# AGY Mac Control

English | [中文](README.md)

Lets **Google Antigravity** agents see and operate apps on your Mac (screenshots, mouse, keyboard) — while **you can watch every step and press Esc to stop it at any time**.

> Not affiliated with Google. Antigravity's own computer-use feature isn't available to everyone yet; this is a safe, transparent stopgap until it is.

## What you see

While the agent is working:

- 🔵 **A glowing blue border** around the screen (fades out 4 s after it stops)
- 💬 **A status pill at the top** showing the current action, e.g. "🖱 点击 (300, 200)", plus "press Esc to stop"
- ⭕ **A ripple** where it clicks
- 🖱 **Smooth cursor movement** instead of teleporting

These overlays are **excluded from the agent's own screenshots** (`sharingType = .none`) and are click-through.

## Safety design

| Design | Why |
|---|---|
| **Permissions live in one small app** | Screen Recording and Accessibility are granted only to the menu-bar helper `AGY Mac Control`, not to Antigravity |
| **Localhost + token** | The helper listens on `127.0.0.1:47321` only; every request needs a random token (`~/Library/Application Support/agy-mac-control/token`, mode 600) |
| **Esc kill switch** | A global Esc pauses everything until you resume from the menu bar |
| **No stale clicks** | Clicking is refused before a screenshot, and refused if the frontmost app changed since the last screenshot |
| **Sensitive apps blocked** | No clicks/typing while Passwords or Keychain Access is frontmost |
| **Audit log** | Every action is logged to `helper.log` |
| **No auto-update, no network** | Built locally from source; nothing is downloaded or sent anywhere |

## Install

Requires macOS 14+, Antigravity desktop, and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/nishinoya070813-a11y/agy-mac-control.git
cd agy-mac-control
./install.sh
```

Then, **yourself**, in System Settings → Privacy & Security:

1. **Accessibility**: enable "AGY Mac Control"
2. **Screen & System Audio Recording**: enable "AGY Mac Control" (use "+" to add it from Applications if it's missing)
3. Menu bar 🖱 AG → Quit, then reopen `/Applications/AGY Mac Control.app`
4. Restart Antigravity

Uninstall: `./uninstall.sh`

## Usage

Just tell Antigravity what to do, e.g. "Open Calculator and compute 1234 × 56". Antigravity asks for permission the first time the tools are used.

Tools: `computer_screenshot`, `computer_click`, `computer_move`, `computer_drag`, `computer_scroll`, `computer_type`, `computer_key`, `computer_list_apps`, `computer_open_app`.

## Known limitations

- Main display only
- Ad-hoc signed: **re-enable both permissions after every rebuild** (the installer clears stale entries)
- Fixed port 47321
- Prefer Antigravity's official computer use once it's available to you

## Risks

This lets an AI operate your whole computer. Use it only while you're watching, never let it enter passwords or payment details, and press **Esc** the moment anything looks wrong.

## License

MIT
