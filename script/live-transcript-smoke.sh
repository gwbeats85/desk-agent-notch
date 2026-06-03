#!/usr/bin/env bash
set -euo pipefail

HELPER_URL="${HELPER_URL:-http://127.0.0.1:4177}"
LOG_PATH="${MARKSHOT_LOG:-${MARKSHOT_LOG_PATH:-/tmp/markshot-debug.log}}"
REQUIRE_TRANSCRIPTS=0
MARKSHOT_USER_DEFAULTS_DOMAIN="${MARKSHOT_USER_DEFAULTS_DOMAIN:-com.deskagent.MarkShot}"
CHAT_HISTORY_KEY="${MARKSHOT_CHAT_HISTORY_KEY:-markshot.notch.chatHistoryJSON}"
MARKSHOT_BUNDLE_ID="$(/usr/bin/defaults read /Applications/MarkShot.app/Contents/Info.plist CFBundleIdentifier 2>/dev/null || true)"
strict_ready_readiness=0
strict_exit_code=0

resolve_defaults_domain() {
  local key="$1"
  if ! command -v defaults >/dev/null 2>&1; then
    echo "$MARKSHOT_USER_DEFAULTS_DOMAIN"
    return 0
  fi
  for candidate in "$MARKSHOT_USER_DEFAULTS_DOMAIN" "$MARKSHOT_BUNDLE_ID" com.deskagent.MarkShot; do
    [ -z "$candidate" ] && continue
    if defaults read "$candidate" "$key" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  echo "$MARKSHOT_USER_DEFAULTS_DOMAIN"
}

MARKSHOT_USER_DEFAULTS_DOMAIN="$(resolve_defaults_domain "$CHAT_HISTORY_KEY")"

for arg in "$@"; do
  case "$arg" in
    --require-transcripts)
      REQUIRE_TRANSCRIPTS=1
      ;;
    -h|--help)
  cat <<'USAGE'
Usage:
  ./live-transcript-smoke.sh [--require-transcripts]

  Options:
  LOG_PATH env var: path to MarkShot debug log (default: /tmp/markshot-debug.log).
  MARKSHOT_LOG or MARKSHOT_LOG_PATH can also set the log path.
  LIVE_IDLE_WAIT_SECONDS env var: seconds to wait for sessions to return to idle in interactive mode (default: 8).
  --require-transcripts  Exit non-zero unless this run emits user+assistant transcript finalization and chat append lines and ends with no active live sessions.
USAGE
      exit 0
      ;;
    *)
      echo "[notch-live-qa] Unknown argument: $arg"
      exit 2
      ;;
  esac
done

for required_cmd in curl jq rg diff; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    echo "[notch-live-qa] Missing required dependency: $required_cmd"
    exit 2
  fi
done
if ! command -v defaults >/dev/null 2>&1; then
  echo "[notch-live-qa] Skipping visible-chat checks: defaults command unavailable."
fi

pre_log_snapshot="$(mktemp)"
post_log_snapshot="$(mktemp)"
trap 'rm -f "$pre_log_snapshot" "$post_log_snapshot"' EXIT
MAX_IDLE_WAIT_SECONDS="${LIVE_IDLE_WAIT_SECONDS:-8}"
HAS_DEFAULTS_CHAT_HISTORY=0
BEFORE_CHAT_MESSAGES='[]'
AFTER_CHAT_MESSAGES='[]'

echo "[notch-live-qa] Helper: $HELPER_URL"
echo "[notch-live-qa] Log: $LOG_PATH"
echo "[notch-live-qa] Defaults domain: $MARKSHOT_USER_DEFAULTS_DOMAIN"
echo "[notch-live-qa] Chat history key: $CHAT_HISTORY_KEY"
echo "[notch-live-qa] Max idle wait: ${MAX_IDLE_WAIT_SECONDS}s"

