{
  description = "Ruby gem flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        ruby = pkgs.ruby_3_4; # Specify version
      in
      {
        packages.runtime = pkgs.buildEnv {
          name = "caldav-runtime";
          paths = [
            ruby
            pkgs.libyaml
            pkgs.openssl
            pkgs.cacert
            pkgs.coreutils
          ];
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.pkg-config # native extension discovery
          ];

          buildInputs = [
            ruby
            pkgs.libyaml # psych gem
            pkgs.openssl # openssl gem
            pkgs.coreutils
            pkgs.cacert
            pkgs.nix-ld
          ];

          shellHook = ''
            export GEM_HOME="$PWD/.gem"
            export GEM_PATH="$GEM_HOME"
            export PATH="$GEM_HOME/bin:$PATH"
            export BUNDLE_PATH="$GEM_HOME"
            export BUNDLE_BIN="$GEM_HOME/bin"
          '';
        };
      }
    );
}

