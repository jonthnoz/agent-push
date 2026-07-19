# Setup runbook — for the AI agent reading this

You (Codex, Claude Code, or any coding agent) are helping the user get **iPhone push
notifications when an AI coding agent finishes a turn or needs input**. Do this on the
user's **local machine**. Follow these steps precisely; ask before any change you're unsure of.

## 0. Preconditions
- Confirm `curl` and `jq` are installed (and `openssl`, needed only for Bark encryption). If
  `jq` is missing, install it (macOS: `brew install jq`; Debian/Ubuntu: `sudo apt-get install -y jq`).
- Ask which phone(s) the user has: **iPhone/Mac**, **Android**, or **both**.
  - iPhone/Mac → the **Bark** app: https://apps.apple.com/app/id1403753865
  - Android → the **ntfy** app (Play Store / F-Droid).
- The machine running the agent must be macOS or Linux (Windows → WSL).

## 1. Collect the backend URL(s) from the user
- **iPhone/Mac (Bark):** have them copy the device URL (`https://api.day.app/XXXX`) → `BARK_URL`.
  Encryption (recommended): Bark → **Settings → Encryption**, **AES256 / CBC**, a **32-character
  key** → `BARK_KEY`. If declined, skip (content transits Bark's server in plaintext).
- **Android (ntfy):** have them subscribe to an **unguessable** topic; the URL is
  `https://ntfy.sh/<topic>` → `NTFY_URL`. ntfy has no E2E, so the topic must stay secret (or self-host).
- Set whichever apply in `config.env`. At least one of `BARK_URL` / `NTFY_URL` is required; set
  both to notify iPhone + Android together.

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
# "done" notifications (fires only on turn-complete, never on approvals):
notify = ["/ABS/PATH/notify.sh"]

# approval notifications (Codex >= 0.144): fires only when Codex asks you to approve a
# tool (shell/apply_patch/MCP/network), not on every tool. matcher ".*" = all approvals.
[[hooks.PermissionRequest]]
matcher = ".*"
[[hooks.PermissionRequest.hooks]]
type = "command"
command = "/ABS/PATH/notify.sh"
```
If a `notify` line already exists, DON'T silently replace it — show the user, comment the old one out, confirm.
Two things to tell the user about the hook: (1) on the next Codex start they'll get a **"Review hooks"**
prompt — they must pick **Trust all and continue** or it won't run (trust is keyed to the config entry —
command/matcher — so editing `notify.sh` later does NOT re-prompt; changing the `config.toml` hook does);
(2) approval pushes are **delayed `NOTIFY_DELAY` seconds (default 5)** and sent only if they still haven't
acted — detected by the session rollout still being frozen AND no approval decision logged in Codex's trace
db (`~/.codex/logs_*.sqlite`, best-effort; falls back to the rollout check if absent). So prompts answered
quickly, auto-approved by `auto_review`, or approved-but-then-running-a-long-silent-command all stay silent;
only ones left sitting ping. `NOTIFY_DELAY=0` disables the delay.
The `PermissionRequest` event only exists on Codex >= ~0.144; older Codex gets "done"-only via `notify`.

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

## Optional — richer permission notifications
Claude's Notification hook has no tool context, so permission prompts show a generic message.
To include the pending tool (e.g. `Bash: terraform apply`), a `goal:` line from the tool's
`description` (Bash/Task only), and the question text for AskUserQuestion, add `pending-tool.sh`
(chmod +x it) as a PreToolUse hook, MERGED into any existing PreToolUse hooks:
```json
"PreToolUse": [ { "hooks": [ { "type": "command", "command": "/ABS/PATH/pending-tool.sh" } ] } ]
```
Opt-in and local-only; `notify.sh` falls back to the generic message without it.

## Scenarios to handle
- **Only Codex / only Claude / both** — wire only what they use.
- **Remote SSH servers** — repeat steps 2–3 on each server that runs an agent; it works over SSH
  because it's an outbound HTTPS call (config must live on the machine running the agent).
- **No encryption** — leave `BARK_KEY` empty.
- **Existing hooks / notify** — merge, never clobber.
