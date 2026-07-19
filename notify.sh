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

# Summarize a tool payload (Codex PermissionRequest — same shape as Claude's PreToolUse):
# "Goal: <description>" on top when present, then "<Tool>: <command/arg>". Mirrors pending-tool.sh.
tool_summary() {
  printf '%s' "$payload" | jq -r '
    (.tool_name // "tool") as $raw
    | ( if ($raw|startswith("mcp__")) then ($raw|split("__")|last) else $raw end ) as $n
    | ( .tool_input.command // .tool_input.file_path // .tool_input.path // .tool_input.url // .tool_input.query
        // ([.tool_input | to_entries[] | select(.key != "description") | .value | select(type=="string")] | .[0] // "") ) as $d
    | ( .tool_input.description // "" ) as $why
    | ( if ($d|type)=="string" and ($d|length)>0 then "\($n): \(($d|gsub("\\s+";" "))[0:160])" else $n end ) as $what
    | if ($why|type)=="string" and ($why|length)>0 then "Goal: \(($why|gsub("\\s+";" "))[0:200])\n\($what)" else $what end' 2>/dev/null || true
}

type="$(field '.type // .hook_event_name // empty')"
case "$type" in
  agent-turn-complete)
    agent="Codex"; icon="$ICON_CODEX"; emoji="✅"; tag="white_check_mark"; sub="turn complete"; level="active"; call=0
    project="$(field '.cwd')"; project="${project##*/}"; [ -n "$project" ] || project="$(basename "$PWD" 2>/dev/null || true)"
    body="$(field '."last-assistant-message" // "Turn complete."')" ;;
  PermissionRequest)                          # Codex: about to ask you to approve a tool (hooks system)
    agent="Codex"; icon="$ICON_CODEX"; emoji="⏳"; tag="hourglass"; sub="needs approval"; level="timeSensitive"; call=1
    project="$(field '.cwd')"; project="${project##*/}"; [ -n "$project" ] || project="$(basename "$PWD" 2>/dev/null || true)"
    body="$(tool_summary)"; [ -n "$body" ] || body="Waiting for your approval."
    # delayed-send baseline: rollout size + moment + trace-db path, to detect after the delay
    # whether the approval is still pending or was already answered.
    pr_tp="$(field '.transcript_path')"; pr_size0="$(wc -c < "$pr_tp" 2>/dev/null || echo 0)"
    pr_sid="$(field '.session_id')"; pr_ts="$(date +%s)"
    pr_db="$(ls -t "$HOME/.codex"/logs_*.sqlite 2>/dev/null | head -1)"; delay_check=1 ;;
  *approval*)                                 # Codex legacy notify: never emits approvals (kept as a harmless fallback)
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
    # .message is generic (no tool context, per docs); route on .notification_type (verified).
    body="$(field '.message // "Waiting for your input."')"
    ntype="$(field '.notification_type')"; perm=0
    case "$ntype" in
      permission_prompt) perm=1 ;;
      "") case "$body" in *permission*) perm=1 ;; esac ;;   # older Claude Code w/o notification_type
    esac
    if [ "$perm" = 1 ]; then
      sub="needs approval"
      # optional PreToolUse hook (pending-tool.sh) stashes the pending tool so we can name it
      pend="$HOME/.config/agent-notify/pending-$(field '.session_id').txt"
      if [ -f "$pend" ]; then ptool="$(cat "$pend" 2>/dev/null || true)"; [ -n "$ptool" ] && body="$ptool"; fi
      # AskUserQuestion fires permission_prompt but is a question, not a command approval
      case "$body" in AskUserQuestion:*) sub="needs input" ;; esac
    fi ;;
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

send() { [ -n "${BARK_URL:-}" ] && send_bark; [ -n "${NTFY_URL:-}" ] && send_ntfy; return 0; }

# ---- Codex "approval already resolved?" checks, from Codex's trace sqlite ----
# Codex logs approval activity to ~/.codex/logs_*.sqlite within ~1-2s (unlike the batched
# rollout, this is orthogonal to how long an approved command then runs). All checks are
# best-effort: if the db/sqlite3 is absent they return 1 (unknown) and the caller falls back
# to the rollout-freeze signal — never worse than not having them.
_sql()    { sqlite3 -readonly -cmd '.timeout 200' "$pr_db" "$1" 2>/dev/null; }
_db_ok()  { [ -n "${pr_db:-}" ] && command -v sqlite3 >/dev/null 2>&1; }
_sid_ok() { case "${pr_sid:-}" in *[!0-9a-f-]*|"") return 1 ;; *) return 0 ;; esac; }  # SQL-safe

