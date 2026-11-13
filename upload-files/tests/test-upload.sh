#!/usr/bin/env bash
#
# Tests for upload-files/upload.sh.
#
# rsync and ssh are replaced by stubs on PATH that fail a given number of
# times with a given exit code before they succeed, and log their arguments.
#
# Requires: bash
#
# Usage: upload-files/tests/test-upload.sh

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UPLOAD="${SCRIPT_DIR}/../upload.sh"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

FAILED=0

pass() {
  echo -e "\033[0;32mPASS\033[0m: $1"
}

fail() {
  echo -e "\033[0;31mFAIL\033[0m: $1"
  FAILED=1
}

# write a stub for command $1 into $WORK_DIR/bin
write_stub() {
  cat >"$WORK_DIR/bin/$1" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$WORK_DIR/$1.calls"
n=\$(cat "$WORK_DIR/$1.count" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$WORK_DIR/$1.count"
if [ "\$n" -lt "\${STUB_FAIL_TIMES:-0}" ]; then
  exit "\${STUB_FAIL_CODE:-255}"
fi
exit 0
STUB
  chmod +x "$WORK_DIR/bin/$1"
}

# run upload.sh with the given extra environment; sets RC and OUT
run_case() {
  rm -rf "${WORK_DIR:?}/bin" "$WORK_DIR"/*.calls "$WORK_DIR"/*.count "$WORK_DIR/publish"
  mkdir -p "$WORK_DIR/bin" "$WORK_DIR/publish/ubuntu/noble/unstable"
  touch "$WORK_DIR/publish/ubuntu/noble/unstable/foo_1.0_amd64.deb" "$WORK_DIR/publish/SOURCELOG_x.txt"
  write_stub rsync
  write_stub ssh

  RC=0
  OUT=$(env PATH="$WORK_DIR/bin:$PATH" \
    UPLOAD_FROM="$WORK_DIR/publish/" \
    UPLOAD_PATTERN="${PATTERN:-*}" \
    UPLOAD_TO_BASE="/opt/archives/packages/" \
    UPLOAD_TO_FOLDER="foo" \
    USE_RUN_NUMBER="true" \
    RUN_ID="42" \
    SERVER_USERNAME="user" \
    SERVER_ADDRESS="host" \
    UPLOAD_RETRY_DELAY=0 \
    "$@" \
    "$UPLOAD" 2>&1) || RC=$?
}

count() {
  cat "$WORK_DIR/$1.count" 2>/dev/null || echo 0
}

# 1. first try works: one rsync call with the expected arguments
run_case
if [ "$RC" -eq 0 ] && [ "$(count rsync)" -eq 1 ] && [ "$(count ssh)" -eq 0 ] &&
  grep -q -F -- "-avzhH --ignore-missing-args --rsync-path=mkdir -p /opt/archives/packages/foo/run-42/ && rsync $WORK_DIR/publish/SOURCELOG_x.txt $WORK_DIR/publish/ubuntu user@host:/opt/archives/packages/foo/run-42/" "$WORK_DIR/rsync.calls"; then
  pass "uploads once with the expanded pattern and the run folder"
else
  fail "uploads once with the expanded pattern and the run folder (rc=$RC, calls: $(cat "$WORK_DIR/rsync.calls" 2>/dev/null))"
fi

# 2. ssh connection drops (exit 255) are retried until rsync succeeds
run_case STUB_FAIL_TIMES=2 STUB_FAIL_CODE=255
if [ "$RC" -eq 0 ] && [ "$(count rsync)" -eq 3 ] && grep -q "attempt 2 of 5" <<<"$OUT"; then
  pass "retries rsync after ssh connection failures"
else
  fail "retries rsync after ssh connection failures (rc=$RC, calls=$(count rsync))"
fi

# 3. gives up after the last attempt and returns rsync's exit code
run_case STUB_FAIL_TIMES=10 STUB_FAIL_CODE=255 UPLOAD_RETRY_ATTEMPTS=3
if [ "$RC" -eq 255 ] && [ "$(count rsync)" -eq 3 ] && grep -q "::error::'rsync' failed with exit code 255 (attempt 3 of 3)" <<<"$OUT"; then
  pass "gives up after the last attempt"
else
  fail "gives up after the last attempt (rc=$RC, calls=$(count rsync))"
fi

# 4. other errors are not retried
run_case STUB_FAIL_TIMES=1 STUB_FAIL_CODE=23
if [ "$RC" -eq 23 ] && [ "$(count rsync)" -eq 1 ]; then
  pass "does not retry non-connection errors"
else
  fail "does not retry non-connection errors (rc=$RC, calls=$(count rsync))"
fi

# 5. the folder is made with mkdir -p in rsync's own connection, never with
#    --mkpath (which fails when another leg makes the folder first) or an
#    extra ssh connection
run_case
if [ "$RC" -eq 0 ] && [ "$(count ssh)" -eq 0 ] &&
  grep -q -F -- "--rsync-path=mkdir -p /opt/archives/packages/foo/run-42/ && rsync" "$WORK_DIR/rsync.calls" &&
  ! grep -q -- "--mkpath" "$WORK_DIR/rsync.calls"; then
  pass "makes the folder race-free in rsync's connection"
else
  fail "makes the folder race-free in rsync's connection (rc=$RC, ssh=$(count ssh), calls: $(cat "$WORK_DIR/rsync.calls" 2>/dev/null))"
fi

# 6. a pattern that matches nothing is passed on for --ignore-missing-args
PATTERN="NOTHING_*.txt" run_case
if [ "$RC" -eq 0 ] && grep -q -F -- "&& rsync $WORK_DIR/publish/NOTHING_*.txt user@host:" "$WORK_DIR/rsync.calls"; then
  pass "passes an unmatched pattern through"
else
  fail "passes an unmatched pattern through (rc=$RC, calls: $(cat "$WORK_DIR/rsync.calls" 2>/dev/null))"
fi

# 7. without the run number the files go straight into the folder
run_case USE_RUN_NUMBER=false
if [ "$RC" -eq 0 ] && grep -q "user@host:/opt/archives/packages/foo/$" "$WORK_DIR/rsync.calls" &&
  grep -q -F -- "--rsync-path=mkdir -p /opt/archives/packages/foo/ && rsync" "$WORK_DIR/rsync.calls"; then
  pass "uploads into the folder without a run subfolder"
else
  fail "uploads into the folder without a run subfolder (rc=$RC, calls: $(cat "$WORK_DIR/rsync.calls" 2>/dev/null))"
fi

exit "$FAILED"
