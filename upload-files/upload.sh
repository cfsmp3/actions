#!/usr/bin/env bash
#
# Upload files matching UPLOAD_PATTERN in UPLOAD_FROM to the server with rsync.
#
# Every leg of a build matrix uploads at about the same time, and the server's
# sshd drops connections it cannot take yet ("kex_exchange_identification:
# Connection closed by remote host"). Such failures are retried with a growing,
# randomized delay; any other rsync error fails right away.
#
# The legs also upload into the same new run-<id> folder at the same time. The
# folder is made with "mkdir -p" on the server, in rsync's own connection, so
# legs racing to make it don't fail: rsync --mkpath failed with "mkdir ...
# failed: File exists" (exit code 11) when another leg made it first.

set -eo pipefail

: "${UPLOAD_FROM:?}" "${UPLOAD_PATTERN:?}" "${UPLOAD_TO_BASE:?}" "${UPLOAD_TO_FOLDER:?}"
: "${SERVER_USERNAME:?}" "${SERVER_ADDRESS:?}"

ATTEMPTS="${UPLOAD_RETRY_ATTEMPTS:-5}"
DELAY="${UPLOAD_RETRY_DELAY:-10}"

# rsync exit codes worth retrying: 255 (ssh could not connect), 10 (socket
# I/O), 12 (protocol data stream), 30 (send/receive timeout), 35 (connection
# timeout)
is_transient() {
  case "$1" in
    255 | 10 | 12 | 30 | 35) return 0 ;;
    *) return 1 ;;
  esac
}

retry() {
  local attempt=1 rc wait
  while true; do
    rc=0
    "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    if ! is_transient "$rc" || [ "$attempt" -ge "$ATTEMPTS" ]; then
      echo "::error::'$1' failed with exit code $rc (attempt $attempt of $ATTEMPTS)"
      return "$rc"
    fi
    wait=$((DELAY * attempt + RANDOM % (DELAY + 1)))
    echo "::warning::'$1' failed with exit code $rc (attempt $attempt of $ATTEMPTS), retrying in ${wait}s"
    sleep "$wait"
    attempt=$((attempt + 1))
  done
}

UPLOAD_FULL_PATH="${UPLOAD_TO_BASE%/}/${UPLOAD_TO_FOLDER%/}/"

if [ "${USE_RUN_NUMBER}" == "true" ]; then
  UPLOAD_FULL_PATH+="run-${RUN_ID:?}/"
fi

# run on the server before rsync, in the same ssh connection
printf -v rsync_path 'mkdir -p %q && rsync' "$UPLOAD_FULL_PATH"

# the pattern is a glob and is meant to be expanded here
# shellcheck disable=SC2206
sources=(${UPLOAD_FROM%/}/${UPLOAD_PATTERN})

echo "::group::Uploading files..."
retry rsync \
  -avzhH \
  --ignore-missing-args --rsync-path="$rsync_path" \
  "${sources[@]}" \
  "${SERVER_USERNAME}@${SERVER_ADDRESS}:${UPLOAD_FULL_PATH}"
echo "::endgroup::"
