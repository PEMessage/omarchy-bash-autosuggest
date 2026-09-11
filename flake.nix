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
    in
    {
      # `nix develop` only (interactive). `nix develop -c ...` cannot enter a
      # buildFHSEnv sandbox, because its shellHook execs bwrap before the
      # command is reached.
      devShells = forAllSystems (pkgs: {
        default = (pkgs.buildFHSEnv {
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
        }).env;
      });
    };
}
