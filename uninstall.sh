#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

purge_data=0
remove_uinput=0
no_activate=0

usage() {
  cat <<'EOF'
Usage: willow-linux-uninstall [options]

Options:
  --purge-data     Also delete the Wine prefix, login, settings, and transcripts
  --remove-uinput  Remove this installer's system udev/modules-load files
  --no-activate    Staging/test use: do not call systemd or xdg-mime
  -h, --help       Show this help

Without --purge-data, private Willow account data is preserved.
EOF
}

die() {
  printf 'uninstall.sh: %s\n' "$*" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --purge-data) purge_data=1 ;;
    --remove-uinput) remove_uinput=1 ;;
    --no-activate) no_activate=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
  shift
done

(( EUID != 0 )) || die 'run as your desktop user, not root'
if (( remove_uinput == 1 )) && ! command -v sudo >/dev/null 2>&1; then
  die 'sudo is required by --remove-uinput; install and configure sudo first'
fi

xdg_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
xdg_config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
bin_home="${XDG_BIN_HOME:-$HOME/.local/bin}"
data_root="$xdg_data_home/willow-linux-bridge"
config_root="$xdg_config_home/willow-linux-bridge"
marker="$data_root/.managed-by-willow-linux-bridge"
libexec_dir="$data_root/current/libexec"

[[ -d "$data_root" && ! -L "$data_root" && -O "$data_root" \
    && -f "$marker" && ! -L "$marker" && -O "$marker" ]] \
  || die "no safely managed Willow Linux bridge was found at $data_root"
IFS= read -r marker_value <"$marker" || true
case "$marker_value" in
  'willow-linux-bridge 0.1.0'|'installing willow-linux-bridge 0.1.0'|'preserved-data-only') ;;
  *) die "unrecognized install marker in $data_root" ;;
esac
if [[ -e "$config_root" || -L "$config_root" ]]; then
  [[ -d "$config_root" && ! -L "$config_root" && -O "$config_root" ]] \
    || die "unsafe configuration root: $config_root"
fi

script_path=$(readlink -f -- "${BASH_SOURCE[0]}")
script_dir=$(cd -- "$(dirname -- "$script_path")" && pwd -P)
if [[ -f "$script_dir/../share/70-willow-uinput.rules" ]]; then
  rule_source="$script_dir/../share/70-willow-uinput.rules"
  modules_source="$script_dir/../share/willow-uinput.conf"
elif [[ -f "$script_dir/data/udev/70-willow-uinput.rules" ]]; then
  rule_source="$script_dir/data/udev/70-willow-uinput.rules"
  modules_source="$script_dir/data/modules-load/willow-uinput.conf"
else
  rule_source=''
  modules_source=''
fi

if (( no_activate == 0 )); then
  if [[ -x "$libexec_dir/willow-dictate" ]]; then
    "$libexec_dir/willow-dictate" reset >/dev/null 2>&1 || true
  fi
  systemctl --user disable --now willow-dictate-ptt.service willow-ydotoold.service \
    willow-voice.service \
    >/dev/null 2>&1 || true
  for unit in willow-dictate-ptt.service willow-ydotoold.service willow-voice.service; do
    unit_state=$(systemctl --user show --property=ActiveState --value "$unit" 2>/dev/null || true)
    case "$unit_state" in
      inactive|failed) ;;
      *) die "user service did not stop safely: $unit (${unit_state:-unknown})" ;;
    esac
  done
  if [[ -x "$libexec_dir/willow-voice-linux" ]]; then
    "$libexec_dir/willow-voice-linux" --stop >/dev/null 2>&1 || true
  fi
  if command -v wineserver >/dev/null 2>&1 && [[ -d "$data_root/wineprefix" ]]; then
    WINEPREFIX="$data_root/wineprefix" timeout 15s wineserver -w >/dev/null 2>&1 \
      || die 'Willow Wine processes did not stop; prefix was not removed'
  fi
  if [[ -x "$libexec_dir/willow-dictate-ptt" ]]; then
    "$libexec_dir/willow-dictate-ptt" --unregister >/dev/null 2>&1 || true
  fi

  current_handler=$(xdg-mime query default x-scheme-handler/willow 2>/dev/null || true)
  if [[ "$current_handler" == willow-voice-url.desktop ]]; then
    previous_handler=''
    if [[ -f "$config_root/previous-willow-handler" ]]; then
      IFS= read -r previous_handler <"$config_root/previous-willow-handler" || true
    fi
    if [[ "$previous_handler" =~ ^[A-Za-z0-9._+-]+\.desktop$ ]]; then
      xdg-mime default "$previous_handler" x-scheme-handler/willow
    else
      python3 - "$xdg_config_home/mimeapps.list" \
        "$xdg_data_home/applications/mimeapps.list" <<'PY'
import os
import sys
import tempfile

key = "x-scheme-handler/willow"
owned = "willow-voice-url.desktop"
for path in sys.argv[1:]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
    except FileNotFoundError:
        continue
    changed = False
    output = []
    for line in lines:
        if not line.startswith(key + "="):
            output.append(line)
            continue
        values = [value for value in line.split("=", 1)[1].strip().split(";") if value]
        filtered = [value for value in values if value != owned]
        if filtered != values:
            changed = True
        if filtered:
            output.append(key + "=" + ";".join(filtered) + ";\n")
    if changed:
        descriptor, temporary = tempfile.mkstemp(prefix="willow-mime-", dir=os.path.dirname(path))
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.writelines(output)
        os.replace(temporary, path)
