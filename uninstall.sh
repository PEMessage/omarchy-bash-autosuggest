#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROJECT_NAME="omarchy-bash-autosuggest"
readonly DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
readonly INSTALL_DIR="${OMARCHY_BASH_AUTOSUGGEST_INSTALL_DIR:-$DATA_HOME/$PROJECT_NAME}"
readonly BASHRC="${OMARCHY_BASH_AUTOSUGGEST_BASHRC:-$HOME/.bashrc}"
readonly START_MARKER="# >>> omarchy-bash-autosuggest >>>"
readonly END_MARKER="# <<< omarchy-bash-autosuggest <<<"

die() {
  printf 'omarchy-bash-autosuggest: %s\n' "$*" >&2
  exit 1
}

if (( EUID == 0 )); then
  die "run the uninstaller as your regular user, not as root"
fi

if [[ -f $BASHRC ]] && grep -Fqx "$START_MARKER" "$BASHRC"; then
  backup_path="$BASHRC.bak.$(date +%Y%m%d%H%M%S)"
  temp_path="$(mktemp "$BASHRC.tmp.XXXXXX")"
  cp -p "$BASHRC" "$backup_path"
  awk -v start="$START_MARKER" -v end="$END_MARKER" '
    $0 == start { skipping = 1; next }
    $0 == end { skipping = 0; found_end = 1; next }
    !skipping { print }
    END { if (skipping || !found_end) exit 42 }
  ' "$BASHRC" >"$temp_path" || {
    rm -f -- "$temp_path"
    die "could not remove the Bash configuration block"
  }
  chmod --reference="$BASHRC" "$temp_path"
  mv -f -- "$temp_path" "$BASHRC"
  printf 'Backed up %s to %s\n' "$BASHRC" "$backup_path"
fi

[[ ${INSTALL_DIR##*/} == "$PROJECT_NAME" ]] || die "refusing to remove unexpected path: $INSTALL_DIR"
[[ $INSTALL_DIR != / && $INSTALL_DIR != "$HOME" ]] || die "refusing to remove unsafe path: $INSTALL_DIR"

rm -rf -- "$INSTALL_DIR"
printf 'Uninstalled %s. Open a new terminal to finish.\n' "$PROJECT_NAME"
