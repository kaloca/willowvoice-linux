#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

bridge_version=0.1.0
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# shellcheck source=versions/willow.env
source "$repo_root/versions/willow.env"

install_dependencies=0
configure_uinput=0
dry_run=0
no_activate=0
skip_dependency_check=0
force_unsupported=0
installer_file=''

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Install the personal Willow Voice compatibility bridge for Arch Linux,
KDE Plasma 6, Wayland, and x86-64.

Options:
  --install-deps          Install missing Arch packages with sudo/pacman
  --configure-uinput      Install a narrow udev rule for active-user auto-paste
  --installer-file PATH   Use a local installer (it must match the pinned hash)
  --no-activate           Install files but do not register/start anything
  --dry-run               Show checks and destinations without changing files
  --doctor                Run the installed diagnostic helper
  --force-unsupported     Bypass OS/session guardrails (unsupported)
  --skip-dependency-check Staging/test use only
  -h, --help              Show this help
EOF
}

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

while (( $# > 0 )); do
  case "$1" in
    --install-deps) install_dependencies=1 ;;
    --configure-uinput) configure_uinput=1 ;;
    --installer-file)
      shift
      (( $# > 0 )) || die '--installer-file requires a path'
      installer_file="$1"
      ;;
    --no-activate) no_activate=1 ;;
    --dry-run) dry_run=1 ;;
    --skip-dependency-check) skip_dependency_check=1 ;;
    --force-unsupported) force_unsupported=1 ;;
    --doctor)
      doctor="${XDG_DATA_HOME:-$HOME/.local/share}/willow-linux-bridge/current/libexec/willow-doctor"
      [[ -x "$doctor" ]] || die 'the bridge is not installed'
      exec "$doctor"
      ;;
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

