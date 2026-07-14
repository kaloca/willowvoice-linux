# Willow Voice on KDE Linux

This is a personal compatibility package for running Willow Voice's Windows
client on Linux and using it as system-wide push-to-talk dictation. Hold a KDE
global shortcut, speak, release it, and the transcript is pasted into the
focused Linux application.

It is intentionally conservative: the Willow installer is downloaded from an
official, versioned URL and checked against a pinned hash; the Linux helpers are
built locally; and an uncertain recording never falls back to an older
transcript.

## Supported target

Version 0.1.0 supports exactly:

- x86-64 Arch Linux
- KDE Plasma 6
- a Wayland session with XWayland enabled
- systemd user services

Other distributions may be possible, but this installer does not pretend their
Wine, KDE Frameworks, or `ydotool` packages are interchangeable. It fails early
instead of installing an untested mix.

This project is unofficial and is not supported by Willow. It contains no
Willow binary, login, transcript, or Wine prefix. On installation it downloads
the official Willow Voice 2.1.8 Windows installer.

For upstream client/account guidance, use Willow's
[official download page](https://willowvoice.com/download) and
[installation guide](https://help.willowvoice.com/en/articles/10876111-install-and-setup-willow-voice-mac-windows).

## Clone it on another computer

On your other Arch computer, clone this repository and enter the project
directory:

```bash
git clone https://github.com/kaloca/willowvoice-linux.git
cd willowvoice-linux
```

You can inspect what the installer would do without changing anything:

```bash
./install.sh --dry-run
```

## Install

From a terminal inside the cloned directory, run:

```bash
./install.sh --install-deps --configure-uinput
```

The privileged options require a working `sudo` setup. The installer reports a
clear error before making changes if `sudo` is unavailable.

The installer itself must **not** be run with `sudo`. It asks for sudo only for
Arch packages and the two small `/dev/uinput` configuration files. The udev rule
uses logind's active-user access; it does not use world-writable permissions or
add you to the broad `input` group.

If the final message asks you to log out, log out and back in once. The services
are already enabled and will start with the new Plasma session.

The installer then:

1. checks the supported platform and required tools;
2. downloads and verifies the pinned official Willow installer;
3. extracts the Windows application without importing data from another PC;
4. builds the small KDE shortcut daemon from source;
5. registers the `willow://` login callback;
6. enables Willow autostart and the two private user services.

It installs per-user files under
`~/.local/share/willow-linux-bridge`, `~/.config`, and `~/.local/bin`.
Your Wine prefix is private (`0700`) and lives at
`~/.local/share/willow-linux-bridge/wineprefix`.

## First use

1. Let Willow open and sign in in the browser. The browser's `willow://` return
   link should now go back to Willow instead of Kate or KIO.
2. In Willow's settings, leave its Windows recording shortcut as
   **Ctrl+Windows**. The Linux bridge sends that combination directly to the
   Willow window.
3. Focus an ordinary text field in any Linux app.
4. Hold **Meta+Alt+D**, speak, and release. Keep that field focused until the
   transcript appears.

To change the Linux shortcut, open **System Settings → Keyboard → Shortcuts**,
search for **Willow Push-to-Talk**, and edit **Hold to dictate**. Keep exactly
one shortcut assigned; multiple bindings to one hold/release action can produce
ambiguous release events.

There are no bridge notifications. Transcript text is placed on the Wayland
clipboard as sensitive data, verified byte-for-byte before Ctrl+V, and cleared
after the paste only if it is still the bridge's text. A clipboard change you
make in the meantime is not erased.

## Useful commands

```bash
# Privacy-safe environment and service checks
willow-doctor

# Restart the bridge services
systemctl --user restart willow-ydotoold.service willow-dictate-ptt.service

# Release a possibly stuck Willow recording key and cancel old workers
willow-dictate reset

# Open Willow manually
willow-voice-linux
```

See [Troubleshooting](docs/TROUBLESHOOTING.md) for login callbacks, shortcut,
clipboard, and `/dev/uinput` problems.

## Updating

Running `./install.sh` again is safe and preserves the Wine prefix. This package
pins Willow 2.1.8 to an immutable official URL, so an upstream replacement
cannot silently enter the install. A future Willow release should be tested
first, then its versioned URL and SHA-256 can be updated in
[`versions/willow.env`](versions/willow.env).

## Uninstall

The normal uninstall removes the application and bridge while preserving your
Willow account, settings, and transcripts for a later reinstall:

```bash
willow-linux-uninstall
```

To erase the Wine prefix as well:

```bash
willow-linux-uninstall --purge-data
```

The active-user udev rule may be useful to other `ydotool` setups, so it is left
alone by default. Remove it only when wanted:

```bash
willow-linux-uninstall --purge-data --remove-uinput
```

The uninstaller restores the previous `willow://` handler when one existed and
only removes command links owned by this package.

## Important limitations and trust

- Willow must remain running. The installer starts it automatically at login.
- The target field must stay focused while transcription finishes. The bridge
  cannot safely identify every native Wayland application's focused widget.
- Auto-paste sends Ctrl+V. Some terminals require Ctrl+Shift+V, and password or
  protected fields may reject synthetic input.
- `ydotool` requires `/dev/uinput`. Giving the active user access to uinput also
  lets other processes running as that user synthesize keyboard input.
- Wine is a compatibility layer, not a security sandbox. The Windows client can
  access files that your Linux user can access, in addition to the microphone
  and network it needs.
- Willow's internal log and transcript formats are not a public Linux API. The
  bridge is pinned and fails closed, but a Willow update can require a bridge
  change.
- The one-time login callback code briefly exists in a process argument because
  that is how the upstream custom URL flow reaches the Windows client.

## Development checks

The normal local test suite never touches Willow, the real clipboard, uinput,
or the live Wine prefix:

```bash
sudo pacman -S --needed ripgrep
./tests/run.sh
```

`ripgrep` is used only by these source-level development checks; the installed
bridge does not need it at runtime.

`cmake` is intentionally build-only; `install.sh` owns the complete per-user
layout, rendered desktop files, services, pinned app payload, and uninstall
manifest. Do not use `cmake --install` as a substitute for the installer.

A full package test should use a fake HOME and `--no-activate`; the release in
this directory was tested that way with the pinned installer, including
install, preserved-data reinstall, and purge uninstall.
