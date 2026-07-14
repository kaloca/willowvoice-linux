#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

export HOME="$temporary/home"
export XDG_DATA_HOME="$temporary/data"
export XDG_CONFIG_HOME="$temporary/config"
mkdir -m0700 "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

# Neither installer nor uninstaller may follow a marker symlink.
mkdir -m0700 "$XDG_DATA_HOME/willow-linux-bridge"
printf '%s\n' 'sentinel-must-not-change' >"$temporary/sentinel"
ln -s "$temporary/sentinel" \
  "$XDG_DATA_HOME/willow-linux-bridge/.managed-by-willow-linux-bridge"
if "$repo_root/install.sh" --dry-run --no-activate >/dev/null 2>&1; then
  printf '%s\n' 'installer accepted a symlink marker' >&2
  exit 1
fi
if "$repo_root/uninstall.sh" --no-activate >/dev/null 2>&1; then
  printf '%s\n' 'uninstaller accepted a symlink marker' >&2
  exit 1
fi
[[ "$(<"$temporary/sentinel")" == sentinel-must-not-change ]]

# A file changed after installation belongs to the user and must be preserved.
rm -rf -- "$XDG_DATA_HOME/willow-linux-bridge"
data_root="$XDG_DATA_HOME/willow-linux-bridge"
config_root="$XDG_CONFIG_HOME/willow-linux-bridge"
application="$XDG_DATA_HOME/applications/willow-voice.desktop"
mkdir -m0700 -p "$data_root" "$config_root" "$(dirname -- "$application")"
printf '%s\n' 'willow-linux-bridge 0.1.0' \
  >"$data_root/.managed-by-willow-linux-bridge"
printf '%s\n' 'original installer content' >"$application"
original_hash=$(sha256sum "$application" | awk '{print $1}')
printf '%s\t%s\n' "$original_hash" "$application" \
  >"$config_root/installed-files.sha256"
printf '%s\n' 'user-modified content' >"$application"
"$repo_root/uninstall.sh" --no-activate >/dev/null
[[ "$(<"$application")" == 'user-modified content' ]]
if "$repo_root/install.sh" --dry-run --no-activate >/dev/null 2>&1; then
  printf '%s\n' 'reinstall would overwrite a preserved modified file' >&2
  exit 1
fi

rm -f -- "$application"
mkdir -p "$HOME/.local/bin"
ln -s /usr/bin/false "$HOME/.local/bin/willow-voice-linux"
if "$repo_root/install.sh" --dry-run --no-activate >/dev/null 2>&1; then
  printf '%s\n' 'reinstall would overwrite a foreign command link' >&2
  exit 1
fi

# Purging while retaining system policy must not strand an unmarked root.
rm -rf -- "$data_root" "$config_root" "$HOME/.local/bin"
mkdir -m0700 "$data_root"
printf '%s\n' 'willow-linux-bridge 0.1.0' >"$data_root/.managed-by-willow-linux-bridge"
printf '%s\n' rule modules >"$data_root/uinput-owned"
"$repo_root/uninstall.sh" --no-activate --purge-data >/dev/null
[[ ! -e "$data_root" ]]

# Unexpected user files are preserved with a recognized marker, never orphaned.
mkdir -m0700 "$data_root"
printf '%s\n' 'willow-linux-bridge 0.1.0' >"$data_root/.managed-by-willow-linux-bridge"
printf '%s\n' 'keep me' >"$data_root/user-file"
"$repo_root/uninstall.sh" --no-activate --purge-data >/dev/null
[[ -f "$data_root/user-file" ]]
[[ "$(<"$data_root/.managed-by-willow-linux-bridge")" == preserved-data-only ]]

printf '%s\n' 'marker and modified-file safety: ok'