# Manual: you approved or denied (an ExecApproval submission on our session since the prompt).
approval_answered() {
  _db_ok && _sid_ok || return 1
  local n; n="$(_sql "SELECT count(*) FROM logs WHERE ts >= ${pr_ts:-0}
    AND target='codex_core::session::handlers'
    AND feedback_log_body LIKE '%Approval {%' AND feedback_log_body LIKE '%${pr_sid}%';")" || return 1
  [ "${n:-0}" -gt 0 ]
}
# Auto-review: the guardian (a subagent thread whose review prompt names our session id)
# returned the verdict {"outcome":"allow"}. Escalations/denials are a different (non-allow)
# verdict → not matched → we still ping (correct: you're now the one being asked).
auto_allowed() {
  _db_ok && _sid_ok || return 1
  local n; n="$(_sql "SELECT count(*) FROM logs v WHERE v.ts >= ${pr_ts:-0}
    AND v.target='codex_core::stream_events_utils' AND v.feedback_log_body LIKE '%FinalAnswer%'
    AND v.feedback_log_body LIKE '%\\\"outcome\\\":\\\"allow\\\"%'  -- value 'allow' then } or ,
    AND v.thread_id IN (SELECT p.thread_id FROM logs p WHERE p.ts >= ${pr_ts:-0} - 2
      AND p.target='codex_core::session::handlers'
      AND p.feedback_log_body LIKE '%Reviewed Codex session id: ${pr_sid}%');")" || return 1
  [ "${n:-0}" -gt 0 ]
}
# Is a guardian still reviewing a request from our session (review started, no verdict yet)?
# Used only to extend the wait past the delay so a slow auto-review resolves before we decide.
review_in_flight() {
  _db_ok && _sid_ok || return 1
  local n; n="$(_sql "SELECT
     (SELECT count(*) FROM logs WHERE ts >= ${pr_ts:-0} - 2 AND target='codex_core::session::handlers'
        AND feedback_log_body LIKE '%Reviewed Codex session id: ${pr_sid}%')
   - (SELECT count(*) FROM logs WHERE ts >= ${pr_ts:-0} AND target='codex_core::stream_events_utils'
        AND feedback_log_body LIKE '%FinalAnswer%'
        AND thread_id IN (SELECT thread_id FROM logs WHERE ts >= ${pr_ts:-0} - 2
          AND target='codex_core::session::handlers'
          AND feedback_log_body LIKE '%Reviewed Codex session id: ${pr_sid}%'));")" || return 1
  [ "${n:-0}" -gt 0 ]
}

# Fire-and-forget in a detached child. Codex PermissionRequest hooks run synchronously AND
# Codex waits for the hook's stdout to reach EOF — so the child must redirect fd 0/1/2 OFF
# the inherited pipe (</dev/null >/dev/null 2>&1), else a slow send would block the approval
# prompt until it finishes. (`async` hook option is parsed but not supported by Codex yet.)
if [ "${delay_check:-0}" = 1 ] && [ -n "${pr_tp:-}" ]; then
  # Codex approvals only: poll until NOTIFY_DELAY (default 5s), then push ONLY if you STILL
  # haven't acted — rollout still frozen, no manual decision, no auto-review allow. If a guardian
  # is mid-review, keep waiting (capped at NOTIFY_MAX_WAIT) so a slow auto-approve resolves first.
  ( { deadline=$(( pr_ts + ${NOTIFY_DELAY:-5} )); hard=$(( pr_ts + ${NOTIFY_MAX_WAIT:-30} ))
      while : ; do
        cur="$(wc -c < "$pr_tp" 2>/dev/null || echo 0)"
        if [ "$cur" != "$pr_size0" ] || approval_answered || auto_allowed; then exit 0; fi
        now="$(date +%s)"
        if [ "$now" -ge "$deadline" ] && ! { review_in_flight && [ "$now" -lt "$hard" ]; }; then break; fi
        sleep 1
      done
      cur="$(wc -c < "$pr_tp" 2>/dev/null || echo 0)"
      [ "$cur" = "$pr_size0" ] && send
    } </dev/null >/dev/null 2>&1 & )
else
  ( { send; } </dev/null >/dev/null 2>&1 & )
fi
exit 0
