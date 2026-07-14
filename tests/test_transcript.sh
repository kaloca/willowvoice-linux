#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

source "$repo_root/bin/willow-dictate"
python_bin=$(command -v python3)
runtime_dir="$temporary/runtime"
mkdir -m0700 "$runtime_dir"
state_file="$runtime_dir/dictation.state"
generation_file="$runtime_dir/generation"

printf '%s' '{"query":"exact synthetic transcript\nsecond line","isPlaceholder":false}' \
  >"$temporary/valid.json"
extract_transcript "$temporary/valid.json" "$temporary/output"
printf 'exact synthetic transcript\nsecond line' >"$temporary/expected"
cmp -s "$temporary/expected" "$temporary/output"

printf '%s' '{"query":"","isPlaceholder":true}' >"$temporary/placeholder.json"
if extract_transcript "$temporary/placeholder.json" "$temporary/unused"; then
  printf '%s\n' 'placeholder transcript was accepted' >&2
  exit 1
fi

write_state active generation 123 /data /logs/main.log 42 ''
state=()
read_state
[[ "${state[0]}" == active && "${state[1]}" == generation && "${state[5]}" == 42 ]]

expected_id='11111111-1111-4111-8111-111111111111'
printf '%s\n' 'current-generation' >"$generation_file"
printf '%s\n' "old Recording started { transcriptId: '22222222-2222-4222-8222-222222222222' }" \
  >"$temporary/main.log"
offset=$(stat -c '%s' "$temporary/main.log")
printf '%s\n' "new Recording started { transcriptId: '$expected_id' }" >>"$temporary/main.log"
actual_id=$(find_recording_id current-generation "$temporary/main.log" "$offset")
[[ "$actual_id" == "$expected_id" ]]

if rg -n 'latest_transcript|newest transcript|baseline' "$repo_root/bin/willow-dictate"; then
  printf '%s\n' 'unsafe newest-transcript fallback was found' >&2
  exit 1
fi

printf '%s\n' 'transcript association: ok'
