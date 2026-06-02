#!/usr/bin/env bash
set -euo pipefail

LOG_PATH="${1:-/tmp/spoken-live-qa.log}"
FAIL=0

if [ -r "$LOG_PATH" ] && [ ! -s "$LOG_PATH" ]; then
  echo "[verify-live-qa] Log file is empty: $LOG_PATH"
  echo "[verify-live-qa] Run-spoken QA again before verification."
  echo "[verify-live-qa]   cd <repo-root>"
  echo "[verify-live-qa]   ./script/run-spoken-live-qa.sh $LOG_PATH"
  exit 2
fi

if [ ! -r "$LOG_PATH" ]; then
  echo "[verify-live-qa] Log file not readable: $LOG_PATH"
  echo "[verify-live-qa] Run:"
  echo "[verify-live-qa]   cd <repo-root> && ./script/run-spoken-live-qa.sh /tmp/spoken-live-qa.log"
  exit 2
fi

require_line() {
  local pattern="$1"
  local label="$2"
  if ! rg -q "$pattern" "$LOG_PATH"; then
    echo "[verify-live-qa] FAIL: missing ${label}"
    FAIL=1
  else
    echo "[verify-live-qa] PASS: found ${label}"
  fi
}

require_line '\[run-spoken-live-qa\] ===== run start id=[^[:space:]]+ =====' 'run-spoken run start marker'
require_line '\[run-spoken-live-qa\] ===== run end id=[^[:space:]]+ status=pass =====' 'run-spoken pass marker'

start_marker_line="$(rg '\[run-spoken-live-qa\] ===== run start id=' "$LOG_PATH" | tail -n 1 || true)"
end_marker_line="$(rg '\[run-spoken-live-qa\] ===== run end id=[^[:space:]]+ status=pass =====' "$LOG_PATH" | tail -n 1 || true)"
if [ -z "$start_marker_line" ] || [ -z "$end_marker_line" ]; then
  echo "[verify-live-qa] FAIL: could not parse run start/end markers."
  FAIL=1
else
  run_start_id="$(printf '%s\n' "$start_marker_line" | sed -E 's/.*run start id=([^[:space:]]+) =====/\1/')"
  run_end_id="$(printf '%s\n' "$end_marker_line" | sed -E 's/.*run end id=([^[:space:]]+) status=.*$/\1/')"
  if [ "$run_start_id" = "" ] || [ "$run_end_id" = "" ]; then
    echo "[verify-live-qa] FAIL: could not parse run start/end IDs from run-spoken markers."
    FAIL=1
  elif [ "$run_start_id" != "$run_end_id" ]; then
    echo "[verify-live-qa] FAIL: run-spoken marker IDs do not match."
    echo "[verify-live-qa]   start_id=$run_start_id"
    echo "[verify-live-qa]   end_id=$run_end_id"
    FAIL=1
  else
    echo "[verify-live-qa] PASS: run-spoken markers match (id=$run_start_id)"
  fi
fi

assert_no_failures() {
  if rg -q "Strict mode failed" "$LOG_PATH"; then
    echo "[verify-live-qa] FAIL: strict mode failure lines present"
    rg "Strict mode failed" "$LOG_PATH" | sed -n '1,10p'
    FAIL=1
  else
    echo "[verify-live-qa] PASS: no strict mode failure lines"
  fi
}

require_line 'before activeSessions: \[\]' 'pre-run active sessions'
require_line 'before activeSessionCount: 0' 'pre-run active session count zero'
require_line 'after activeSessions: \[\]' 'post-run active sessions'
require_line 'after activeSessionCount: 0' 'post-run active session count zero'
require_line 'Strict mode checks passed\.' 'strict mode success marker'
require_line 'SUMMARY: require_transcripts=1' 'strict summary flag'
require_line 'Matched counts: user_transcript=[1-9][0-9]* assistant_transcript=[1-9][0-9]* chat_append_user=[1-9][0-9]* chat_append_assistant=[1-9][0-9]*' 'transcript/append buckets'
require_line 'SUMMARY: transcript_markers start=[1-9][0-9]* stop=[1-9][0-9]*' 'transcript lifecycle markers'
require_line 'Added visible voice lines: user=[1-9][0-9]* assistant=[1-9][0-9]*' 'visible chat import'
require_line 'SUMMARY: visible_chat_history_readable=1' 'visible chat history availability'
require_line 'SUMMARY: strict_result=passed' 'strict summary result'
require_line 'SUMMARY: sessions before=0 after=0' 'helper session cleanup'
require_line 'SUMMARY: visible_voice_user=[1-9][0-9]* visible_voice_assistant=[1-9][0-9]*' 'visible voice summary'
require_line 'App debug log post-size: [1-9][0-9]* bytes' 'app debug post-size line'
require_line 'App debug log delta: [1-9][0-9]* bytes' 'app debug log evidence delta'

assert_no_failures

if [ "$FAIL" -ne 0 ]; then
  echo "[verify-live-qa] RESULT: spoken QA verification failed"
  exit 1
fi

echo "[verify-live-qa] RESULT: spoken QA verification passed"
