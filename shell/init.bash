# shellcheck shell=bash

# Load only in interactive Bash sessions.
[[ $- == *i* ]] || return 0

if [[ ${OMARCHY_AUTOSUGGEST_TUNE_READLINE:-1} != 0 ]]; then
  # A small Fish-like layer over Omarchy's Readline defaults. Keep the user's
  # existing history policy and add only duplicate cleanup.
  case ":${HISTCONTROL:-}:" in
    *:erasedups:*) ;;
    *) HISTCONTROL="${HISTCONTROL:+$HISTCONTROL:}erasedups" ;;
  esac

  bind 'set bell-style none'
  bind 'set colored-completion-prefix on'

  # Bind both CSI and SS3 arrows so regular terminals and tmux behave alike.
  bind '"\e[A": history-search-backward'
  bind '"\eOA": history-search-backward'
  bind '"\C-p": history-search-backward'
  bind '"\e[B": history-search-forward'
  bind '"\eOB": history-search-forward'
  bind '"\C-n": history-search-forward'

  # Alt moves by Readline words. Ctrl moves by shell words, treating quoted and
  # escaped text like Bash syntax. Terminals emit a few common variants.
  bind '"\e[1;3C": forward-word'
  bind '"\e[3C": forward-word'
  bind '"\e\e[C": forward-word'
  bind '"\e[1;3D": backward-word'
  bind '"\e[3D": backward-word'
  bind '"\e\e[D": backward-word'
  bind '"\e[1;5C": shell-forward-word'
  bind '"\e[5C": shell-forward-word'
  bind '"\e[1;5D": shell-backward-word'
  bind '"\e[5D": shell-backward-word'
fi

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
  if ! make --silent -C "$_oba_root" rebuild; then
    printf 'omarchy-bash-autosuggest: rebuild failed; suggestions are disabled\n' >&2
    unset _oba_root _oba_module _oba_needs_build
    return 0
  fi
fi

if ! type omarchy_autosuggest &>/dev/null; then
  if ! enable -f "$_oba_module" omarchy_autosuggest 2>/dev/null; then
    # A stale module can survive an unusual package replacement with preserved
    # mtimes. Rebuild once before giving up.
    if ! make --silent -C "$_oba_root" rebuild ||
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
