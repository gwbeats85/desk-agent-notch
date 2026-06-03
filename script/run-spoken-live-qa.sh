#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT_DIR="$(pwd)"

LOG_PATH="${1:-/tmp/spoken-live-qa.log}"
HELPER_URL="http://127.0.0.1:4177"
APP_PATH="/Applications/MarkShot.app"
APP_LOG_PATH="${MARKSHOT_LOG_PATH:-${MARKSHOT_LOG:-/tmp/markshot-debug.log}}"
MARKSHOT_USER_DEFAULTS_DOMAIN="${MARKSHOT_USER_DEFAULTS_DOMAIN:-com.deskagent.MarkShot}"
MARKSHOT_CHAT_HISTORY_KEY="${MARKSHOT_CHAT_HISTORY_KEY:-markshot.notch.chatHistoryJSON}"
MARKSHOT_START_TIMEOUT_SECONDS="${MARKSHOT_START_TIMEOUT_SECONDS:-12}"
AUTO_START_MARKSHOT="${AUTO_START_MARKSHOT:-1}"
MARKSHOT_BUNDLE_ID="$(/usr/bin/defaults read /Applications/MarkShot.app/Contents/Info.plist CFBundleIdentifier 2>/dev/null || true)"
LOG_DIR="$(dirname "$LOG_PATH")"
RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')-$$-${RANDOM}-${RANDOM}"
APP_LOG_PRE_SIZE=0
APP_LOG_POST_SIZE=0
APP_LOG_DELTA="unknown"
PRE_CHAT_MESSAGES='[]'
PRE_CHAT_COUNT=0
RUN_END_MARKER_EMITTED=0
RUN_STATUS="failed"

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

MARKSHOT_USER_DEFAULTS_DOMAIN="$(resolve_defaults_domain "$MARKSHOT_CHAT_HISTORY_KEY")"
if [ -z "$MARKSHOT_BUNDLE_ID" ]; then
  MARKSHOT_BUNDLE_ID="$MARKSHOT_USER_DEFAULTS_DOMAIN"
fi

mic_permission_state() {
  local client_id="$1"
  local client_label="$2"
  local row
  local auth_value
  local auth_reason

  row="$(sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "select client,auth_value,auth_reason from access where service='kTCCServiceMicrophone' and client='$client_id' limit 1" 2>/dev/null || true)"
  if [ -z "$row" ]; then
    echo "[run-spoken-live-qa] Mic permission: no TCC row for ${client_label} (${client_id})"
    return 1
  fi
  auth_value="$(printf '%s\n' "$row" | awk -F'|' '{print $2}')"
  auth_reason="$(printf '%s\n' "$row" | awk -F'|' '{print $3}')"
  echo "[run-spoken-live-qa] Mic permission for ${client_label} (${client_id}): auth_value=${auth_value} auth_reason=${auth_reason}"
}

log_run_end_marker() {
  local run_status="${1:-failed}"
  if [ "$RUN_END_MARKER_EMITTED" = "1" ]; then
    return
  fi
  RUN_END_MARKER_EMITTED=1
  if [ "$run_status" = "pass" ]; then
    echo "[run-spoken-live-qa] ===== run end id=${RUN_ID} status=pass ====="
  else
    echo "[run-spoken-live-qa] ===== run end id=${RUN_ID} status=failed ====="
  fi
}

trap 'log_run_end_marker "$RUN_STATUS"' EXIT

if ! /usr/bin/which defaults >/dev/null 2>&1; then
  echo "[run-spoken-live-qa] macOS 'defaults' command not found; verify environment manually."
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "[run-spoken-live-qa] Missing required dependency: jq"
  exit 3
fi
if ! command -v rg >/dev/null 2>&1; then
  echo "[run-spoken-live-qa] Missing required dependency: rg"
  exit 3
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "[run-spoken-live-qa] Missing required dependency: curl"
  exit 3
fi
if [ ! -d "$LOG_DIR" ]; then
  echo "[run-spoken-live-qa] Log directory not found: $LOG_DIR"
  exit 3
fi

if [ ! -x "$SCRIPT_DIR/script/live-transcript-qa.sh" ]; then
  echo "[run-spoken-live-qa] Missing executable script: $SCRIPT_DIR/script/live-transcript-qa.sh"
  exit 3
fi

if [ ! -x "$SCRIPT_DIR/script/live-transcript-verify.sh" ]; then
  echo "[run-spoken-live-qa] Missing executable script: $SCRIPT_DIR/script/live-transcript-verify.sh"
  exit 3