if [ ! -r "$LOG_PATH" ]; then
  if [ ! -e "$LOG_PATH" ]; then
    echo "[notch-live-qa] Log file not found. Waiting for next run to create it."
    LOG_READABILITY="missing"
  else
    echo "[notch-live-qa] Log file exists but is not readable; transcript diff validation will be skipped."
    LOG_READABILITY="unreadable"
  fi
else
  LOG_READABILITY="readable"
fi
HAS_LOG=1
if [ ! -r "$LOG_PATH" ]; then
  HAS_LOG=0
fi

read_chat_history() {
  local raw_json
  local parsed_json
  raw_json="$(defaults read "$MARKSHOT_USER_DEFAULTS_DOMAIN" "$CHAT_HISTORY_KEY" 2>/dev/null || true)"
  if [ -n "$raw_json" ]; then
    if ! parsed_json="$(printf '%s\n' "$raw_json" | jq -c 'if type == "array" then . else [] end' 2>/dev/null)"; then
      parsed_json="[]"
    fi
    printf '%s\n' "$parsed_json"
  else
    printf '%s\n' "[]"
  fi
}

run_json() {
  local path="$1"
  local response
  if ! response="$(curl --connect-timeout 2 --max-time 8 -fsS "$HELPER_URL$path" 2>/dev/null)"; then
    echo "[notch-live-qa] Helper request failed: $HELPER_URL$path"
    return 1
  fi
  echo "$response"
}

run_json_query() {
  local path="$1"
  local query="$2"
  local raw_json
  local parsed

  if ! raw_json="$(run_json "$path")"; then
    return 1
  fi

  if ! parsed="$(printf '%s\n' "$raw_json" | jq -r "$query" 2>/dev/null)"; then
    echo "[notch-live-qa] Failed to parse JSON from $path"
    echo "[notch-live-qa] Raw response: $raw_json"
    return 1
  fi
  printf '%s\n' "$parsed"
}

readiness_level() {
  local response
  local level
  if ! response="$(run_json "/api/live/config")"; then
    return 1
  fi
  if ! level="$(printf '%s\n' "$response" | jq -r '.readiness.level // "unknown"' 2>/dev/null)"; then
    echo "[notch-live-qa] Failed to parse readiness from /api/live/config"
    return 1
  fi
  printf '%s\n' "$level"
}

status_snapshot() {
  local path="$1"
  local raw_json
  if ! raw_json="$(run_json "$path")"; then
    return 1
  fi
  if ! printf '%s\n' "$raw_json" | jq -e . >/dev/null 2>&1; then
    echo "[notch-live-qa] Received non-JSON response from $path"
    echo "[notch-live-qa] Raw response: $raw_json"
    return 1
  fi
  printf '%s\n' "$raw_json"
}

