{
  description = "Flake to build a static site with hugo";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-24.11";
    even-theme = {
      url = "github:olOwOlo/hugo-theme-even/master";
      flake = false;
    };
  };

  outputs =
    {
      self,
      even-theme,
      nixpkgs,
      ...
    }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forEachSystem =
        fn:
        nixpkgs.lib.genAttrs systems (
          system:
          let
            pkgs = import nixpkgs { inherit system; };
          in
          fn pkgs
        );

      buildHugoPackage = { pkgs, pname, version, src, extraBuildArgs ? "" }: (pkgs.stdenvNoCC.mkDerivation {
        inherit pname version src;

        nativeBuildInputs = [
          pkgs.hugo
        ];

        buildPhase = ''
          mkdir -p themes/even/
          cp -r ${even-theme} themes/even
          hugo ${extraBuildArgs}
        '';

        installPhase = ''
          cp -r public $out
        '';
      });

    in
    {
      packages = forEachSystem (pkgs: rec {
        allthingsembedded = buildHugoPackage {
          inherit pkgs;
          pname = "allthingsembedded";
          version = "1.0.0";
          src = self;
          extraBuildArgs = "--minify";
        };

        allthingsembedded-staging = buildHugoPackage {
          inherit pkgs;
          pname = "allthingsembedded";
          version = "1.0.0";
          src = self;
          extraBuildArgs = "--minify -D --baseURL https://allthingsembedded.com/staging-web";
        };

        default = allthingsembedded;
      });

      devShells = forEachSystem (pkgs: rec {
        allthingsembedded = pkgs.mkShellNoCC {
          nativeBuildInputs = [
            pkgs.hugo
          ];
        };

        default = allthingsembedded;
      });
    };
}
