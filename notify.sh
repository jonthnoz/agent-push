#!/usr/bin/env bash
# agent-push: mobile push when Codex or Claude Code finishes a turn or needs input.
#   iOS / macOS         -> Bark  (optional end-to-end AES encryption)
#   Android / anything  -> ntfy  (set NTFY_URL; no E2E — use a random topic or self-host)
# Set BARK_URL and/or NTFY_URL in the config. If both are set, both are notified.
#
#   Codex `notify`    -> the event JSON arrives as the last CLI argument.
#   Claude Code hooks -> the event JSON arrives on stdin (Stop, Notification).
#
# Requires: curl, jq (and openssl only when BARK_KEY is set).
set -euo pipefail

CONFIG="${AGENT_NOTIFY_CONFIG:-$HOME/.config/agent-notify/config.env}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"
if [ -z "${BARK_URL:-}" ] && [ -z "${NTFY_URL:-}" ]; then
  echo "agent-push: set BARK_URL (iOS) and/or NTFY_URL (Android) in $CONFIG" >&2
  exit 0
fi

# App icons shown in the notification (override in config.env for crisper logos).
ICON_CODEX="${ICON_CODEX:-https://www.google.com/s2/favicons?sz=128&domain=openai.com}"
ICON_CLAUDE="${ICON_CLAUDE:-https://www.google.com/s2/favicons?sz=128&domain=claude.ai}"

# --- read the event JSON: argv (Codex) or stdin (Claude Code) --------------
if [ "$#" -gt 0 ]; then payload="${!#}"; else payload="$(cat)"; fi
field() { printf '%s' "$payload" | jq -r "$1" 2>/dev/null || true; }

# Fallback only: the docs say Stop provides `last_assistant_message` directly. This reads
# the transcript for older Claude Code that lacks it — scoped to text since the last genuine
# user prompt so it can never surface a prior turn (worst case: empty -> "Finished.").
transcript_last_msg() {
  local tp; tp="$(field '.transcript_path')"
  [ -n "$tp" ] && [ -f "$tp" ] || return 0
  tail -n 400 "$tp" | jq -sr '
    reduce .[] as $e ([];
      if $e.type=="user" and (
           ($e.message.content|type)=="string"
           or (($e.message.content|type)=="array" and ([$e.message.content[].type]|index("tool_result")|not)))
      then []
      elif $e.type=="assistant" then . + [ $e.message.content[]? | select(.type=="text") | .text ]
      else . end)
    | last // empty' 2>/dev/null || true
}

type="$(field '.type // .hook_event_name // empty')"
case "$type" in
  agent-turn-complete)
    agent="Codex"; icon="$ICON_CODEX"; emoji="✅"; tag="white_check_mark"; sub="turn complete"; level="active"; call=0
    project="$(field '.cwd')"; project="${project##*/}"; [ -n "$project" ] || project="$(basename "$PWD" 2>/dev/null || true)"
    body="$(field '."last-assistant-message" // "Turn complete."')" ;;
  *approval*)
    agent="Codex"; icon="$ICON_CODEX"; emoji="⏳"; tag="hourglass"; sub="needs approval"; level="timeSensitive"; call=1
    project="$(field '.cwd')"; project="${project##*/}"; [ -n "$project" ] || project="$(basename "$PWD" 2>/dev/null || true)"
    body="$(field '."last-assistant-message" // "Waiting for your approval."')" ;;
  Stop)                                       # Claude Code: finished responding
    agent="Claude"; icon="$ICON_CLAUDE"; emoji="✅"; tag="white_check_mark"; sub="done"; level="active"; call=0
    project="$(field '.cwd')"; project="${project##*/}"
    body="$(field '.last_assistant_message')"        # authoritative field (per docs)
    [ -n "$body" ] || body="$(transcript_last_msg)"  # fallback for older Claude Code
    [ -n "$body" ] || body="Finished." ;;
  Notification)                               # Claude Code: permission or idle prompt
    agent="Claude"; icon="$ICON_CLAUDE"; emoji="⏳"; tag="hourglass"; sub="needs input"; level="timeSensitive"; call=1
    project="$(field '.cwd')"; project="${project##*/}"
    # The Notification hook carries only a generic message — no tool name/args (per docs).
    body="$(field '.message // "Waiting for your input."')"
    case "$body" in *permission*) sub="needs approval" ;; esac ;;
  *)
    agent="Agent"; icon="$ICON_CODEX"; emoji="🔔"; tag="bell"; sub=""; level="active"; call=0
    project=""
    body="$(field '."last-assistant-message" // .message // "Notification"')" ;;
esac

title="${agent} ${emoji}${project:+ ${project}}"
body="$(printf '%s' "$body" | head -c 500)"; [ -n "$body" ] || body="(no message)"
group="${project:-agents}"

to_hex() { printf %s "$1" | od -An -v -tx1 | tr -d ' \n'; }

# ---------------- Bark (iOS / macOS), optional AES E2E ----------------
send_bark() {
  local json
  json="$(jq -nc \
    --arg title "$title" --arg subtitle "$sub" --arg body "$body" \
    --arg group "$group" --arg icon "$icon" --arg level "$level" --arg call "$call" '
    {title:$title, subtitle:$subtitle, body:$body, group:$group, icon:$icon, level:$level}
    | with_entries(select(.value != ""))
    | if $call == "1" then . + {call:"1"} else . end')"

  if [ -n "${BARK_KEY:-}" ]; then
    local klen; klen=${#BARK_KEY}
    case "$klen" in
      16|24|32) : ;;
      *) curl -fsS --max-time 10 -H 'Content-Type: application/json' \
           -d "{\"title\":\"agent-push config error\",\"body\":\"BARK_KEY must be 16, 24, or 32 chars (got $klen)\"}" \
           "$BARK_URL" >/dev/null || true; return ;;
    esac
    local iv ct
    iv="$(openssl rand -hex 8)"
    ct="$(printf %s "$json" | openssl enc -"aes-$((klen * 8))-cbc" -K "$(to_hex "$BARK_KEY")" -iv "$(to_hex "$iv")" -a -A)"
    curl -fsS --max-time 10 --data-urlencode "ciphertext=$ct" --data-urlencode "iv=$iv" "$BARK_URL" >/dev/null || true
  else
    curl -fsS --max-time 10 -H 'Content-Type: application/json' -d "$json" "$BARK_URL" >/dev/null || true
  fi
}

# ---------------- ntfy (Android / cross-platform), no E2E ----------------
send_ntfy() {
  local prio; [ "$call" = 1 ] && prio=urgent || prio=default
  # positional params (not an array) so it's safe under `set -u` on bash 3.2 (macOS)
  set -- -H "Title: ${agent}${project:+ ${project}}" -H "Priority: ${prio}" \
         -H "Tags: ${tag}" -H "Icon: ${icon}" -d "${body}"
  [ -n "${NTFY_TOKEN:-}" ] && set -- -H "Authorization: Bearer ${NTFY_TOKEN}" "$@"
  curl -fsS --max-time 10 "$@" "$NTFY_URL" >/dev/null || true
}

[ -n "${BARK_URL:-}" ] && send_bark
[ -n "${NTFY_URL:-}" ] && send_ntfy
exit 0