wait_for_idle_sessions() {
  local elapsed=0
  while [ "$elapsed" -lt "$MAX_IDLE_WAIT_SECONDS" ]; do
    local snapshot
    if ! snapshot="$(status_snapshot "/api/notch/status")"; then
      return 1
    fi
    local active_count
    active_count=$(printf '%s\n' "$snapshot" | jq -r '(.live.activeSessions // []) | length')
    if [ "$active_count" = "0" ]; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

before_status="$(status_snapshot "/api/notch/status")"
before_sessions=$(printf '%s\n' "$before_status" | jq -c '(.live.activeSessions // [])')
before_session_count=$(printf '%s\n' "$before_sessions" | jq -r 'length')
before_conversation_turns=$(printf '%s\n' "$before_status" | jq -c '(.conversation?.recentTurns // [])')
before_conversation_turn_ids=$(printf '%s\n' "$before_conversation_turns" | jq -c 'map(.id)')
before_conversation_turn_count=$(printf '%s\n' "$before_conversation_turn_ids" | jq -r 'length')
echo "[notch-live-qa] before activeSessions: $before_sessions"
echo "[notch-live-qa] before activeSessionCount: $before_session_count"
echo "[notch-live-qa] before conversation turns: $before_conversation_turn_count"
before_sessions_empty=1
if ! [ "$before_session_count" = "0" ]; then
  echo "[notch-live-qa] Warning: before activeSessions is not empty."
  before_sessions_empty=0
fi

echo "[notch-live-qa] before live readiness:" 
run_json_query "/api/live/config" '{provider, model, readiness}'

if ! before_live_readiness="$(readiness_level || true)"; then
  before_live_readiness="unknown"
  if [ "$REQUIRE_TRANSCRIPTS" -eq 1 ]; then
    echo "[notch-live-qa] Strict mode failed: unable to read live readiness level before run."
    strict_ready_readiness=1
  fi
fi
before_live_ready=0
if [ "$before_live_readiness" = "ready" ]; then
  before_live_ready=1
else
  before_live_ready=0
  if [ "$REQUIRE_TRANSCRIPTS" -eq 1 ]; then
    echo "[notch-live-qa] Strict mode failed: live readiness is $before_live_readiness before the run."
  fi
fi

if [ "$HAS_LOG" -eq 1 ]; then
  cp "$LOG_PATH" "$pre_log_snapshot"
else
  echo "[notch-live-qa] No log snapshot copied; transcript detection will rely on live stream only."
fi
if command -v defaults >/dev/null 2>&1; then
  BEFORE_CHAT_MESSAGES="$(read_chat_history)"
  HAS_DEFAULTS_CHAT_HISTORY=1
  BEFORE_CHAT_COUNT="$(printf '%s\n' "$BEFORE_CHAT_MESSAGES" | jq -r 'length')"
  echo "[notch-live-qa] before chat history count: $BEFORE_CHAT_COUNT"
else
  echo "[notch-live-qa] defaults unavailable; skipping chat history pre-check."
fi

interactive=0

if [ -t 0 ]; then
  interactive=1
  cat <<'MSG'

1) Launch /Applications/MarkShot.app
2) Click waveform/Listen and speak: check live transcript import
3) Wait for response, then stop live session
4) Open Hermes chat and confirm visible entries
5) Press Enter here when done.

MSG
  read -r _
else
  echo "[notch-live-qa] Non-interactive mode; skipping manual pause."
fi

if [ "$HAS_LOG" -eq 0 ] && [ "$REQUIRE_TRANSCRIPTS" -eq 1 ]; then
  if [ "$LOG_READABILITY" = "missing" ]; then
    echo "[notch-live-qa] Strict mode failed: log file not found at $LOG_PATH."
  else
    echo "[notch-live-qa] Strict mode failed: log file exists but is not readable at $LOG_PATH."
  fi
  echo "[notch-live-qa] Start MarkShot and keep this script running after a spoken test, or set MARKSHOT_LOG to a valid path."
  exit 1
fi

if [ "$interactive" -eq 1 ]; then
  echo "[notch-live-qa] Waiting briefly for live session teardown..."
  if ! wait_for_idle_sessions; then
    echo "[notch-live-qa] Session did not return to idle before running final checks (timeout ${MAX_IDLE_WAIT_SECONDS}s)."
  fi
fi

after_status="$(status_snapshot "/api/notch/status")"
after_sessions=$(printf '%s\n' "$after_status" | jq -c '(.live.activeSessions // [])')
after_session_count=$(printf '%s\n' "$after_sessions" | jq -r 'length')
after_conversation_turns=$(printf '%s\n' "$after_status" | jq -c '(.conversation?.recentTurns // [])')
after_conversation_turn_ids=$(printf '%s\n' "$after_conversation_turns" | jq -c 'map(.id)')
after_conversation_turn_count=$(printf '%s\n' "$after_conversation_turn_ids" | jq -r 'length')
if ! added_conversation_turn_ids="$(jq -n --argjson before "$before_conversation_turn_ids" --argjson after "$after_conversation_turn_ids" '$after - $before')" ; then
  echo "[notch-live-qa] Failed to diff conversation turn IDs."
  added_conversation_turn_ids='[]'