fi
# Start with a clean per-run log so stale evidence can't produce false positives.
if ! : > "$LOG_PATH" 2>/dev/null; then
  echo "[run-spoken-live-qa] Failed to clear log file before run: $LOG_PATH"
  exit 3
fi
# Keep the complete spoken QA trace in one file, including preflight and teardown output.
exec > >(tee -a "$LOG_PATH")
exec 2>&1

read_chat_history() {
  if ! command -v defaults >/dev/null 2>&1; then
    echo "[]"
    return 0
  fi

  local raw_json
  local parsed_json
  raw_json="$(defaults read "$MARKSHOT_USER_DEFAULTS_DOMAIN" "$MARKSHOT_CHAT_HISTORY_KEY" 2>/dev/null || true)"
  if [ -z "$raw_json" ]; then
    echo "[]"
    return 0
  fi
  if ! parsed_json="$(printf '%s\n' "$raw_json" | jq -c 'if type == "array" then . else [] end' 2>/dev/null)"; then
    parsed_json='[]'
  fi
  printf '%s\n' "$parsed_json"
}

read_chat_history_counts() {
  PRE_CHAT_MESSAGES="$(read_chat_history)"
  PRE_CHAT_COUNT="$(printf '%s\n' "$PRE_CHAT_MESSAGES" | jq -r 'length')"
  echo "[run-spoken-live-qa] chat history before count: $PRE_CHAT_COUNT"
}

echo "[run-spoken-live-qa] ===== run start id=${RUN_ID} ====="

if [ ! -t 0 ]; then
  echo "[run-spoken-live-qa] This script requires an interactive terminal for spoken verification."
  echo "[run-spoken-live-qa] Run from Terminal.app:"
  echo "[run-spoken-live-qa]   cd <repo-root>"
  echo "[run-spoken-live-qa]   ./script/run-spoken-live-qa.sh ${LOG_PATH}"
  exit 2
fi

if [ ! -d "$APP_PATH" ]; then
  echo "[run-spoken-live-qa] MarkShot app not found at $APP_PATH"
  echo "[run-spoken-live-qa] Install/update app first via:"
    echo "[run-spoken-live-qa]   cd <repo-root> && ./script/build_and_run.sh --install"
  exit 3
fi

if ! pgrep -f "/Applications/MarkShot.app/Contents/MacOS/MarkShot" >/dev/null; then
  echo "[run-spoken-live-qa] MarkShot process is not running."
  if [ "$AUTO_START_MARKSHOT" = "1" ]; then
    echo "[run-spoken-live-qa] AUTO_START_MARKSHOT enabled; attempting to launch $APP_PATH."
    if ! open "$APP_PATH" >/dev/null 2>&1; then
      echo "[run-spoken-live-qa] Failed to launch MarkShot automatically."
      echo "[run-spoken-live-qa] Start /Applications/MarkShot.app manually and retry this command."
      exit 3
    fi
    waited_seconds=0
    while [ "$waited_seconds" -lt "$MARKSHOT_START_TIMEOUT_SECONDS" ]; do
      if pgrep -f "/Applications/MarkShot.app/Contents/MacOS/MarkShot" >/dev/null; then
        echo "[run-spoken-live-qa] MarkShot process detected after ${waited_seconds}s."
        break
      fi
      sleep 1
      waited_seconds=$((waited_seconds + 1))
    done
  fi
fi
if ! pgrep -f "/Applications/MarkShot.app/Contents/MacOS/MarkShot" >/dev/null; then
  echo "[run-spoken-live-qa] MarkShot did not start after wait window."
  echo "[run-spoken-live-qa] Start /Applications/MarkShot.app and retry this command."
  exit 3
fi

if ! curl -sfS "$HELPER_URL/api/health" >/dev/null; then
  echo "[run-spoken-live-qa] Helper not reachable at $HELPER_URL"
  echo "[run-spoken-live-qa] Start DeskAgent helper first, then rerun this command."
  exit 3
fi

if ! status="$(curl -sfS "$HELPER_URL/api/notch/status")"; then
  echo "[run-spoken-live-qa] Could not fetch helper notch status."
  exit 3
fi

if ! live_status="$(curl -sfS "$HELPER_URL/api/live/config")"; then
  echo "[run-spoken-live-qa] Could not fetch helper live config."
  exit 3
fi

