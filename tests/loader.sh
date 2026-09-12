#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_data_home="$(mktemp -d)"
test_link="$test_data_home/omarchy-bash-autosuggest"

cleanup() {
  [[ ! -L $test_link ]] || unlink "$test_link"
  [[ ! -d $test_data_home ]] || rmdir "$test_data_home"
}
trap cleanup EXIT

ln -s "$repo_root" "$test_link"

output="$(
  XDG_DATA_HOME="$test_data_home" HISTCONTROL=ignoreboth \
    bash --noprofile --norc -ic '
      source "$XDG_DATA_HOME/omarchy-bash-autosuggest/shell/init.bash"
      printf "__HISTCONTROL__%s\n" "$HISTCONTROL"
      omarchy_autosuggest status
      omarchy_autosuggest disable
      bind -q history-search-backward
      bind -q history-search-forward
      bind -q forward-word
      bind -q shell-forward-word
      bind -q shell-backward-word
    ' 2>&1
)"

grep -Fq '__HISTCONTROL__ignoreboth:erasedups' <<<"$output"
grep -Fq 'omarchy_autosuggest 0.2.1: enabled' <<<"$output"
grep -Fq '"\C-p", "\eOA", "\e[A"' <<<"$output"
grep -Fq '"\C-n", "\eOB", "\e[B"' <<<"$output"
grep -Fq '"\e\e[C", "\e[1;3C", "\e[3C", "\ef"' <<<"$output"
grep -Fq '"\e\C-f", "\e[1;5C", "\e[5C"' <<<"$output"
grep -Fq '"\e\C-b", "\e[1;5D", "\e[5D"' <<<"$output"

opt_out="$(
  XDG_DATA_HOME="$test_data_home" HISTCONTROL=ignoreboth \
    OMARCHY_AUTOSUGGEST_TUNE_READLINE=0 \
    bash --noprofile --norc -ic '
      source "$XDG_DATA_HOME/omarchy-bash-autosuggest/shell/init.bash"
      printf "%s\n" "$HISTCONTROL"
    ' 2>&1
)"
grep -Fxq 'ignoreboth' <<<"$opt_out"

printf 'loader test passed\n'
