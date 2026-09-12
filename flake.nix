{
  description = "FHS build environment for the omarchy-bash-autosuggest Bash loadable module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));

      # The FHS environment, exposed three ways:
      #   devShells.default = fhs.env  -> interactive `nix develop`
      #   packages.default  = fhs      -> the wrapper binary
      #   apps.default      = wrapper  -> `nix run .# -- -c '<command>'`
      # The last two exist because `nix develop -c` cannot reach into an FHS
      # env (its shellHook execs bwrap before the command is run); the wrapper
      # binary forwards its arguments to bash *inside* the chroot.
      mkFhs = pkgs: pkgs.buildFHSEnv {
        name = "omarchy-autosuggest-build";

        # Headers and libraries end up at the conventional FHS paths the
        # Makefile expects (/usr/include/bash, /usr/include/readline,
        # /usr/lib). `extraOutputsToInstall = [ "dev" ]` pulls in the Bash and
        # Readline development headers.
        targetPkgs =
          pkgs:
          with pkgs;
          [
            bashInteractive
            readline
            gcc
            binutils
            patchelf
            gnumake
            pkg-config
            coreutils
            gnused
            gnugrep
            findutils
            gawk
            gzip
            git
            python3
            shellcheck
          ];

        extraOutputsToInstall = [ "dev" ];

        # Plain `make` links Readline and records a Nix-store RPATH, so the
        # resulting module is tied to this machine. This helper builds without
        # linking Readline (the loading Bash already provides the symbols) and
        # strips the RPATH, leaving an `.so` whose only dependency is libc.
        profile = ''
          omarchy-build-portable() {
            make --silent rebuild LDLIBS= &&
              patchelf --remove-rpath build/omarchy_autosuggest.so &&
              printf 'Portable module: %s\n' "$PWD/build/omarchy_autosuggest.so"
          }
          export -f omarchy-build-portable
        '';
      };
    in
    {
      # Interactive shell: `nix develop`.
      devShells = forAllSystems (pkgs: {
        default = (mkFhs pkgs).env;
      });

      # Non-interactive use: `nix run .# -- -c '<command>'`.
      packages = forAllSystems (pkgs: {
        default = mkFhs pkgs;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${mkFhs pkgs}/bin/omarchy-autosuggest-build";
          meta.description = "Run a command inside the omarchy-autosuggest FHS build environment";
        };
      });
    };
}