if ! printf '%s' "$live_status" | jq -e '.readiness.level == "ready"' >/dev/null; then
  echo "[run-spoken-live-qa] Helper live readiness is not ready."
  printf '%s\n' "$live_status" | jq -r '.readiness | "level=\(.level) nextStep=\(.nextStep)"' || true
  exit 3
fi

if ! before_active_sessions="$(printf '%s' "$status" | jq -c '.live.activeSessions // []' 2>/dev/null)"; then
  echo "[run-spoken-live-qa] Could not parse activeSessions from helper status."
  exit 3
fi
before_active_session_count="$(printf '%s\n' "$before_active_sessions" | jq -r 'length')"
echo "[run-spoken-live-qa] before activeSessions: $before_active_sessions"
echo "[run-spoken-live-qa] before activeSessionCount: $before_active_session_count"
if [ "$before_active_session_count" != "0" ]; then
  echo "[run-spoken-live-qa] Helper activeSessions is not empty; clean up by stopping live sessions first."
  printf '%s\n' "$status" | jq -r '{activeSessions,activeCount:(.live.activeSessions|length)}' || true
  exit 3
fi

echo "[run-spoken-live-qa] Preflight passed. Helper idle and ready for spoken QA."
printf '%s\n' "$live_status" | jq -r 'if .provider then "provider=\(.provider) model=\(.model)" else "provider=unknown model=unknown" end'
echo "[run-spoken-live-qa] Starting strict spoken QA. Open MarkShot and run Listen with a short phrase during this run."
echo "[run-spoken-live-qa] Log path: $LOG_PATH"
echo "[run-spoken-live-qa] App debug log path: $APP_LOG_PATH (env: MARKSHOT_LOG_PATH or MARKSHOT_LOG)"
echo "[run-spoken-live-qa] App: /Applications/MarkShot.app"
echo "[run-spoken-live-qa] App bundle id: ${MARKSHOT_BUNDLE_ID:-unknown}"
if command -v sqlite3 >/dev/null 2>&1; then
  mic_permission_state "$MARKSHOT_BUNDLE_ID" "app bundle id" || true
  for candidate in "$MARKSHOT_USER_DEFAULTS_DOMAIN" com.deskagent.MarkShot; do
    [ "$candidate" = "$MARKSHOT_BUNDLE_ID" ] && continue
    mic_permission_state "$candidate" "legacy candidate" || true
  done
else
  echo "[run-spoken-live-qa] sqlite3 not available; skipping microphone permission precheck."
fi

echo "[run-spoken-live-qa] App defaults domain: $MARKSHOT_USER_DEFAULTS_DOMAIN key: $MARKSHOT_CHAT_HISTORY_KEY"
if [ -d "$APP_LOG_PATH" ]; then
  echo "[run-spoken-live-qa] App debug log path is a directory: $APP_LOG_PATH"
  echo "[run-spoken-live-qa] Set MARKSHOT_LOG_PATH to a writable file path."
  exit 3
fi
if [ -e "$APP_LOG_PATH" ] && [ ! -f "$APP_LOG_PATH" ]; then
  echo "[run-spoken-live-qa] App debug log path is not a file: $APP_LOG_PATH"
  echo "[run-spoken-live-qa] Set MARKSHOT_LOG_PATH to a writable file path."
  exit 3
fi
if [ ! -e "$APP_LOG_PATH" ]; then
  if : > "$APP_LOG_PATH" 2>/dev/null; then
    echo "[run-spoken-live-qa] App debug log did not exist; created ${APP_LOG_PATH}."
  else
    echo "[run-spoken-live-qa] App debug log path is not writable at start: $APP_LOG_PATH"
    echo "[run-spoken-live-qa] Set MARKSHOT_LOG_PATH (or MARKSHOT_LOG) to an explicit writable file path before running."
    exit 3
  fi
elif [ -e "$APP_LOG_PATH" ] && [ ! -w "$APP_LOG_PATH" ]; then
  echo "[run-spoken-live-qa] App debug log exists but is not writable: $APP_LOG_PATH"
  echo "[run-spoken-live-qa] Set MARKSHOT_LOG_PATH (or MARKSHOT_LOG) to an explicit writable file path before running."
  exit 3
fi

if [ -r "$APP_LOG_PATH" ]; then
  APP_LOG_PRE_SIZE="$(wc -c < "$APP_LOG_PATH" | tr -d ' ')"
  echo "[run-spoken-live-qa] App debug log pre-size: ${APP_LOG_PRE_SIZE} bytes"
elif [ -e "$APP_LOG_PATH" ]; then
  echo "[run-spoken-live-qa] App debug log exists but is not readable; pre-size unavailable."
