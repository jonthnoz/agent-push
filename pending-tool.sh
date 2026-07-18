#!/usr/bin/env bash
# agent-push PreToolUse hook (optional): stash the tool about to run so the permission
# Notification can name it (the Notification hook itself gets no tool context).
# Fires before every tool call; the stash is overwritten each time, so when an
# approval prompt appears it holds the pending tool. Fast, never blocks.
set -euo pipefail
dir="$HOME/.config/agent-notify"; mkdir -p "$dir" 2>/dev/null || true
payload="$(cat)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // "default"' 2>/dev/null || echo default)"
line="$(printf '%s' "$payload" | jq -r '
  (.tool_name // "tool") as $n
  | ( .tool_input.command // .tool_input.file_path // .tool_input.path // .tool_input.url
      // (.tool_input | to_entries | (.[0].value? // "")) ) as $d
  | if ($d|type)=="string" and ($d|length)>0 then "\($n): \(($d|gsub("\\s+";" "))[0:160])" else $n end' 2>/dev/null || true)"
[ -n "$line" ] && printf '%s' "$line" > "$dir/pending-$sid.txt" 2>/dev/null || true
exit 0
