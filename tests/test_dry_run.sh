#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

mkdir -m0700 "$temporary/home"
output=$(
  HOME="$temporary/home" \
  XDG_DATA_HOME="$temporary/data" \
  XDG_CONFIG_HOME="$temporary/config" \
  XDG_CACHE_HOME="$temporary/cache" \
  "$repo_root/install.sh" --dry-run --no-activate --skip-dependency-check
)
[[ "$output" == *'Supported target : Arch Linux'* ]]
[[ ! -e "$temporary/data" && ! -e "$temporary/config" && ! -e "$temporary/cache" ]]

printf '%s\n' 'installer dry run: ok'
