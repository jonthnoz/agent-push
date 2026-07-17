#!/usr/bin/env bash
# agent-push: mobile push notification (via Bark) when Codex or Claude Code
# finishes a turn or needs your input. Optional end-to-end AES encryption.
#
#   Codex `notify`    -> the event JSON arrives as the last CLI argument.
#   Claude Code hooks -> the event JSON arrives on stdin (Stop, Notification).
#
# Requires: curl, jq, openssl. Config: ~/.config/agent-notify/config.env
set -euo pipefail

CONFIG="${AGENT_NOTIFY_CONFIG:-$HOME/.config/agent-notify/config.env}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"
: "${BARK_URL:?set BARK_URL in $CONFIG (e.g. https://api.day.app/<your-device-key>)}"

# App icons shown in the notification (override in config.env for crisper logos).
ICON_CODEX="${ICON_CODEX:-https://www.google.com/s2/favicons?sz=128&domain=openai.com}"
ICON_CLAUDE="${ICON_CLAUDE:-https://www.google.com/s2/favicons?sz=128&domain=claude.ai}"

# --- read the event JSON: argv (Codex) or stdin (Claude Code) --------------
if [ "$#" -gt 0 ]; then payload="${!#}"; else payload="$(cat)"; fi
field() { printf '%s' "$payload" | jq -r "$1" 2>/dev/null || true; }

# last assistant text block from a Claude Code transcript (JSONL)
last_assistant_msg() {
  local tp; tp="$(field '.transcript_path')"
  [ -n "$tp" ] && [ -f "$tp" ] || return 0
  tail -n 200 "$tp" | jq -sr '
    [ .[] | select(.type=="assistant") | .message.content[]?
          | select(.type=="text") | .text ] | last // empty' 2>/dev/null || true
}

type="$(field '.type // .hook_event_name // empty')"
case "$type" in
  agent-turn-complete)
    agent="Codex"; icon="$ICON_CODEX"; emoji="✅"; sub="turn complete"; level="active"; call=0
    project="$(field '.cwd')"; project="${project##*/}"; [ -n "$project" ] || project="$(basename "$PWD" 2>/dev/null || true)"
    body="$(field '."last-assistant-message" // "Turn complete."')" ;;
  *approval*)
    agent="Codex"; icon="$ICON_CODEX"; emoji="⏳"; sub="needs approval"; level="timeSensitive"; call=1
    project="$(field '.cwd')"; project="${project##*/}"; [ -n "$project" ] || project="$(basename "$PWD" 2>/dev/null || true)"
    body="$(field '."last-assistant-message" // "Waiting for your approval."')" ;;
  Stop)
    agent="Claude"; icon="$ICON_CLAUDE"; emoji="✅"; sub="done"; level="active"; call=0
    project="$(field '.cwd')"; project="${project##*/}"
    body="$(last_assistant_msg)"; [ -n "$body" ] || body="Finished." ;;
  Notification)
    agent="Claude"; icon="$ICON_CLAUDE"; emoji="⏳"; sub="needs input"; level="timeSensitive"; call=1
    project="$(field '.cwd')"; project="${project##*/}"
    body="$(field '.message // "Waiting for your input."')" ;;
  *)
    agent="Agent"; icon="$ICON_CODEX"; emoji="🔔"; sub=""; level="active"; call=0
    project=""
    body="$(field '."last-assistant-message" // .message // "Notification"')" ;;
esac

title="${agent} ${emoji}${project:+ ${project}}"
body="$(printf '%s' "$body" | head -c 500)"; [ -n "$body" ] || body="(no message)"
group="${project:-agents}"

# Build the Bark payload as JSON (empty fields dropped).
json="$(jq -nc \
  --arg title "$title" --arg subtitle "$sub" --arg body "$body" \
  --arg group "$group" --arg icon "$icon" --arg level "$level" --arg call "$call" '
  {title:$title, subtitle:$subtitle, body:$body, group:$group, icon:$icon, level:$level}
  | with_entries(select(.value != ""))
  | if $call == "1" then . + {call:"1"} else . end')"

# --- send: encrypted if BARK_KEY set, else plaintext JSON ------------------
to_hex() { printf %s "$1" | od -An -v -tx1 | tr -d ' \n'; }

if [ -n "${BARK_KEY:-}" ]; then
  klen=${#BARK_KEY}
  case "$klen" in
    16|24|32) : ;;
    *)  # wrong key length would silently fail to decrypt — surface it instead
        curl -fsS --max-time 10 -H 'Content-Type: application/json' \
          -d "{\"title\":\"agent-push config error\",\"body\":\"BARK_KEY must be 16, 24, or 32 chars (got $klen)\"}" \
          "$BARK_URL" >/dev/null || true
        exit 0 ;;
  esac
  cipher="aes-$((klen * 8))-cbc"
  iv="$(openssl rand -hex 8)"                         # 16 ASCII chars = 16-byte IV
  ct="$(printf %s "$json" | openssl enc -"$cipher" -K "$(to_hex "$BARK_KEY")" -iv "$(to_hex "$iv")" -a -A)"
  curl -fsS --max-time 10 \
    --data-urlencode "ciphertext=$ct" --data-urlencode "iv=$iv" \
    "$BARK_URL" >/dev/null || true
else
  curl -fsS --max-time 10 -H 'Content-Type: application/json' -d "$json" "$BARK_URL" >/dev/null || true
fi
