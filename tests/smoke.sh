#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
module="$repo_root/build/omarchy_autosuggest.so"

[[ -r $module ]] || {
  printf 'missing test module: %s\n' "$module" >&2
  exit 1
}

# Readline's active-mark API only exists in 8.1 and newer. The module must keep
# referencing it weakly so that loading against an older Readline (for example
# the Readline 7.0 embedded in Ubuntu 18.04's Bash) does not abort the shell
# with "undefined symbol". A strong reference here is a portability regression.
for symbol in rl_activate_mark rl_deactivate_mark rl_keep_mark_active \
              rl_mark_active_p; do
  if ! nm -D "$module" | grep -Eq "[[:space:]]w $symbol$"; then
    printf 'regression: %s must be a weak reference\n' "$symbol" >&2
    exit 1
  fi
done

output="$({
  bash --noprofile --norc -c '
    enable -f "$1" omarchy_autosuggest
    omarchy_autosuggest version
    omarchy_autosuggest enable
    omarchy_autosuggest status
    omarchy_autosuggest limit 4096
    omarchy_autosuggest disable
    omarchy_autosuggest status
  ' bash "$module"
} 2>&1)"

grep -Fq '0.2.1' <<<"$output"
grep -Fq 'enabled (history scan limit: 8192)' <<<"$output"
grep -Fq 'disabled (history scan limit: 4096)' <<<"$output"

printf 'smoke test passed\n'
