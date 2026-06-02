#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER_URL="${HELPER_URL:-http://127.0.0.1:4177}"
LOG_PATH="${MARKSHOT_LOG:-${MARKSHOT_LOG_PATH:-/tmp/markshot-debug.log}}"

REQUIRED_APPS=(
  "curl"
  "jq"
  "rg"
  "diff"
)

for required_cmd in "${REQUIRED_APPS[@]}"; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    echo "[notch-live-qa] Missing required dependency: $required_cmd"
    exit 2
  fi
done

run_json() {
  local path="$1"
  local response
  response="$(curl --connect-timeout 2 --max-time 8 -fsS "$HELPER_URL$path" 2>/dev/null || true)"
  if [ -z "$response" ]; then
    return 1
  fi
  if ! printf '%s\n' "$response" | jq -r . >/dev/null 2>&1; then
    echo "[notch-live-qa] Failed to parse JSON from $HELPER_URL$path"
    echo "[notch-live-qa] Raw response: $response"
    return 1
  fi
  echo "$response"
}

run_live_readiness_level() {
  local readiness
  readiness="$(run_json "/api/live/config" | jq -r '.readiness.level // "unknown"')"
  echo "$readiness"
}

if [ ! -x "$PROJECT_ROOT/script/live-transcript-smoke.sh" ]; then
  echo "[notch-live-qa] Missing executable smoke script: $PROJECT_ROOT/script/live-transcript-smoke.sh"
  exit 2
fi

if ! run_json "/api/health" >/dev/null; then
  echo "[notch-live-qa] Helper is not reachable at $HELPER_URL."
  echo "[notch-live-qa] Start the DeskAgent helper and retry."
  exit 1
fi

before_live_readiness="$(run_live_readiness_level || true)"
echo "[notch-live-qa] before live readiness: $before_live_readiness"
if [ "$before_live_readiness" != "ready" ]; then
  echo "[notch-live-qa] Live readiness is not ready before run."
  echo "[notch-live-qa] Strict spoken validation cannot continue with non-ready live config."
  exit 1
fi

echo "[notch-live-qa] Helper URL: $HELPER_URL"
echo "[notch-live-qa] Log path: $LOG_PATH"
echo "[notch-live-qa] Log path env: MARKSHOT_LOG_PATH or MARKSHOT_LOG"
echo "[notch-live-qa] Project: $PROJECT_ROOT"

if [ ! -r "$LOG_PATH" ]; then
  if [ ! -e "$LOG_PATH" ]; then
    echo "[notch-live-qa] Log file not found; the strict spoken run will still execute but cannot be validated by diff."
    echo "[notch-live-qa] Set MARKSHOT_LOG if needed."
  else
    echo "[notch-live-qa] Log file exists but is not readable; the strict spoken run will still execute but cannot be validated by diff."
  fi
else
  if [ -w "$LOG_PATH" ]; then
    echo "[notch-live-qa] Resetting log before spoken smoke."
    : > "$LOG_PATH"
  else
    echo "[notch-live-qa] Log file is not writable; skipping reset (validation may be noisy)."
    echo "[notch-live-qa] Set MARKSHOT_LOG to a writable path for a clean spoken run."
  fi
fi

STRICT_MODE=1

before_sessions="$(run_json "/api/notch/status" | jq -c '.live.activeSessions // []' || true)"
if [ -n "$before_sessions" ]; then
  before_session_count="$(printf '%s\n' "$before_sessions" | jq -r 'length')"
  echo "[notch-live-qa] before activeSessions: $before_sessions"
  echo "[notch-live-qa] before activeSessionCount: $before_session_count"
else
  echo "[notch-live-qa] Could not read before-session state from helper."
  if [ "$STRICT_MODE" -eq 1 ]; then
    echo "[notch-live-qa] Strict spoken validation requires pre-session helper state."
    exit 1
  fi
fi

if [ ! -t 0 ]; then
  echo "[notch-live-qa] Non-interactive mode; no manual pause."
else
  echo
  cat <<'MSG'
Manual spoken verification recipe:
1) Launch /Applications/MarkShot.app.
2) Click waveform/Listen.
3) Speak a short phrase, for example:
   check live transcript import
4) Wait for assistant response and stop live session.
5) Open Hermes chat and confirm visible user/assistant lines.
6) Press Enter here to run strict validation.
MSG
  read -r _
fi

set +e
"$PROJECT_ROOT/script/live-transcript-smoke.sh" --require-transcripts
qa_status=$?
set -e

after_sessions="$(run_json "/api/notch/status" | jq -c '.live.activeSessions // []' || true)"
if [ -n "$after_sessions" ]; then
  after_session_count="$(printf '%s\n' "$after_sessions" | jq -r 'length')"
  echo "[notch-live-qa] after activeSessions: $after_sessions"
  echo "[notch-live-qa] after activeSessionCount: $after_session_count"
  after_live_readiness="$(run_live_readiness_level || true)"
  echo "[notch-live-qa] after live readiness: $after_live_readiness"
  if [ "$after_live_readiness" != "ready" ] && [ "$STRICT_MODE" -eq 1 ]; then
    echo "[notch-live-qa] Strict spoken validation cannot be trusted after a non-ready live config."
    qa_status=1
  fi
else
  echo "[notch-live-qa] Could not read after-session state from helper."
  if [ "$STRICT_MODE" -eq 1 ]; then
    echo "[notch-live-qa] Strict spoken validation cannot prove cleanup without after-session state."
    qa_status=1
  fi
fi

if [ "$qa_status" -ne 0 ]; then
  echo "[notch-live-qa] Spoken QA strict checks failed. Run through the manual recipe and re-check visible Hermes chat."
  if [ -r "$LOG_PATH" ]; then
    echo "[notch-live-qa] Suggested debug tail:"
    tail -n 160 "$LOG_PATH" | rg "live (start|stop|user_transcript|assistant_transcript|chat append|bridge|evaluate failed|setup failed|stream send failed|live stop requested)" || true
  fi
  echo "[notch-live-qa] If this is a true manual run, we expect a non-empty transcript path and visible Voice/+assistant chat append lines in the smoke output."
  exit "$qa_status"
fi

echo "[notch-live-qa] Spoken QA run complete. Transcript import and strict checks passed."
