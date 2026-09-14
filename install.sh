#!/usr/bin/env bash
# shellcheck disable=SC2016 # The installed loader must retain its variables literally.

set -Eeuo pipefail

readonly PROJECT_NAME="omarchy-bash-autosuggest"
readonly REPO_URL="${OMARCHY_BASH_AUTOSUGGEST_REPO_URL:-https://github.com/PEMessage/omarchy-bash-autosuggest.git}"
readonly REPO_REF="${OMARCHY_BASH_AUTOSUGGEST_REF:-main}"
readonly DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
readonly INSTALL_DIR="${OMARCHY_BASH_AUTOSUGGEST_INSTALL_DIR:-$DATA_HOME/$PROJECT_NAME}"
readonly BASHRC="${OMARCHY_BASH_AUTOSUGGEST_BASHRC:-$HOME/.bashrc}"
readonly START_MARKER="# >>> omarchy-bash-autosuggest >>>"
readonly END_MARKER="# <<< omarchy-bash-autosuggest <<<"

die() {
  printf 'omarchy-bash-autosuggest: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" &>/dev/null || die "missing required command: $1"
}

if (( EUID == 0 )); then
  die "run the installer as your regular Omarchy user, not as root"
fi

if command -v omarchy &>/dev/null; then
  omarchy_version="$(omarchy version 2>/dev/null || true)"
  omarchy_major="${omarchy_version%%.*}"
  if [[ $omarchy_major =~ ^[0-9]+$ ]] && (( omarchy_major < 4 )); then
    die "Omarchy 4 or newer is required (found $omarchy_version)"
  fi

  if command -v omarchy-pkg-add &>/dev/null; then
    printf 'Checking build dependencies...\n'
    omarchy-pkg-add base-devel bash git readline
  fi
else
  printf 'omarchy-bash-autosuggest: Omarchy was not detected; continuing with generic Bash support\n' >&2
fi

for command_name in bash cc git install make mktemp strip; do
  require_command "$command_name"
done

(( BASH_VERSINFO[0] >= 5 )) || die "Bash 5 or newer is required"
[[ -r /usr/include/bash/builtins.h ]] ||
  die "Bash development headers are missing; on Omarchy run: omarchy pkg add bash base-devel"
[[ -r /usr/include/readline/readline.h ]] ||
  die "Readline development headers are missing; on Omarchy run: omarchy pkg add readline"

mkdir -p "$(dirname "$INSTALL_DIR")"

if [[ -d $INSTALL_DIR/.git ]]; then
  if ! git -C "$INSTALL_DIR" diff --quiet ||
     ! git -C "$INSTALL_DIR" diff --cached --quiet; then
    die "the existing checkout has local changes: $INSTALL_DIR"
  fi
  printf 'Updating %s...\n' "$PROJECT_NAME"
  git -C "$INSTALL_DIR" pull --ff-only --quiet
elif [[ -e $INSTALL_DIR ]]; then
  die "install path exists but is not a git checkout: $INSTALL_DIR"
else
  printf 'Installing %s...\n' "$PROJECT_NAME"
  git clone --quiet --depth 1 --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR"
fi

make --silent -C "$INSTALL_DIR" rebuild
[[ -r $INSTALL_DIR/build/omarchy_autosuggest.so ]] || die "the module was not built"

installed_version="$(
  bash --noprofile --norc -c '
    enable -f "$1" omarchy_autosuggest
    omarchy_autosuggest version
  ' bash "$INSTALL_DIR/build/omarchy_autosuggest.so"
)" || die "the built module could not be loaded"

# Ghost text needs Readline 8.1 (the active-region API). Older Readline still
# loads the module, but suggestions cannot be drawn, so warn instead of letting
# the user discover it on the next shell.
if bash --noprofile --norc -c '
      enable -f "$1" omarchy_autosuggest
      omarchy_autosuggest status
    ' bash "$INSTALL_DIR/build/omarchy_autosuggest.so" 2>/dev/null |
    grep -Fq 'Readline 8.1 or newer required'; then
  printf 'omarchy-bash-autosuggest: Readline 8.1 or newer is required; suggestions will stay disabled\n' >&2
fi

mkdir -p "$(dirname "$BASHRC")"
touch "$BASHRC"

if grep -Fqx "$START_MARKER" "$BASHRC"; then
  grep -Fqx "$END_MARKER" "$BASHRC" || die "the Bash configuration block is incomplete: $BASHRC"
else
  backup_path="$BASHRC.bak.$(date +%Y%m%d%H%M%S%N)"
  cp -p "$BASHRC" "$backup_path"
  {
    printf '\n%s\n' "$START_MARKER"
    printf '%s\n' '_oba_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"'
    printf '%s\n' 'if [[ -r $_oba_data_home/omarchy-bash-autosuggest/shell/init.bash ]]; then'
    printf '%s\n' '  source "$_oba_data_home/omarchy-bash-autosuggest/shell/init.bash"'
    printf '%s\n' 'fi'
    printf '%s\n' 'unset _oba_data_home'
    printf '%s\n' "$END_MARKER"
  } >>"$BASHRC"
  printf 'Backed up %s to %s\n' "$BASHRC" "$backup_path"
fi

printf '\nInstalled %s v%s. Open a new terminal to start using it.\n' \
  "$PROJECT_NAME" "$installed_version"