(( EUID != 0 )) || die 'run this installer as your desktop user, not root'
[[ -n "${HOME:-}" && "$HOME" == /* ]] || die 'HOME must be an absolute path'

xdg_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
xdg_config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
xdg_cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
bin_home="${XDG_BIN_HOME:-$HOME/.local/bin}"
data_root="$xdg_data_home/willow-linux-bridge"
config_root="$xdg_config_home/willow-linux-bridge"
applications_dir="$xdg_data_home/applications"
systemd_dir="$xdg_config_home/systemd/user"
marker="$data_root/.managed-by-willow-linux-bridge"

for path_value in "$xdg_data_home" "$xdg_config_home" "$xdg_cache_home" "$bin_home"; do
  [[ "$path_value" =~ ^/[A-Za-z0-9_./+@:=,-]+$ ]] \
    || die "unsafe XDG path: $path_value"
done

bridge_revision=$(
  cd -- "$repo_root"
  find CMakeLists.txt src bin data versions uninstall.sh -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    | sha256sum \
    | cut -c1-12
)
release_id="bridge-${bridge_version}-${bridge_revision}_willow-${WILLOW_BUILD_ID}-${WILLOW_INSTALLER_SHA256:0:12}"
release_dir="$data_root/releases/$release_id"
current_dir="$data_root/current"
libexec_dir="$current_dir/libexec"

legacy_paths=(
  "$HOME/.local/opt/willow-voice/app/Willow Voice.exe"
  "$HOME/.local/bin/willow-voice-linux"
  "$HOME/.local/bin/willow-dictate-toggle"
  "$HOME/.local/bin/willow-dictate-ptt"
  "$xdg_config_home/systemd/user/willow-dictate-ptt.service"
  "$xdg_config_home/systemd/user/willow-ydotoold.service"
)
owned_destinations=(
  "$bin_home/willow-voice-linux"
  "$bin_home/willow-dictate"
  "$bin_home/willow-doctor"
  "$bin_home/willow-linux-uninstall"
  "$applications_dir/willow-voice.desktop"
  "$applications_dir/willow-voice-url.desktop"
  "$applications_dir/willow-dictate-ptt.desktop"
  "$systemd_dir/willow-dictate-ptt.service"
  "$systemd_dir/willow-ydotoold.service"
  "$systemd_dir/willow-voice.service"
)
managed_regular_destinations=(
  "$applications_dir/willow-voice.desktop"
  "$applications_dir/willow-voice-url.desktop"
  "$applications_dir/willow-dictate-ptt.desktop"
  "$systemd_dir/willow-dictate-ptt.service"
  "$systemd_dir/willow-ydotoold.service"
  "$systemd_dir/willow-voice.service"
)

verify_managed_destinations() {
  local manifest_file="$config_root/installed-files.sha256"
  local expected_hash managed_file current_hash
  [[ -d "$config_root" && ! -L "$config_root" && -O "$config_root" \
      && -f "$manifest_file" && ! -L "$manifest_file" && -O "$manifest_file" ]] \
    || die 'managed install manifest is missing or unsafe'
  [[ "$(wc -l <"$manifest_file")" -eq "${#managed_regular_destinations[@]}" ]] \
    || die 'managed install manifest has an unexpected number of entries'
  for managed_file in "${managed_regular_destinations[@]}"; do
    expected_hash=$(awk -F $'\t' -v path="$managed_file" '$2 == path {print $1}' "$manifest_file")
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] \
      || die "managed install manifest is missing: $managed_file"
    if [[ -e "$managed_file" || -L "$managed_file" ]]; then
      [[ -f "$managed_file" && ! -L "$managed_file" && -O "$managed_file" ]] \
        || die "managed file was replaced: $managed_file"
      current_hash=$(sha256sum -- "$managed_file" | awk '{print $1}')
      [[ "$current_hash" == "$expected_hash" ]] \
        || die "managed file was modified; move it before reinstalling: $managed_file"
    fi
  done

  local link expected target
  while IFS=$'\t' read -r link expected; do
    if [[ -e "$link" || -L "$link" ]]; then
      [[ -L "$link" ]] || die "managed command was replaced: $link"
      target=$(readlink -- "$link")
      [[ "$target" == "$expected" ]] || die "managed command link was modified: $link"
    fi
  done <<EOF
$bin_home/willow-voice-linux	$libexec_dir/willow-voice-linux
$bin_home/willow-dictate	$libexec_dir/willow-dictate
$bin_home/willow-doctor	$libexec_dir/willow-doctor
$bin_home/willow-linux-uninstall	$libexec_dir/uninstall.sh
EOF
}

if [[ -e "$data_root" || -L "$data_root" ]]; then
  [[ -d "$data_root" && ! -L "$data_root" && -O "$data_root" ]] \
    || die "install root must be an owned, non-symlinked directory: $data_root"
  [[ -f "$marker" && ! -L "$marker" && -O "$marker" ]] \
    || die "unmanaged path already exists: $data_root"
  IFS= read -r marker_value <"$marker" || true
  case "$marker_value" in
    'willow-linux-bridge 0.1.0'|'installing willow-linux-bridge 0.1.0'|'preserved-data-only') ;;
    *) die "unrecognized install marker in $data_root" ;;
  esac
  if [[ "$marker_value" == preserved-data-only ]]; then
    for destination in "${owned_destinations[@]}"; do
      if [[ -e "$destination" || -L "$destination" ]]; then
        die "preserved file would be overwritten; move it first: $destination"
      fi
    done
  elif [[ "$marker_value" == 'willow-linux-bridge 0.1.0' ]]; then
    verify_managed_destinations
  elif [[ -f "$config_root/installed-files.sha256" ]]; then
    verify_managed_destinations
  fi
else
  if [[ -e "$config_root" || -L "$config_root" ]]; then
    die "unmanaged configuration path already exists: $config_root"
  fi
  for legacy in "${legacy_paths[@]}"; do
    if [[ -e "$legacy" || -L "$legacy" ]]; then
      die "an existing Willow bridge was found at $legacy; this installer will not replace it"
    fi
  done
  for destination in "${owned_destinations[@]}"; do
    if [[ -e "$destination" || -L "$destination" ]]; then
      die "refusing to overwrite unmanaged file: $destination"
    fi
  done
fi

if (( force_unsupported == 0 )); then
  [[ "$(uname -m)" == x86_64 ]] || die 'this release supports x86-64 only'
  [[ -e /etc/arch-release && -x /usr/bin/pacman ]] \
    || die 'this release supports Arch Linux only; see README.md'
  if [[ -n "${XDG_SESSION_TYPE:-}" && "${XDG_SESSION_TYPE}" != wayland ]]; then
    die 'run this release in a Wayland session'
  fi
  if [[ -n "${XDG_CURRENT_DESKTOP:-}" && "${XDG_CURRENT_DESKTOP}" != *KDE* \
      && "${KDE_FULL_SESSION:-}" != true ]]; then
    die 'this release requires KDE Plasma 6'
  fi
  if (( no_activate == 0 )) && [[ -z "${DISPLAY:-}" ]]; then
    die 'XWayland DISPLAY is unavailable; install from the Plasma session or use --no-activate'
  fi
fi

required_commands=(
  cmp cmake ctest ninja c++ wine wineserver xdotool ydotool ydotoold wl-copy wl-paste
  python3 curl 7z xdg-mime update-desktop-database systemctl flock sha256sum Xwayland
)
arch_packages=(
  cmake ninja gcc diffutils qt6-base kglobalaccel kglobalacceld wine xdotool ydotool wl-clipboard
  python curl 7zip desktop-file-utils xdg-utils xorg-xwayland
)
missing_commands=()
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
done
missing_packages=()
if (( skip_dependency_check == 0 )) && command -v pacman >/dev/null 2>&1; then
  mapfile -t missing_packages < <(pacman -T "${arch_packages[@]}" 2>/dev/null || true)
fi

if (( dry_run == 1 )); then
  printf 'Supported target : Arch Linux, Plasma 6, Wayland/XWayland, x86-64\n'
  printf 'Install root     : %s\n' "$data_root"
  printf 'Release          : %s\n' "$release_id"
  printf 'Willow build     : %s\n' "$WILLOW_BUILD_ID"
  printf 'Activation       : %s\n' "$([[ $no_activate == 1 ]] && printf disabled || printf enabled)"
  if (( ${#missing_commands[@]} > 0 || ${#missing_packages[@]} > 0 )); then
    printf 'Missing commands : %s\n' "${missing_commands[*]}"
    printf 'Missing packages : %s\n' "${missing_packages[*]}"
    printf 'Dependency fix   : ./install.sh --install-deps --configure-uinput\n'
  else
    printf 'Dependencies     : present\n'
  fi
  exit 0
fi

if (( install_dependencies == 1 || (no_activate == 0 && configure_uinput == 1) )) \
    && ! command -v sudo >/dev/null 2>&1; then
  die 'sudo is required for dependency or uinput setup; install and configure sudo first'
fi

if (( skip_dependency_check == 0 \
    && (${#missing_commands[@]} > 0 || ${#missing_packages[@]} > 0) )); then
  if (( install_dependencies == 0 )); then
    die "missing commands: ${missing_commands[*]}; rerun with --install-deps"
  fi
  note 'Installing required Arch packages (sudo is used only for pacman)'
  sudo pacman -S --needed -- "${arch_packages[@]}"
  missing_commands=()
  for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
  done
  (( ${#missing_commands[@]} == 0 )) \
    || die "dependencies remain unavailable: ${missing_commands[*]}"
  mapfile -t missing_packages < <(pacman -T "${arch_packages[@]}" 2>/dev/null || true)
  (( ${#missing_packages[@]} == 0 )) \
    || die "Arch packages remain unavailable: ${missing_packages[*]}"
fi

needs_relogin=0
new_data_root=0
configure_uinput_access() {
  local rule_destination=/etc/udev/rules.d/70-willow-uinput.rules
  local modules_destination=/etc/modules-load.d/willow-uinput.conf
  local owned=() prior_owned=() temporary_owned
  note 'Installing active-user /dev/uinput access rule'
  if sudo test -L "$rule_destination" || sudo test -L "$modules_destination"; then
    die 'refusing symlinked udev or modules-load destination'
  fi
  if sudo test -e "$rule_destination"; then
    sudo cmp -s -- "$repo_root/data/udev/70-willow-uinput.rules" "$rule_destination" \
      || die "refusing to replace existing $rule_destination"
  fi
  if sudo test -e "$modules_destination"; then
    sudo cmp -s -- "$repo_root/data/modules-load/willow-uinput.conf" "$modules_destination" \
      || die "refusing to replace existing $modules_destination"
  fi
  if ! sudo test -e "$rule_destination"; then
    sudo install -Dm0644 "$repo_root/data/udev/70-willow-uinput.rules" "$rule_destination"
    owned+=(rule)
  fi
  if ! sudo test -e "$modules_destination"; then
    sudo install -Dm0644 "$repo_root/data/modules-load/willow-uinput.conf" "$modules_destination"
    owned+=(modules)
  fi
  if [[ -f "$data_root/uinput-owned" && ! -L "$data_root/uinput-owned" ]]; then
    mapfile -t prior_owned <"$data_root/uinput-owned"
    owned+=("${prior_owned[@]}")
  fi
  temporary_owned=$(mktemp "$data_root/uinput-owned.XXXXXX")
  printf '%s\n' "${owned[@]}" | sort -u >"$temporary_owned"
  mv -f -- "$temporary_owned" "$data_root/uinput-owned"
  sudo modprobe uinput
  sudo udevadm control --reload-rules
  sudo udevadm trigger --action=change --subsystem-match=misc --sysname-match=uinput || true
  sudo udevadm settle || true
}

if (( no_activate == 0 && configure_uinput == 0 )) && [[ ! -w /dev/uinput ]]; then
  die '/dev/uinput is not writable; rerun with --configure-uinput'
fi

if [[ -e "$xdg_cache_home" || -L "$xdg_cache_home" ]]; then
  [[ -d "$xdg_cache_home" && ! -L "$xdg_cache_home" && -O "$xdg_cache_home" ]] \
    || die "cache root must be an owned, non-symlinked directory: $xdg_cache_home"
else
  mkdir -p -m0700 -- "$xdg_cache_home"
fi
chmod 0700 -- "$xdg_cache_home" 2>/dev/null || true
work_dir=$(mktemp -d "$xdg_cache_home/willow-linux-install.XXXXXX")
cleanup() {
  rm -rf -- "$work_dir"
  if (( new_data_root == 1 )) && [[ ! -f "$marker" ]]; then
    rm -rf -- "$data_root"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n "$installer_file" ]]; then
  installer_source=$(realpath -e -- "$installer_file")
  [[ -f "$installer_source" && ! -L "$installer_source" ]] \
    || die 'local installer is not a regular, non-symlinked file'
  installer_file="$work_dir/willow-voice-installer.exe"
  install -m0600 -- "$installer_source" "$installer_file"
  note 'Using the supplied pinned Willow installer'
else
  installer_file="$work_dir/willow-voice-installer.exe"
  note 'Downloading the pinned official Willow Windows installer'
  curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --output "$installer_file" "$WILLOW_INSTALLER_URL"
fi

actual_sha=$(sha256sum -- "$installer_file" | awk '{print $1}')
[[ "$actual_sha" == "$WILLOW_INSTALLER_SHA256" ]] \
  || die "Willow installer checksum mismatch (got $actual_sha)"
note 'Installer checksum verified'

mkdir -p -- "$work_dir/nsis" "$work_dir/app"
7z e -y "-o$work_dir/nsis" "$installer_file" '$PLUGINSDIR/app-64.7z' >/dev/null
[[ -f "$work_dir/nsis/app-64.7z" ]] || die 'pinned installer payload was not found'
7z x -y "-o$work_dir/app" "$work_dir/nsis/app-64.7z" >/dev/null
[[ -f "$work_dir/app/Willow Voice.exe" ]] || die 'Willow Voice.exe is missing from payload'
[[ -f "$work_dir/app/resources/app.asar" ]] || die 'resources/app.asar is missing from payload'
[[ -f "$work_dir/app/resources/tray/WillowTree.png" ]] || die 'Willow tray icon is missing from payload'

note 'Building the KDE shortcut helper locally'
cmake -S "$repo_root" -B "$work_dir/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
cmake --build "$work_dir/build"
ctest --test-dir "$work_dir/build" --output-on-failure

stage_release="$work_dir/release"
mkdir -p -- "$stage_release/libexec" "$stage_release/share"
mv -- "$work_dir/app" "$stage_release/app"
install -m0755 "$work_dir/build/willow-dictate-ptt" "$stage_release/libexec/"
install -m0755 \
  "$repo_root/bin/willow-dictate" \
  "$repo_root/bin/willow-doctor" \
  "$repo_root/bin/willow-voice-linux" \
  "$repo_root/uninstall.sh" \
  "$stage_release/libexec/"
install -m0644 "$repo_root/data/udev/70-willow-uinput.rules" "$stage_release/share/"
install -m0644 "$repo_root/data/modules-load/willow-uinput.conf" "$stage_release/share/"
install -m0644 "$repo_root/versions/willow.env" "$stage_release/"
printf '%s\n' "$bridge_version" >"$stage_release/bridge-version"
chmod -R go-rwx -- "$stage_release"
(cd -- "$stage_release" && find . -type f ! -name release-manifest.sha256 -print0 \
  | sort -z | xargs -0 sha256sum >release-manifest.sha256)
chmod 0600 -- "$stage_release/release-manifest.sha256"

note "Installing release $release_id"
write_marker() {
  local value="$1" temporary
  temporary=$(mktemp "$data_root/marker.XXXXXX")
  printf '%s\n' "$value" >"$temporary"
  chmod 0600 -- "$temporary"
  mv -f -- "$temporary" "$marker"
}

if [[ ! -d "$data_root" ]]; then
  mkdir -p -m0700 -- "$data_root"
  new_data_root=1
fi
[[ -d "$data_root" && ! -L "$data_root" && -O "$data_root" ]] \
  || die "install root must be an owned, non-symlinked directory: $data_root"
chmod 0700 -- "$data_root"
write_marker 'installing willow-linux-bridge 0.1.0'

for managed_directory in "$data_root/releases" "$data_root/wineprefix"; do
  if [[ -e "$managed_directory" || -L "$managed_directory" ]]; then
    [[ -d "$managed_directory" && ! -L "$managed_directory" && -O "$managed_directory" ]] \
      || die "unsafe managed directory: $managed_directory"
  fi
done
mkdir -p -- "$data_root/releases" "$data_root/wineprefix" "$config_root" \
  "$applications_dir" "$systemd_dir" "$bin_home"
[[ -d "$config_root" && ! -L "$config_root" && -O "$config_root" ]] \
  || die "configuration root must be an owned, non-symlinked directory: $config_root"
chmod 0700 -- "$config_root"
chmod 0700 -- "$data_root/wineprefix"

if [[ ! -d "$release_dir" ]]; then
  incoming="$data_root/releases/.incoming-$release_id-$$"
  cp -a -- "$stage_release" "$incoming"
  mv -- "$incoming" "$release_dir"
elif [[ ! -L "$release_dir" && -f "$release_dir/release-manifest.sha256" ]] \
    && (cd -- "$release_dir" && sha256sum --status -c release-manifest.sha256); then
  :
else
  die "existing managed release failed verification: $release_dir"
fi
[[ ! -e "$current_dir" || -L "$current_dir" ]] \
  || die "managed current path is not a symlink: $current_dir"
temporary_link="$data_root/.current-$$"
ln -s "releases/$release_id" "$temporary_link"
mv -Tf -- "$temporary_link" "$current_dir"

render_template() {
  local source_file="$1" destination_file="$2"
  python3 - "$source_file" "$destination_file" "$libexec_dir" \
    "$current_dir/app/resources/tray/WillowTree.png" <<'PY'
import os
import sys
import tempfile

source, destination, libexec, icon = sys.argv[1:]
with open(source, "r", encoding="utf-8") as handle:
    content = handle.read()
content = content.replace("@LIBEXEC@", libexec).replace("@ICON@", icon)
descriptor, temporary = tempfile.mkstemp(prefix="willow-template-", dir=os.path.dirname(destination))
with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(content)
os.chmod(temporary, 0o644)
os.replace(temporary, destination)
PY
}

render_template "$repo_root/data/applications/willow-voice.desktop.in" \
  "$applications_dir/willow-voice.desktop"
render_template "$repo_root/data/applications/willow-voice-url.desktop.in" \
  "$applications_dir/willow-voice-url.desktop"
render_template "$repo_root/data/applications/willow-dictate-ptt.desktop.in" \
  "$applications_dir/willow-dictate-ptt.desktop"
render_template "$repo_root/data/systemd/user/willow-dictate-ptt.service.in" \
  "$systemd_dir/willow-dictate-ptt.service"
render_template "$repo_root/data/systemd/user/willow-ydotoold.service.in" \
  "$systemd_dir/willow-ydotoold.service"
render_template "$repo_root/data/systemd/user/willow-voice.service.in" \
  "$systemd_dir/willow-voice.service"

install_link() {
  local target="$1" link="$2" temporary
  temporary="$link.new-$$"
  ln -s -- "$target" "$temporary"
  mv -Tf -- "$temporary" "$link"
}
install_link "$libexec_dir/willow-voice-linux" "$bin_home/willow-voice-linux"
install_link "$libexec_dir/willow-dictate" "$bin_home/willow-dictate"
install_link "$libexec_dir/willow-doctor" "$bin_home/willow-doctor"
install_link "$libexec_dir/uninstall.sh" "$bin_home/willow-linux-uninstall"

write_private_file() {
  local destination="$1" temporary
  shift
  temporary=$(mktemp "$(dirname -- "$destination")/file.XXXXXX")
  printf '%s\n' "$@" >"$temporary"
  chmod 0600 -- "$temporary"
  mv -f -- "$temporary" "$destination"
}
write_private_file "$config_root/release-id" "$release_id"

managed_files=(
  "$applications_dir/willow-voice.desktop" \
  "$applications_dir/willow-voice-url.desktop" \
  "$applications_dir/willow-dictate-ptt.desktop" \
  "$systemd_dir/willow-dictate-ptt.service" \
  "$systemd_dir/willow-ydotoold.service" \
  "$systemd_dir/willow-voice.service"
)
installed_manifest=$(mktemp "$config_root/installed-files.XXXXXX")
for managed_file in "${managed_files[@]}"; do
  printf '%s\t%s\n' "$(sha256sum -- "$managed_file" | awk '{print $1}')" "$managed_file" \
    >>"$installed_manifest"
done
chmod 0600 -- "$installed_manifest"
mv -f -- "$installed_manifest" "$config_root/installed-files.sha256"

if (( no_activate == 0 )); then
  if (( configure_uinput == 1 )); then
    configure_uinput_access
  fi
  if [[ ! -w /dev/uinput ]]; then
    needs_relogin=1
  fi
  previous_handler_file="$config_root/previous-willow-handler"
  if [[ ! -f "$previous_handler_file" ]]; then
    previous_handler=$(xdg-mime query default x-scheme-handler/willow 2>/dev/null || true)
    [[ "$previous_handler" == willow-voice-url.desktop ]] && previous_handler=''
    write_private_file "$previous_handler_file" "$previous_handler"
  elif [[ -L "$previous_handler_file" || ! -O "$previous_handler_file" ]]; then
    die "unsafe previous-handler state: $previous_handler_file"
  fi
  update-desktop-database "$applications_dir"
  xdg-mime default willow-voice-url.desktop x-scheme-handler/willow
  systemctl --user daemon-reload
  systemctl --user enable willow-voice.service willow-ydotoold.service willow-dictate-ptt.service
  systemctl --user restart willow-voice.service
  if (( needs_relogin == 0 )); then
    systemctl --user restart willow-ydotoold.service willow-dictate-ptt.service
  fi
fi

write_marker 'willow-linux-bridge 0.1.0'

printf '\nInstalled Willow Linux bridge %s.\n' "$bridge_version"
printf 'Default push-to-talk shortcut: Meta+Alt+D (hold, then release).\n'
if (( no_activate == 1 )); then
  printf 'Activation was skipped. Files were installed but services and URI handling were not changed.\n'
elif (( needs_relogin == 1 )); then
  printf 'Log out and back in once so /dev/uinput access takes effect; services are already enabled.\n'
else
  printf 'Willow is starting. Log in, keep the target text field focused, and try the shortcut.\n'
fi
