#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

command -v rg >/dev/null 2>&1 || {
  printf '%s\n' 'tests/run.sh: ripgrep is required (sudo pacman -S --needed ripgrep)' >&2
  exit 1
}

scripts=(
  "$repo_root/install.sh"
  "$repo_root/uninstall.sh"
  "$repo_root/bin/willow-dictate"
  "$repo_root/bin/willow-doctor"
  "$repo_root/bin/willow-voice-linux"
  "$repo_root/tests/test_callback.sh"
  "$repo_root/tests/test_clipboard_race.sh"
  "$repo_root/tests/test_transcript.sh"
  "$repo_root/tests/test_dry_run.sh"
  "$repo_root/tests/test_safety.sh"
)
bash -n "${scripts[@]}"

machine_path_pattern='/home/[A-Za-z0-9._-]+|/tmp/'"willow"
if rg -n "$machine_path_pattern" \
    "$repo_root" \
    -g '!build/**' -g '!README.md' -g '!docs/**'; then
  printf '%s\n' 'machine-specific or legacy path found' >&2
  exit 1
fi
if rg -n --pcre2 \
    'code=(?!(?:11111111-1111-4111-8111-111111111111|22222222-2222-4222-8222-222222222222))(?:[0-9a-fA-F]{8}-[0-9a-fA-F-]{27})' \
    "$repo_root" -g '!build/**'; then
  printf '%s\n' 'non-synthetic callback identifier found' >&2
  exit 1
fi

"$repo_root/tests/test_callback.sh"
"$repo_root/tests/test_clipboard_race.sh"
"$repo_root/tests/test_transcript.sh"
"$repo_root/tests/test_dry_run.sh"
"$repo_root/tests/test_safety.sh"

rg -q 'RuntimeDirectory=willow-ydotool' \
  "$repo_root/data/systemd/user/willow-ydotoold.service.in"
rg -q 'willow-ydotool/ydotool.sock' "$repo_root/bin/willow-dictate"
if rg -n '^After=.*graphical-session\.target' "$repo_root/data/systemd/user"; then
  printf '%s\n' 'graphical-session.target ordering cycle found' >&2
  exit 1
fi
sed -n '/^required_commands=(/,/^)/p' "$repo_root/install.sh" \
  | rg -q '(^|[[:space:]])cmp([[:space:]]|$)'
sed -n '/^required_commands=(/,/^)/p' "$repo_root/install.sh" \
  | rg -q '(^|[[:space:]])ctest([[:space:]]|$)'
sed -n '/^arch_packages=(/,/^)/p' "$repo_root/install.sh" \
  | rg -q '(^|[[:space:]])diffutils([[:space:]]|$)'
sed -n '/^arch_packages=(/,/^)/p' "$repo_root/install.sh" \
  | rg -q '(^|[[:space:]])kglobalacceld([[:space:]]|$)'
rg -q 'for command_name in .*cmp' "$repo_root/bin/willow-doctor"
rg -q 'sudo is required for dependency or uinput setup' "$repo_root/install.sh"
rg -q 'sudo is required by --remove-uinput' "$repo_root/uninstall.sh"

cmake -S "$repo_root" -B "$temporary/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
cmake --build "$temporary/build"
ctest --test-dir "$temporary/build" --output-on-failure

printf '%s\n' 'all local tests: ok'
