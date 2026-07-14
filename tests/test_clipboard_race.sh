#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d)
socket_pid=''
copy_pid=''
cleanup() {
  [[ -n "$copy_pid" ]] && kill "$copy_pid" 2>/dev/null || true
  [[ -n "$socket_pid" ]] && kill "$socket_pid" 2>/dev/null || true
  rm -rf -- "$temporary"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

source "$repo_root/bin/willow-dictate"
export FAKE_CLIPBOARD="$temporary/clipboard"
export FAKE_YDOTOOL_LOG="$temporary/ydotool.log"
export FAKE_MUTATE_ON_START=1
wl_copy_bin="$repo_root/tests/fakes/wl-copy"
wl_paste_bin="$repo_root/tests/fakes/wl-paste"
systemctl_bin="$repo_root/tests/fakes/systemctl"
ydotool_bin="$repo_root/tests/fakes/ydotool"
cmp_bin=$(command -v cmp)
runtime_dir="$temporary/runtime"
paste_lock_file="$runtime_dir/paste.lock"
generation_file="$runtime_dir/generation"
ydotool_socket="$runtime_dir/ydotool.sock"
mkdir -m0700 "$runtime_dir"
printf '%s\n' 'current-generation' >"$generation_file"
printf '%s' 'synthetic current transcript' >"$temporary/transcript"

python3 - "$ydotool_socket" <<'PY' &
import socket
import sys
import time

server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.listen(1)
time.sleep(20)
PY
socket_pid=$!
for _ in {1..50}; do
  [[ -S "$ydotool_socket" ]] && break
  sleep 0.01
done
[[ -S "$ydotool_socket" ]]

if deliver_transcript current-generation "$temporary/transcript"; then
  printf '%s\n' 'delivery succeeded after clipboard mutation' >&2
  exit 1
fi
[[ "$(<"$FAKE_CLIPBOARD")" == 'different clipboard data' ]]
[[ ! -s "$FAKE_YDOTOOL_LOG" ]]

printf '%s\n' 'clipboard mutation before paste: safely aborted'
