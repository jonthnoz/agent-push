# Setup runbook — for the AI agent reading this

You (Codex, Claude Code, or any coding agent) are helping the user get **iPhone push
notifications when an AI coding agent finishes a turn or needs input**. Do this on the
user's **local machine**. Follow these steps precisely; ask before any change you're unsure of.

## 0. Preconditions
- Confirm `curl`, `jq`, and `openssl` are installed. If `jq` is missing, install it
  (macOS: `brew install jq`; Debian/Ubuntu: `sudo apt-get install -y jq`).
- The user needs the **Bark** iOS app: https://apps.apple.com/app/id1403753865
- Works on macOS and Linux. If the user is on Windows, they need WSL.

## 1. Collect two values from the user
1. **Bark URL** — have them open Bark and copy the device URL at the top
   (`https://api.day.app/XXXXXXXX`).
2. **Encryption key (recommended)** — have them open Bark → **Settings → Encryption**,
   choose **AES256 / CBC**, set a **32-character key**, and give you that key. If they
   decline encryption, skip it (content will transit Bark's server in plaintext).

## 2. Install the script + config
```sh
# from a clone of this repo (adjust path if cloned elsewhere)
mkdir -p ~/.config/agent-notify
cp config.env.example ~/.config/agent-notify/config.env
chmod 600 ~/.config/agent-notify/config.env
chmod +x notify.sh
```
Edit `~/.config/agent-notify/config.env`: set `BARK_URL`, and `BARK_KEY` if encrypting.
Note the **absolute path** to `notify.sh` (e.g. `~/git/agent-push/notify.sh`) — you need it below.

## 3. Wire the agents the user actually uses (ask which)
**Codex** — in `~/.codex/config.toml`:
```toml
notify = ["/ABS/PATH/notify.sh"]
```
If a `notify` line already exists, DON'T silently replace it — show the user, comment the old one out, confirm.

**Claude Code** — in `~/.claude/settings.json`, add under `"hooks"`:
```json
"Stop": [
  { "hooks": [ { "type": "command", "command": "/ABS/PATH/notify.sh" } ] }
],
"Notification": [
  { "hooks": [ { "type": "command", "command": "/ABS/PATH/notify.sh" } ] }
]
```
CRITICAL: **merge** into any existing `hooks` object — do not overwrite other hooks.
Validate the file is valid JSON afterwards (`jq . ~/.claude/settings.json`).

## 4. Test end-to-end
```sh
/ABS/PATH/notify.sh '{"type":"agent-turn-complete","last-assistant-message":"agent-push test ✅"}'
```
Ask the user whether a banner arrived on their phone.

## 5. Troubleshoot only if the test fails
- Direct check: `curl -d "raw test" "$BARK_URL"` (reads their URL) — should return `{"code":200,...}`.
- Banner shows for the raw test but not the encrypted one → the app's key/algorithm must match
  `BARK_KEY` exactly (32 chars ⇒ AES256/CBC).
- Nothing at all, even raw → the Bark app isn't receiving APNS: check Notification permission for
  Bark, disable any VPN/DNS blocker or iCloud Private Relay, reinstall Bark.

## Scenarios to handle
- **Only Codex / only Claude / both** — wire only what they use.
- **Remote SSH servers** — repeat steps 2–3 on each server that runs an agent; it works over SSH
  because it's an outbound HTTPS call (config must live on the machine running the agent).
- **No encryption** — leave `BARK_KEY` empty.
- **Existing hooks / notify** — merge, never clobber.