fi
added_conversation_turn_count=$(printf '%s\n' "$added_conversation_turn_ids" | jq -r 'length')
if ! added_notch_conversation_turns="$(jq -n --argjson before "$before_conversation_turn_ids" --argjson after "$after_conversation_turns" '[ $after[] | select((.source == "notch") and (.id as $id | $before | index($id) | not)) ]')" ; then
  echo "[notch-live-qa] Failed to filter notch conversation turns."
  added_notch_conversation_turns='[]'
fi
added_notch_conversation_turn_count=$(printf '%s\n' "$added_notch_conversation_turns" | jq -r 'length')
echo "[notch-live-qa] after activeSessions: $after_sessions"
echo "[notch-live-qa] after activeSessionCount: $after_session_count"
echo "[notch-live-qa] after conversation turns: $after_conversation_turn_count"
echo "[notch-live-qa] added conversation turns: $added_conversation_turn_count"
if [ "$added_conversation_turn_count" -gt 0 ]; then
  echo "[notch-live-qa] added turn IDs: $(printf '%s\n' "$added_conversation_turn_ids" | jq -r 'join(", ")')"
fi
echo "[notch-live-qa] added notch conversation turns: $added_notch_conversation_turn_count"
if [ "$added_notch_conversation_turn_count" -gt 0 ]; then
  echo "[notch-live-qa] added notch turn IDs: $(printf '%s\n' "$added_notch_conversation_turns" | jq -r 'map(.id) | join(\", \")')"
fi

echo "[notch-live-qa] after live readiness:" 
run_json_query "/api/live/config" '{provider, model, readiness}'

if [ "$HAS_LOG" -eq 1 ]; then
  strict_exit_code=0
  if [ "$strict_ready_readiness" -eq 1 ]; then
    strict_failed=1
  else
    strict_failed=0
  fi
  if [ "$REQUIRE_TRANSCRIPTS" -eq 1 ] && [ "$before_live_ready" -eq 0 ]; then
    echo "[notch-live-qa] Strict mode failed: live readiness was not ready before run."
    strict_failed=1
  fi

  if ! after_live_readiness="$(readiness_level || true)"; then
    after_live_readiness="unknown"
  fi
  if [ "$after_live_readiness" != "ready" ]; then
    echo "[notch-live-qa] Strict mode warning: live readiness is $after_live_readiness after run."
    if [ "$REQUIRE_TRANSCRIPTS" -eq 1 ]; then
      echo "[notch-live-qa] Strict mode failed: live readiness did not return ready after run."
      strict_failed=1
    fi
  fi

  cp "$LOG_PATH" "$post_log_snapshot"
  echo "[notch-live-qa] Transcript bridge lines since run start:"
  transcript_hits=$(diff -u "$pre_log_snapshot" "$post_log_snapshot" | rg -P 'live (user_transcript|assistant_transcript|bridge (start|stop|unavailable|reload|reset)|evaluate failed|setup failed|stream send failed|start requested|stop requested|bridge unavailable|audio_diagnostic)|chat append (live )?(user|assistant)' || true)
  if [ -z "$transcript_hits" ] && [ -r "$LOG_PATH" ]; then
    transcript_hits=$(rg -P 'live (user_transcript|assistant_transcript|bridge (start|stop|unavailable|reload|reset)|evaluate failed|setup failed|stream send failed|start requested|stop requested|bridge unavailable|audio_diagnostic)|chat append (live )?(user|assistant)' "$LOG_PATH" || true)
  fi
  if [ -n "$transcript_hits" ]; then
    echo "$transcript_hits"
  else
    echo "[notch-live-qa] No transcript/bridge diff lines matched this run."
    if [ "$REQUIRE_TRANSCRIPTS" -eq 1 ]; then
      echo "[notch-live-qa] Strict mode failed: expected at least one transcript/bridge event."
      strict_failed=1
    fi
  fi

  transcript_hits_lc="$(printf '%s\n' "$transcript_hits" | tr '[:upper:]' '[:lower:]')"
  transcript_start_hits="$(printf '%s\n' "$transcript_hits_lc" | rg -c 'live start requested' || echo 0)"
  transcript_stop_hits="$(printf '%s\n' "$transcript_hits_lc" | rg -c 'live stop requested' || echo 0)"
  audio_frame_hits="$(printf '%s\n' "$transcript_hits_lc" | rg -c 'live audio_diagnostic reason=audio_frame' || echo 0)"
