# Troubleshooting

Start with:

```bash
willow-doctor
```

It reports only environment and service state. It does not print login tokens,
transcripts, clipboard contents, or Willow's private log.

## The shortcut does nothing

Check both services:

```bash
systemctl --user status willow-voice.service willow-dictate-ptt.service willow-ydotoold.service
```

Then reset and restart them:

```bash
willow-dictate reset
systemctl --user restart willow-ydotoold.service willow-dictate-ptt.service
```

In **System Settings → Keyboard → Shortcuts**, search for **Willow
Push-to-Talk**. `Meta+Alt+D` is the default. Assign exactly one key sequence.

Also confirm that Willow's own Windows shortcut is **Ctrl+Windows**. The KDE
shortcut and Willow shortcut are two separate layers.

## `/dev/uinput` is not writable

Run the installer again with the narrow active-user rule:

```bash
./install.sh --configure-uinput
```

Then log out and back in. Verify:

```bash
test -w /dev/uinput && echo ready
```

Do not fix this with `chmod 666 /dev/uinput` or by adding your account to the
`input` group. Those grant broader, persistent access than this package needs.

## Willow records only while its window is focused

The Linux helper must be running, and Willow must use XWayland so `xdotool` can
target it without stealing focus:

```bash
systemctl --user restart willow-dictate-ptt.service
willow-voice-linux
```

Do not launch Willow with a separate native-Wayland Wine command; use the
installed launcher, which deliberately keeps Wine on X11/XWayland.

## The transcript is not pasted

Keep the destination field focused until transcription finishes. Ordinary
editors and browser fields accept Ctrl+V. Many terminals require Ctrl+Shift+V,
and secure/password fields intentionally reject synthetic pastes.

If Willow did not produce an exact recording ID, the bridge deliberately pastes
nothing. It never chooses the newest transcript as a fallback, because that can
insert an older dictation.

Restarting the services cancels old delivery workers:

```bash
willow-dictate reset
systemctl --user restart willow-dictate-ptt.service
```

## Old clipboard text appears

This package verifies that the clipboard exactly matches the current transcript
immediately before Ctrl+V. If old clipboard text still appears, first confirm
that these commands point into `willow-linux-bridge/current`, not an older
prototype:

```bash
readlink -f ~/.local/bin/willow-dictate
readlink -f ~/.local/bin/willow-voice-linux
```

Then run `willow-doctor` and restart both services. Avoid posting Willow's
transcript JSON or `main.log`; they can contain dictated text.

## A login callback opens Kate or says “Unknown protocol willow”

Check the handler:

```bash
xdg-mime query default x-scheme-handler/willow
```

It should print `willow-voice-url.desktop`. Repair it with:

```bash
xdg-mime default willow-voice-url.desktop x-scheme-handler/willow
```

Start Willow and repeat login. The handler accepts only the expected
`willow://login-callback` shape and rejects unrelated custom URLs.

## Logs for bridge failures

The bridge does not log transcript text or clipboard data. Service diagnostics
are available with:

```bash
journalctl --user -u willow-dictate-ptt.service -u willow-ydotoold.service -b
```

Willow's own Wine/AppData logs are private and may include dictated text; do not
share them without reviewing and redacting them first.
