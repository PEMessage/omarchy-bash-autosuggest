#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
module="$repo_root/build/omarchy_autosuggest.so"

[[ -r $module ]] || {
  printf 'missing test module: %s\n' "$module" >&2
  exit 1
}

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
