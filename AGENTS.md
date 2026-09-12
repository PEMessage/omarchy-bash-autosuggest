# AGENTS.md

Build-environment notes for this repository (omarchy-bash-autosuggest).

## Build environment

`flake.nix` provides an interactive devShell based on `buildFHSEnv`, plus a
wrapper app for non-interactive commands. Nix itself does not build anything;
all compilation happens manually inside the FHS sandbox.

```bash
nix develop                    # enter the FHS interactively

# ...or run one command without an interactive shell:
nix run .# -- -c 'make'
```

Use `nix run .# -- -c '<command>'` for scripting/CI. It goes through the
`buildFHSEnv` wrapper (exposed as `packages.default` / `apps.default`), which
forwards its arguments to `bash` inside the sandbox and propagates the exit
code. Do not use `nix develop -c`: the FHS shellHook ends in `exec bwrap`, so
anything after the shellHook never runs.

Inside the sandbox:

- Headers live at standard FHS paths: `/usr/include/bash`, `/usr/include/readline`;
  libraries are in `/usr/lib` — exactly what the `Makefile` expects with its
  hard-coded `-I/usr/include/bash` etc.
- `cc` / `make` / `strip` / `patchelf` / `python3` / `shellcheck` are available.

## Build commands

```bash
make                      # plain build (links readline; artifact carries a Nix-store RPATH)
make test                 # smoke test + pty interactive test (needs a real terminal)
omarchy-build-portable    # produce a portable .so (no readline link, no RPATH)
```

`omarchy-build-portable` is defined in the FHS `profile`:

```bash
omarchy-build-portable() {
  make --silent rebuild LDLIBS=
  patchelf --remove-rpath build/omarchy_autosuggest.so
}
```

- `LDLIBS=` skips linking `-lreadline`. The `rl_*` symbols needed at load time
  are provided by the host bash process (bash links readline itself and puts
  those symbols in the global symbol table), so the module does not declare a
  dependency on readline.
- `patchelf --remove-rpath` drops the `/nix/store/...` RUNPATH that the Nix
  cc-wrapper writes automatically.
- Result: `NEEDED` only lists `libc.so.6`, no RPATH — the file loads on other
  distributions.

Functions defined in `profile` must be `export -f`: the FHS startup sequence is
`/init → source /etc/profile → exec bash`, and plain shell functions do not
survive across `exec`.

## Notes

- `make test`'s pty test needs a real terminal; run it from `nix develop` rather
  than `nix run`.
- On WSL without a tty (e.g. piped stdin), `nix develop` may appear not to enter
  the FHS; verify with a real terminal or `script -qec 'nix develop' /dev/null`.