PY
    fi
  fi
fi

if (( remove_uinput == 1 )); then
  [[ -n "$rule_source" && -n "$modules_source" ]] \
    || die 'cannot locate the installer-owned uinput files for comparison'
  uinput_owned_file="$data_root/uinput-owned"
  rule_owned=0
  modules_owned=0
  if [[ -f "$uinput_owned_file" && ! -L "$uinput_owned_file" && -O "$uinput_owned_file" ]]; then
    grep -Fxq rule "$uinput_owned_file" && rule_owned=1 || true
    grep -Fxq modules "$uinput_owned_file" && modules_owned=1 || true
  fi
  if (( rule_owned == 1 )) \
      && sudo cmp -s -- "$rule_source" /etc/udev/rules.d/70-willow-uinput.rules; then
    sudo rm -f -- /etc/udev/rules.d/70-willow-uinput.rules
  fi
  if (( modules_owned == 1 )) \
      && sudo cmp -s -- "$modules_source" /etc/modules-load.d/willow-uinput.conf; then
    sudo rm -f -- /etc/modules-load.d/willow-uinput.conf
  fi
  sudo udevadm control --reload-rules
  sudo udevadm trigger --action=change --subsystem-match=misc --sysname-match=uinput || true
  sudo udevadm settle || true
  rm -f -- "$uinput_owned_file"
fi

remove_owned_link() {
  local link="$1" expected="$2" target=''
  if [[ -L "$link" ]]; then
    target=$(readlink -- "$link")
    [[ "$target" == "$expected" ]] && rm -f -- "$link"
  fi
}
remove_owned_link "$bin_home/willow-voice-linux" "$libexec_dir/willow-voice-linux"
remove_owned_link "$bin_home/willow-dictate" "$libexec_dir/willow-dictate"
remove_owned_link "$bin_home/willow-doctor" "$libexec_dir/willow-doctor"
remove_owned_link "$bin_home/willow-linux-uninstall" "$libexec_dir/uninstall.sh"

manifest="$config_root/installed-files.sha256"
if [[ -f "$manifest" && ! -L "$manifest" && -O "$manifest" ]]; then
  while IFS=$'\t' read -r expected_hash managed_file; do
    case "$managed_file" in
      "$xdg_data_home/applications/willow-voice.desktop"|\
      "$xdg_data_home/applications/willow-voice-url.desktop"|\
      "$xdg_data_home/applications/willow-dictate-ptt.desktop"|\
      "$xdg_config_home/systemd/user/willow-dictate-ptt.service"|\
      "$xdg_config_home/systemd/user/willow-ydotoold.service"|\
      "$xdg_config_home/systemd/user/willow-voice.service")
        if [[ -f "$managed_file" && ! -L "$managed_file" && -O "$managed_file" \
            && "$(sha256sum -- "$managed_file" | awk '{print $1}')" == "$expected_hash" ]]; then
          rm -f -- "$managed_file"
        elif [[ -e "$managed_file" || -L "$managed_file" ]]; then
          printf 'Preserved modified file: %s\n' "$managed_file" >&2
        fi
        ;;
      *) die "unsafe path in install manifest: $managed_file" ;;
    esac
  done <"$manifest"
else
  printf '%s\n' 'Install manifest missing; desktop and service files were preserved.' >&2
fi

rm -f -- "$data_root/current"
rm -rf -- "$data_root/releases"
rm -rf -- "$config_root"

if (( purge_data == 1 )); then
  prefix="$data_root/wineprefix"
  if [[ -e "$prefix" ]]; then
    [[ -d "$prefix" && ! -L "$prefix" && -O "$prefix" ]] \
      || die "refusing unsafe Wine prefix: $prefix"
    rm -rf -- "$prefix"
  fi
  rm -f -- "$data_root/uinput-owned"
  rm -f -- "$marker"
  if ! rmdir -- "$data_root" 2>/dev/null; then
    temporary_marker=$(mktemp "$data_root/marker.XXXXXX")
    printf '%s\n' 'preserved-data-only' >"$temporary_marker"
    chmod 0600 -- "$temporary_marker"
    mv -f -- "$temporary_marker" "$marker"
    printf 'Preserved unexpected files under %s; the directory remains safely managed.\n' \
      "$data_root" >&2
  fi
else
  temporary_marker=$(mktemp "$data_root/marker.XXXXXX")
  printf '%s\n' 'preserved-data-only' >"$temporary_marker"
  chmod 0600 -- "$temporary_marker"
  mv -f -- "$temporary_marker" "$marker"
fi

if (( no_activate == 0 )); then
  update-desktop-database "$xdg_data_home/applications" >/dev/null 2>&1 || true
  systemctl --user daemon-reload
fi

printf '%s\n' 'Willow Linux bridge removed.'
if (( purge_data == 0 )); then
  printf 'Private Willow data was preserved at %s/wineprefix\n' "$data_root"
fi
