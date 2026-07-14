#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

export HOME="$temporary/home"
export XDG_DATA_HOME="$temporary/data"
mkdir -p "$HOME" "$XDG_DATA_HOME/willow-linux-bridge/current/app"
: >"$XDG_DATA_HOME/willow-linux-bridge/current/app/Willow Voice.exe"

source "$repo_root/bin/willow-voice-linux"

valid='willow://login-callback?code=11111111-1111-4111-8111-111111111111&posthog_distinct_id=synthetic-test-device'
valid_callback_url "$valid"
valid_callback_url 'willow://login-callback?posthog_distinct_id=test-device&code=22222222-2222-4222-8222-222222222222'

invalid=(
  'https://example.com/login-callback?code=11111111-1111-4111-8111-111111111111'
  'willow://other?code=11111111-1111-4111-8111-111111111111'
  'willow://login-callback?code=not-a-uuid'
  'willow://login-callback?code=11111111-1111-4111-8111-111111111111&code=22222222-2222-4222-8222-222222222222'
  'willow://login-callback?code=11111111-1111-4111-8111-111111111111&unexpected=yes'
  'willow://login-callback?code=11111111-1111-4111-8111-111111111111&posthog_distinct_id='
  'willow://login-callback?code=11111111-1111-4111-8111-111111111111&'
  $'willow://login-callback?code=11111111-1111-4111-8111-111111111111\nignored'
)
for url in "${invalid[@]}"; do
  if valid_callback_url "$url"; then
    printf 'accepted invalid callback URL\n' >&2
    exit 1
  fi
done

printf '%s\n' 'callback validation: ok'