else
  echo "[run-spoken-live-qa] App debug log does not exist yet."
fi

if command -v defaults >/dev/null 2>&1; then
  read_chat_history_counts
else
  echo "[run-spoken-live-qa] defaults unavailable; chat history preflight skipped."
fi

set +e
MARKSHOT_LOG_PATH="$APP_LOG_PATH" \
  MARKSHOT_LOG="$APP_LOG_PATH" \
  MARKSHOT_USER_DEFAULTS_DOMAIN="$MARKSHOT_USER_DEFAULTS_DOMAIN" \
  MARKSHOT_CHAT_HISTORY_KEY="$MARKSHOT_CHAT_HISTORY_KEY" \
  "$SCRIPT_DIR/script/live-transcript-qa.sh"
qa_status=$?
set -e

if command -v defaults >/dev/null 2>&1; then
  if ! POST_CHAT_MESSAGES="$(read_chat_history)"; then
    POST_CHAT_MESSAGES='[]'
  fi
  POST_CHAT_COUNT="$(printf '%s\n' "$POST_CHAT_MESSAGES" | jq -r 'length')"
  if ! ADDED_CHAT_MESSAGES="$(jq -n --argjson before "$PRE_CHAT_MESSAGES" --argjson after "$POST_CHAT_MESSAGES" '[ $after[] | select((.id as $id | ($before | map(.id)) | index($id) | not)) ]')"; then
    ADDED_CHAT_MESSAGES='[]'
  fi
  ADDED_VOICE_CHAT_USER="$(printf '%s\n' "$ADDED_CHAT_MESSAGES" | jq -r '[ .[] | select(.role == "user" and (.text | startswith("Voice: "))) ] | length')"
  ADDED_VOICE_CHAT_ASSISTANT="$(printf '%s\n' "$ADDED_CHAT_MESSAGES" | jq -r '[ .[] | select(.role == "assistant") ] | length')"
  echo "[run-spoken-live-qa] chat history after count: $POST_CHAT_COUNT"
  echo "[run-spoken-live-qa] chat history added count: $((POST_CHAT_COUNT - PRE_CHAT_COUNT))"
  echo "[run-spoken-live-qa] chat history added visible lines: user=$ADDED_VOICE_CHAT_USER assistant=$ADDED_VOICE_CHAT_ASSISTANT"
else
  echo "[run-spoken-live-qa] chat history diff skipped (defaults unavailable)."
fi

if [ -r "$APP_LOG_PATH" ]; then
  APP_LOG_POST_SIZE="$(wc -c < "$APP_LOG_PATH" | tr -d ' ')"
  APP_LOG_DELTA=$((APP_LOG_POST_SIZE - APP_LOG_PRE_SIZE))
  echo "[run-spoken-live-qa] App debug log post-size: ${APP_LOG_POST_SIZE} bytes"
  if [ "$APP_LOG_DELTA" -lt 0 ]; then
    echo "[run-spoken-live-qa] App debug log shrank during run; treating delta as 0."
    APP_LOG_DELTA=0
  fi
  echo "[run-spoken-live-qa] App debug log delta: ${APP_LOG_DELTA} bytes"
  if [ "$APP_LOG_DELTA" -eq 0 ]; then
    echo "[run-spoken-live-qa] App debug log did not grow during this run; no app-side transcript events were observed."
    qa_status=1
  fi
  echo "[run-spoken-live-qa] Captured app debug log tail:"
  echo "[run-spoken-live-qa] --- app debug log tail start ---"
  tail -n 200 "$APP_LOG_PATH"
  echo "[run-spoken-live-qa] --- app debug log tail end ---"
elif [ -w "$APP_LOG_PATH" ]; then
  echo "[run-spoken-live-qa] App debug log exists but is not readable: $APP_LOG_PATH"
else
  echo "[run-spoken-live-qa] App debug log not readable: $APP_LOG_PATH"
fi

echo "[run-spoken-live-qa] Running spoken QA verifier."
set +e
"$SCRIPT_DIR/script/live-transcript-verify.sh" "$LOG_PATH"
verify_status=$?
set -e

if [ "$verify_status" -eq 0 ]; then
  RUN_STATUS="pass"
  echo "[run-spoken-live-qa] COMPLETE: spoken QA evidence passes strict criteria."
  exit 0
fi

echo "[run-spoken-live-qa] NOTE: verifier failed. Keep this log for manual review."
exit "$verify_status"
