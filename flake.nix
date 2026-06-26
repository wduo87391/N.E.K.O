{
  description = "N.E.K.O development environment using uv2nix";

  # Flake 输入：固定 Nix 世界里要用到的包集合和 Python/uv 转换工具。
  inputs = {
    # Nixpkgs 提供 Python 解释器、uv、mkShell 等基础包。
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # pyproject.nix 提供从 pyproject 元数据构造 Python 包集合的底层 builder。
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # uv2nix 读取 uv.lock，把 uv 解析出的依赖图转换为 pyproject.nix overlay。
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # uv 不会锁定构建后端依赖；这个输入提供常见 build-system 包的 overlay。
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # 当前目标是 NixOS 开发环境；先只暴露 Linux，避免无意评估 Darwin/其他平台。
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;

      # 读取 pyproject.toml 与 uv.lock；单项目也会被 uv2nix 当作 workspace 处理。
      workspace = uv2nix.lib.workspace.loadWorkspace {
        workspaceRoot = ./.;
      };

      # 由 uv.lock 生成运行依赖 overlay。wheel 优先更接近官方 hello-world 的稳妥默认值。
      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      # Some legacy PyAutoGUI stack sdists do not declare setuptools, so uv2nix
      # needs the build backend supplied explicitly.
      buildSystemOverrides = final: prev:
      let
        withSetuptools = package:
          package.overrideAttrs (old: {
            nativeBuildInputs =
              (old.nativeBuildInputs or [ ])
              ++ final.resolveBuildSystem {
                setuptools = [ ];
              };
          });
      in
      {
        mouseinfo = withSetuptools prev.mouseinfo;
        pyautogui = withSetuptools prev.pyautogui;
        pygetwindow = withSetuptools prev.pygetwindow;
        pymsgbox = withSetuptools prev.pymsgbox;
        pyperclip = withSetuptools prev.pyperclip;
        pyrect = withSetuptools prev.pyrect;
        pyscreeze = withSetuptools prev.pyscreeze;
        pytweening = withSetuptools prev.pytweening;
        qrcode-terminal = withSetuptools prev.qrcode-terminal;
        safeio = withSetuptools prev.safeio;
      };

      # 开发 shell 使用 editable 安装；源码路径通过 shellHook 里的 REPO_ROOT 注入。
      editableOverlay = workspace.mkEditablePyprojectOverlay {
        root = "$REPO_ROOT";
      };

      # 每个系统各自实例化 nixpkgs、Python 和 pyproject.nix 包集合，避免交叉引用宿主系统。
      pythonSets = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # N.E.K.O 在 pyproject.toml 里声明 requires-python = "==3.11.*"。
          python = lib.head (
            pyproject-nix.lib.util.filterPythonInterpreters {
              inherit (workspace) requires-python;
              inherit (pkgs) pythonInterpreters;
            }
          );

          # pyproject.nix 的基础 Python 包集合；具体依赖随后由 overlay 注入。
          pythonBase = pkgs.callPackage pyproject-nix.build.packages {
            inherit python;
          };
        in
        pythonBase.overrideScope (
          lib.composeManyExtensions [
            pyproject-build-systems.overlays.wheel
            overlay
            buildSystemOverrides
          ]
        )
      );
    in
    {
      # nix develop 默认进入的开发环境：依赖来自 uv.lock，本地项目以 editable 方式挂载。
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pythonSet = pythonSets.${system}.overrideScope editableOverlay;

          # workspace.deps.all = 默认依赖 + optional-dependencies + dependency-groups。
          # 这里会包含 pyproject.toml 里的 dev/galgame 组；如果只想要运行依赖，改成 workspace.deps.default。
          virtualenv = pythonSet.mkVirtualEnv "n-e-k-o-dev-env" workspace.deps.all;
        in
        {
          default = pkgs.mkShell {
            packages = [
              virtualenv
              pkgs.uv
            ];

            # 让 uv 服从 Nix 构建出的解释器/环境，而不是自己创建或下载 Python。
            env = {
              UV_NO_SYNC = "1";
              UV_PYTHON = pythonSet.python.interpreter;
              UV_PYTHON_DOWNLOADS = "never";
            };

            # editable overlay 需要 REPO_ROOT；清掉 PYTHONPATH 可避免 nixpkgs Python hook 污染。
            shellHook = ''
              unset PYTHONPATH
              export REPO_ROOT=$(git rev-parse --show-toplevel)
            '';
          };
        }
      );

      # nix build 默认产物：一个包含运行依赖的虚拟环境，适合先验证 uv2nix 依赖闭包。
      # 真正发布 CLI/桌面应用时，可再按官方 Shipping applications 文档改成 mkApplication。
      packages = forAllSystems (
        system:
        {
          default = pythonSets.${system}.mkVirtualEnv "n-e-k-o-env" workspace.deps.default;
        }
      );
    };
}