user_transcript_hits="$(printf '%s\n' "$transcript_hits_lc" | rg -c 'live user_transcript .*final=(true|1|yes|y|done|completed|complete|finished|\"true\"|\"1\"|\"yes\"|\"y\"|\"done\"|\"completed\"|\"complete\"|\"finished\"|final\(empty\)|matched stop phrase)' || echo 0)"
assistant_transcript_hits="$(printf '%s\n' "$transcript_hits_lc" | rg -c 'live assistant_transcript .*final=(true|1|yes|y|done|completed|complete|finished|\"true\"|\"1\"|\"yes\"|\"y\"|\"done\"|\"completed\"|\"complete\"|\"finished\"|final\(empty\)|matched stop phrase)' || echo 0)"
  chat_append_user_hits="$(printf '%s\n' "$transcript_hits" | rg -c "chat append live user" || echo 0)"
  chat_append_assistant_hits="$(printf '%s\n' "$transcript_hits" | rg -c "chat append live assistant" || echo 0)"
  audio_diagnostic_hits="$(printf '%s\n' "$transcript_hits_lc" | rg -c 'live audio_diagnostic reason=' || echo 0)"
  bridge_error_hits="$(printf '%s\n' "$transcript_hits" | rg -c "live (bridge unavailable|evaluate failed|setup failed|stream send failed)" || echo 0)"

  echo "[notch-live-qa] Matched counts: user_transcript=$user_transcript_hits assistant_transcript=$assistant_transcript_hits chat_append_user=$chat_append_user_hits chat_append_assistant=$chat_append_assistant_hits"
echo "[notch-live-qa] Transcript lifecycle markers: start=$transcript_start_hits stop=$transcript_stop_hits"
echo "[notch-live-qa] Audio diagnostics: frames=$audio_frame_hits"

  if [ "$REQUIRE_TRANSCRIPTS" -eq 1 ]; then
    if [ "$transcript_start_hits" -lt 1 ]; then
      echo "[notch-live-qa] Strict mode failed: no live start marker was observed for this window."
      strict_failed=1
    fi
    if [ "$audio_frame_hits" -lt 1 ]; then
      echo "[notch-live-qa] Strict mode failed: no live audio frame events observed."
      strict_failed=1
    fi
    if [ "$transcript_stop_hits" -lt 1 ]; then
      echo "[notch-live-qa] Strict mode failed: no live stop marker was observed for this window."
      strict_failed=1
    fi
    if [ "$audio_frame_hits" -lt 1 ] && [ "$transcript_start_hits" -gt 0 ] && [ "$transcript_stop_hits" -gt 0 ]; then
      echo "[notch-live-qa] Strict mode failed: live session started/stopped with zero audio frames."
    fi
    if [ "$before_sessions_empty" -eq 0 ]; then
      echo "[notch-live-qa] Strict mode failed: pre-existing live sessions detected."
      strict_failed=1
    fi
    if [ "$user_transcript_hits" -lt 1 ]; then
      echo "[notch-live-qa] Strict mode failed: no user transcript event observed."
      strict_failed=1
    fi
    if [ "$assistant_transcript_hits" -lt 1 ]; then
      echo "[notch-live-qa] Strict mode failed: no assistant transcript event observed."
      strict_failed=1
    fi
    if [ "$chat_append_user_hits" -lt 1 ]; then
      echo "[notch-live-qa] Strict mode failed: no live user chat append observed."
      strict_failed=1
    fi
    if [ "$chat_append_assistant_hits" -lt 1 ]; then
      echo "[notch-live-qa] Strict mode failed: no live assistant chat append observed."
      strict_failed=1
    fi
    if [ "$added_notch_conversation_turn_count" -eq 0 ]; then
      echo "[notch-live-qa] Note: no new helper conversation turns from source \"notch\" were recorded in /api/notch/status during this run."
      echo "[notch-live-qa] This is expected in the current local architecture; Notch transcripts are imported to Hermes from the live bridge before writeback."
    fi
    if ! [ "$after_session_count" = "0" ]; then
      echo "[notch-live-qa] Strict mode failed: helper sessions not idle after run."
      strict_failed=1
    fi
  fi

