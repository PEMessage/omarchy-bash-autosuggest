# shellcheck shell=bash

# Load only in interactive Bash sessions.
[[ $- == *i* ]] || return 0

_oba_root="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-bash-autosuggest"
_oba_module="$_oba_root/build/omarchy_autosuggest.so"
_oba_needs_build=

if [[ ! -r $_oba_module ||
      $_oba_root/src/omarchy_autosuggest.c -nt $_oba_module ||
      $_oba_root/Makefile -nt $_oba_module ||
      /usr/bin/bash -nt $_oba_module ||
      /usr/lib/libreadline.so.8 -nt $_oba_module ]]; then
  _oba_needs_build=1
fi

if [[ $_oba_needs_build ]]; then
  if ! make --silent -C "$_oba_root" clean all; then
    printf 'omarchy-bash-autosuggest: rebuild failed; suggestions are disabled\n' >&2
    unset _oba_root _oba_module _oba_needs_build
    return 0
  fi
fi

if ! type omarchy_autosuggest &>/dev/null; then
  if ! enable -f "$_oba_module" omarchy_autosuggest 2>/dev/null; then
    # A stale module can survive an unusual package replacement with preserved
    # mtimes. Rebuild once before giving up.
    if ! make --silent -C "$_oba_root" clean all ||
       ! enable -f "$_oba_module" omarchy_autosuggest 2>/dev/null; then
      printf 'omarchy-bash-autosuggest: module load failed; suggestions are disabled\n' >&2
      unset _oba_root _oba_module _oba_needs_build
      return 0
    fi
  fi
fi

omarchy_autosuggest enable

if [[ ${OMARCHY_AUTOSUGGEST_HISTORY_LIMIT:-} ]]; then
  omarchy_autosuggest limit "$OMARCHY_AUTOSUGGEST_HISTORY_LIMIT"
fi

unset _oba_root _oba_module _oba_needs_build
