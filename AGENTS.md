# AGENTS.md

Build-environment notes for this repository (omarchy-bash-autosuggest), plus a
detailed explanation of why the FHS devShell cannot be used with
`nix develop -c 'xxx'`.

## Build environment overview

`flake.nix` does one thing: it provides an interactive devShell based on
`buildFHSEnv`. Nix itself does not build anything; all compilation happens
manually inside the FHS sandbox entered via `nix develop`.

```bash
nix develop   # enter the FHS interactively
```

Once inside:

- Headers live at standard FHS paths: `/usr/include/bash`, `/usr/include/readline`;
  libraries are in `/usr/lib` — exactly what the `Makefile` expects with its
  hard-coded `-I/usr/include/bash` etc.
- `cc` / `make` / `strip` / `patchelf` / `python3` / `shellcheck` are available.

Build commands:

```bash
make                      # plain build (links readline; artifact carries a Nix-store RPATH)
make test                 # smoke test + pty interactive test
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

Note: functions defined in `profile` must be `export -f`. The FHS startup
sequence is `/init → source /etc/profile → exec bash`; `exec` replaces the
process, and plain shell functions do not survive across `exec` unless exported.

## Why `nix develop -c 'xxx'` is unusable with the FHS devShell

### 1. How `nix develop -c` actually works

`nix develop -c CMD` generates a temporary activation script (something like
`/tmp/nix-shell.XXXX`), initializes the environment, then execs the command at
the end of the script. Observed tail of the script:

```bash
eval "${shellHook:-}"
command rm -f '/tmp/nix-shell.XXXX'
exec 'echo' 'HI'        # the command is hard-coded as an argv list after the shellHook
```

Two key points:

- The command is **hard-coded in an `exec` after the shellHook**; it is not
  passed to the shellHook as arguments.
- So the shellHook cannot see the command: measured inside the shellHook,
  `$#` = 0, `$@` is empty, and `$BASH_EXECUTION_STRING` is empty too (i.e. this
  bash was not the one started with `-c 'CMD'`).

### 2. How the `buildFHSEnv` devShell works

The `buildFHSEnv` `.env` (our devShell) has a bwrap launcher script as its
`shellHook`, ending with:

```bash
exec "${cmd[@]}"
```

`cmd` is a `bwrap ... container-init` invocation that execs `/init` with no
arguments; `/init` is:

```bash
source /etc/profile
exec bash "$@"
```

i.e. **start the FHS sandbox, then start an interactive bash**.

### 3. Why the combination is necessarily broken

Putting 1 and 2 together:

```
nix develop -c 'make'
  └─ bash /tmp/nix-shell.XXXX
       ├─ eval "${shellHook}"          ← the bwrap launcher lives here
       │    └─ exec bwrap ... /init   ← process replaced, drops into FHS interactive bash
       │                                 the remaining lines never run
       ├─ command rm -f /tmp/nix-shell.XXXX
       └─ exec 'make'                  ← never reached
```

The shellHook's `exec bwrap` replaces the current process entirely, so the
trailing `exec 'make'` in the script never executes. And since the shellHook
cannot perceive the pending command (`$@` empty, `$BASH_EXECUTION_STRING`
empty), there is no way to "forward the command into the sandbox".

Observed behavior:

- `nix develop -c echo HELLO` prints nothing and exits quietly (the command is
  left outside the sandbox).
- `nix develop -c 'echo HI'` (quoted, single argument): even with a plain
  `mkShell`, `exec 'echo HI'` treats the whole string as a program name and
  fails with `exec: echo HI: not found`. `nix develop -c` does no shell
  parsing — for multi-word commands use `nix develop -c bash -c '...'` or split
  into separate arguments.
- `$-` is `imBH` in interactive mode (a real terminal) and `hB` in `-c` mode,
  so one can branch on `case $- in *i*)` to tell the two apart — but that is
  all; the command itself remains invisible.

### Conclusion

The FHS devShell only works interactively:

```bash
nix develop          # enter the FHS sandbox
make                 # compile manually inside the sandbox
```

If you need to run commands **non-interactively/scripted** inside the FHS, do
not use `nix develop -c`. Call the wrapper that `buildFHSEnv` generates instead
(not exposed by this flake); e.g. expose the `buildFHSEnv {...}` result (without
`.env`) as a package output and run:

```bash
result/bin/omarchy-autosuggest-build -c 'make'   # wrapper appends args to bash
```

This is what the `buildFHSEnv` docs describe: command-line arguments passed to
the wrapper are appended to `runScript` (defaulting to `bash`), so
`wrapper -c 'cmd'` is equivalent to `bash -c 'cmd'` inside the sandbox.

## Other notes

- On WSL without a tty (e.g. piped stdin), `nix develop` may appear to not enter
  the FHS because the shellHook is not run in `-c`/pipe scenarios; verify with a
  real terminal or a pseudo-terminal such as
  `script -qec 'nix develop' /dev/null`.
- `nix develop -c` works fine with a plain `mkShell` (its shellHook does not
  exec away the process, so the trailing `exec CMD` runs); the problem is
  specific to devShells whose shellHook ends in `exec`, like `buildFHSEnv`'s.