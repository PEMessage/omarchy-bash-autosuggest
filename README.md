# Omarchy Bash Autosuggest

Fast, Fish-like history suggestions and command-line motion for Bash, tuned
for Omarchy 4.

[![CI](https://github.com/cyppe/omarchy-bash-autosuggest/actions/workflows/ci.yml/badge.svg)](https://github.com/cyppe/omarchy-bash-autosuggest/actions/workflows/ci.yml)

Type the beginning of a command and the newest matching history entry appears
as a faint italic suffix. Accept all or part of it, keep typing to refine it,
or dismiss it without changing the command you typed.

```text
$ git c▏heckout main
       └─ faint suggestion; Right accepts it
```

This is a small Bash/Readline extension, not a replacement shell or an
Omarchy Shell/Quickshell plugin. It keeps Omarchy's Starship prompt, Tab
completion, `fzf` history search, terminal theme, and Bash history file.

## Install on Omarchy 4

Run this in a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/cyppe/omarchy-bash-autosuggest/main/install.sh | bash && exec bash
```

The installer:

1. Checks the small build dependency set with Omarchy's package helper.
2. Clones the project to `~/.local/share/omarchy-bash-autosuggest`.
3. Compiles and load-checks the module against the local Bash and Readline.
4. Backs up `~/.bashrc`.
5. Appends one clearly marked loader block to `~/.bashrc`.

Dependencies already included with a normal Omarchy installation are left
alone. If any are missing, Omarchy may ask for sudo permission to install
them. The extension itself is installed entirely in your home directory.

If you prefer to inspect the installer first:

```bash
git clone https://github.com/cyppe/omarchy-bash-autosuggest.git
cd omarchy-bash-autosuggest
less install.sh
./install.sh
exec bash
```

### Prebuilt modules

Tagged releases also publish portable modules built in a `manylinux2014`
container (glibc 2.17) for `x86_64` and `aarch64`:

```
omarchy-autosuggest-<tag>-x86_64-unknown-linux-gnu.tar.gz
omarchy-autosuggest-<tag>-aarch64-unknown-linux-gnu.tar.gz
```

Each archive contains `omarchy_autosuggest.so` plus a `.sha256` checksum and can
be loaded without a compiler:

```bash
tar xzf omarchy-autosuggest-*.tar.gz
enable -f "$PWD/omarchy_autosuggest.so" omarchy_autosuggest
omarchy_autosuggest enable
```

The source installer above remains the recommended path: the module hooks
Readline internals, so compiling it against the host Bash and Readline is the
most reliable option.

## Everyday controls

Suggestion acceptance is deliberately simple:

| Key | With a suggestion visible |
| --- | --- |
| Keep typing | Refine or replace the suggestion |
| Right Arrow or Ctrl-F | Accept the complete suggestion |
| Alt-F or Alt-Right | Accept through the next Readline word |
| Ctrl-Right | Accept through the next Bash shell word/token |
| End or Ctrl-E | Accept the complete suggestion |
| Ctrl-G | Hide this suggestion until the typed line changes |
| Enter | Execute only text that was typed or explicitly accepted |
| Any other edit or motion | Remove the ghost suffix, then perform its normal action |

When no suggestion is visible, these keys retain their ordinary Readline
meaning.

### History

| Key | Action |
| --- | --- |
| Up or Ctrl-P | Search backward using the text already typed as a prefix |
| Down or Ctrl-N | Search forward using the same prefix |
| Up on an empty line | Walk through all history, newest first |
| Down past the newest match | Restore the line present before navigation |
| Ctrl-R | Open Omarchy's full interactive `fzf` history search |

Both common terminal encodings for Up and Down are bound, so the behavior is
consistent in a regular terminal and inside tmux. Recalled history is shown as
plain command text rather than immediately growing a second ghost suggestion.

The loader adds `erasedups` to the user's existing `HISTCONTROL`. On Omarchy,
whose default is `ignoreboth`, the result is `ignoreboth:erasedups`: leading-
space commands and adjacent duplicates remain ignored, and saving a repeated
command removes its older copies.

### Motion and completion

| Key | Action |
| --- | --- |
| Alt-F or Alt-Right | Move forward by a Readline word |
| Alt-B or Alt-Left | Move backward by a Readline word |
| Ctrl-Right | Move forward by a shell-aware word |
| Ctrl-Left | Move backward by a shell-aware word |
| Tab / Shift-Tab | Cycle completion candidates forward / backward |

Readline words are useful for small movements within punctuation. Shell words
follow Bash token boundaries, so quoted and escaped arguments move more like
the shell parses them. Tab completion remains Omarchy's menu completion; the
extension fixes its internal repeat state so repeated Tab presses keep cycling.

Other repeat-sensitive Readline commands—including `yank-pop` and repeated
`yank-last-arg`—also retain their normal behavior.

## Visual behavior

Ghost text is faint and italic but has no hard-coded foreground color, so it
inherits the active Omarchy terminal theme. Completion prefixes use the
theme's configured completion color. The audible/visual Readline bell is
disabled for a calmer prompt.

The styling is implemented with Readline's active region and restored whenever
no suggestion is present or the extension is disabled.

## How suggestions are selected

Suggestions are:

- read directly from Bash's in-memory history;
- matched case-sensitively against the complete text before the cursor;
- selected newest-first: the most recent matching entry wins and older
  entries are never used as a fallback;
- hidden when that most recent match is exactly the text already typed. This
  mirrors zsh-autosuggestions: after running `ls`, typing `ls` shows nothing,
  while typing `ls ` lets an older `ls ..` become the suggestion;
- stripped of trailing whitespace, so accepting a suggestion never appends
  stray blanks to the line or to the next history entry;
- displayed only when the cursor is at the end of a non-empty command;
- hidden while browsing history;
- omitted for multiline history entries;
- bounded to the newest 8,192 history entries by default.

Before normal editing or command execution, the extension removes every
character that was not explicitly accepted. Enter therefore cannot
accidentally execute ghost text.

## Configuration

Put configuration before the installer block in `~/.bashrc`.

Change the bounded history scan:

```bash
export OMARCHY_AUTOSUGGEST_HISTORY_LIMIT=4096
```

Keep the suggestions but opt out of the additional history, bell, completion,
arrow, and Ctrl-arrow tuning:

```bash
export OMARCHY_AUTOSUGGEST_TUNE_READLINE=0
```

This is useful when you maintain all Readline bindings yourself. Load the
extension after those bindings. If another tool changes bindings later, run
`omarchy_autosuggest refresh` so the extension can wrap the new final map.

Available maintenance commands:

```bash
omarchy_autosuggest status
omarchy_autosuggest version
omarchy_autosuggest disable
omarchy_autosuggest enable
omarchy_autosuggest refresh
omarchy_autosuggest limit 8192
```

`limit` changes the current shell only; the environment variable applies to
future shells.

## Design and safety

- No daemon or background process.
- No separate history database.
- No network access after installation.
- No subprocess or script on each key press.
- No changes under `/usr/share/omarchy`.
- No hard-coded terminal color.
- Bounded history scanning.
- Safe fallback: if a rebuild or load fails, Bash continues without suggestions.

The module interposes on Readline commands in-process. It preserves the real
previous Readline function while dispatching, which is what allows history
search, menu completion, yank-pop, and other repeated motions to continue
across consecutive key presses.

The compiled module is typically under 20 KB. It is built locally because
Bash loadable modules must match the installed Bash and Readline ABI.

## Update

Run the installation command again:

```bash
curl -fsSL https://raw.githubusercontent.com/cyppe/omarchy-bash-autosuggest/main/install.sh | bash && exec bash
```

The installer performs a fast-forward update, rebuilds, and load-checks the
module. The shell loader also rebuilds automatically when Bash, Readline, the
C source, or the Makefile is newer than the installed module.

## Uninstall

```bash
~/.local/share/omarchy-bash-autosuggest/uninstall.sh && exec bash
```

The uninstaller backs up `~/.bashrc`, removes only its marked loader block,
and deletes the project checkout. It does not touch Bash history.

## Dotfile managers and custom layouts

The automatic installer is designed for regular, unmanaged Omarchy dotfiles.
If `.bashrc` is generated by chezmoi, yadm, or another manager, clone and build
the project, then manage this loader near the end of the interactive section:

```bash
_oba_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
if [[ -r $_oba_data_home/omarchy-bash-autosuggest/shell/init.bash ]]; then
  source "$_oba_data_home/omarchy-bash-autosuggest/shell/init.bash"
fi
unset _oba_data_home
```

Load it after Omarchy's default Bash configuration and any personal Readline,
completion, or `fzf` bindings.

## Compatibility

The supported target is Omarchy 4 or newer with Bash 5 and Readline 8. The
installer can run on another Bash-based distribution when the Bash and
Readline development headers are already available, but Omarchy is the tested
and supported environment.

Both Emacs and vi Readline keymaps are wrapped by the C module. The documented
shortcuts follow Omarchy's default Emacs-style setup.

## Development

```bash
make check
make test
```

`make check` runs GCC's static analyzer, Bash syntax validation, and ShellCheck.
`make test` builds the module, verifies its control commands, then drives a real
interactive Bash through a pseudo-terminal. The regression suite covers
repeated history traversal, restoring the original line, Tab cycling,
`yank-pop`, repeated last-argument recall, suggestion acceptance, Ctrl-G
dismissal, history/suggestion separation, editing commands (Backspace,
Ctrl-W, Ctrl-U) acting on the typed text rather than the ghost suffix, and
Enter erasing the ghost before the command runs.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