if [ "$HAS_DEFAULTS_CHAT_HISTORY" -eq 1 ]; then
    AFTER_CHAT_MESSAGES="$(read_chat_history)"
    AFTER_CHAT_COUNT="$(printf '%s\n' "$AFTER_CHAT_MESSAGES" | jq -r 'length')"
    if ! ADDED_CHAT_MESSAGES="$(jq -n --argjson before "$BEFORE_CHAT_MESSAGES" --argjson after "$AFTER_CHAT_MESSAGES" '[ $after[] | select((.id as $id | ($before | map(.id)) | index($id) | not)) ]')" ; then
      ADDED_CHAT_MESSAGES='[]'
    fi
    ADDED_CHAT_COUNT="$(printf '%s\n' "$ADDED_CHAT_MESSAGES" | jq -r 'length')"
    if ! ADDED_VOICE_CHAT_USER_MESSAGES="$(printf '%s\n' "$ADDED_CHAT_MESSAGES" | jq -r '[ .[] | select(.role == "user" and (.text | startswith("Voice: "))) ] | length')" ; then
      ADDED_VOICE_CHAT_USER_MESSAGES=0
    fi
    if ! ADDED_VOICE_CHAT_ASSISTANT_MESSAGES="$(printf '%s\n' "$ADDED_CHAT_MESSAGES" | jq -r '[ .[] | select(.role == "assistant") ] | length')" ; then
      ADDED_VOICE_CHAT_ASSISTANT_MESSAGES=0
    fi
    echo "[notch-live-qa] Chat history count: before=$BEFORE_CHAT_COUNT after=$AFTER_CHAT_COUNT added=$ADDED_CHAT_COUNT"
    echo "[notch-live-qa] Added visible voice lines: user=$ADDED_VOICE_CHAT_USER_MESSAGES assistant=$ADDED_VOICE_CHAT_ASSISTANT_MESSAGES"

  if [ "$REQUIRE_TRANSCRIPTS" -eq 1 ] && [ "$ADDED_VOICE_CHAT_USER_MESSAGES" -lt 1 ]; then
      echo "[notch-live-qa] Strict mode failed: no new user message added to chat history with Voice: prefix."
      strict_failed=1
    fi
  if [ "$REQUIRE_TRANSCRIPTS" -eq 1 ] && [ "$ADDED_VOICE_CHAT_ASSISTANT_MESSAGES" -lt 1 ]; then
    echo "[notch-live-qa] Strict mode failed: no new assistant message added to chat history."
    strict_failed=1
  fi
else
  echo "[notch-live-qa] Chat history checks skipped: defaults read unavailable."
  if [ "$REQUIRE_TRANSCRIPTS" -eq 1 ]; then
    echo "[notch-live-qa] Strict mode failed: unable to verify visible Hermes chat import without AppStorage."
    strict_failed=1
  fi
  fi

  if [ "$REQUIRE_TRANSCRIPTS" -eq 1 ] && [ "$strict_failed" -eq 1 ]; then
    if [ "$interactive" -eq 1 ]; then
      if [ "$bridge_error_hits" -gt 0 ] || [ -z "$transcript_hits" ]; then
        echo "[notch-live-qa] Capture may have failed. Check for:"
      else
        echo "[notch-live-qa] No manual voice session likely ran in this window."
      fi
      echo "[notch-live-qa] - Microphone setup failed"
      echo "[notch-live-qa] - Microphone stream send failed"
      echo "[notch-live-qa] - live bridge unavailable"
      echo "[notch-live-qa] - live evaluate failed"
      echo "[notch-live-qa] Tail of transcript log for this run:"
      if tail -n 120 "$LOG_PATH" 2>/dev/null | rg -n "live (user_transcript|assistant_transcript|chat append|bridge|start requested|stop requested|evaluate failed|setup failed|stream send failed|bridge unavailable)" ; then
        :
      elif [ "$HAS_LOG" -eq 1 ] && [ -n "$LOG_PATH" ]; then
        tail -n 120 "$LOG_PATH" 2>/dev/null || true
      else
        echo "[notch-live-qa] (no readable MARKSHOT_LOG available for this run)"
      fi
    fi
    strict_exit_code=1
  fi

  if [ "$REQUIRE_TRANSCRIPTS" -eq 1 ] && [ "$strict_failed" -eq 0 ]; then
    echo "[notch-live-qa] Strict mode checks passed."
  fi

  if [ "$REQUIRE_TRANSCRIPTS" -eq 1 ] && [ "$strict_failed" -eq 0 ]; then
    echo "[notch-live-qa] Chat history visible-message checks passed."
  fi

  if [ "$REQUIRE_TRANSCRIPTS" -eq 0 ] && [ -n "$transcript_hits" ] && [ "$interactive" -eq 1 ] && [ "$user_transcript_hits" -lt 1 ] && [ "$assistant_transcript_hits" -lt 1 ]; then
    echo "[notch-live-qa] Hint: run output contains bridge traffic but no transcript events."
  fi
fi

if [ "$HAS_LOG" -eq 1 ]; then
  if [ "$REQUIRE_TRANSCRIPTS" -eq 1 ]; then
    if [ "${strict_failed-0}" -eq 0 ]; then
      echo "[notch-live-qa] SUMMARY: strict_result=passed"
    else
      echo "[notch-live-qa] SUMMARY: strict_result=failed"
    fi
  else
    echo "[notch-live-qa] SUMMARY: strict_result=not_required"
  fi
  echo "[notch-live-qa] SUMMARY: require_transcripts=$REQUIRE_TRANSCRIPTS"
  echo "[notch-live-qa] SUMMARY: sessions before=$before_session_count after=$after_session_count"
  echo "[notch-live-qa] SUMMARY: transcript_hits user=$user_transcript_hits assistant=$assistant_transcript_hits chat_append_user=$chat_append_user_hits chat_append_assistant=$chat_append_assistant_hits"
  echo "[notch-live-qa] SUMMARY: transcript_markers start=$transcript_start_hits stop=$transcript_stop_hits"
  echo "[notch-live-qa] SUMMARY: added_conversation_turns=$added_conversation_turn_count added_notch_turns=$added_notch_conversation_turn_count"
  if [ "$HAS_DEFAULTS_CHAT_HISTORY" -eq 1 ]; then
    echo "[notch-live-qa] SUMMARY: visible_chat_history_readable=1"
    echo "[notch-live-qa] SUMMARY: visible_voice_user=$ADDED_VOICE_CHAT_USER_MESSAGES visible_voice_assistant=$ADDED_VOICE_CHAT_ASSISTANT_MESSAGES"
  else
  echo "[notch-live-qa] SUMMARY: visible_chat_history_readable=0"
  fi
fi

if [ "$strict_exit_code" -eq 1 ]; then
  exit 1
fi

echo "[notch-live-qa] Done."
