#!/usr/bin/env bash
# Drain finished segments to S3, then delete them locally.
#
# Two rules, and the whole offline story falls out of them:
#
#   Only touch files older than 11 minutes. A segment rotates every 10, so an
#   11 minute old file is one ffmpeg has closed and will never write to again.
#   Uploading a file that is still being written gives you a truncated MP4.
#
#   Delete only after the upload succeeds. If the link is down, cp fails, the
#   file stays on disk, and the next run picks it up. That is the retry queue:
#   there is no queue, there is just a disk and an && .
set -euo pipefail

# shellcheck source=/dev/null
source /etc/padelytix/cameras.env

FOOTAGE=/var/lib/padelytix/footage

find "$FOOTAGE" -type f -name '*.mp4' -mmin +11 -print0 | while IFS= read -r -d '' file; do
    cam=$(basename "$(dirname "$file")")
    name=$(basename "$file")
    day=${name%%_*}

    if aws s3 cp "$file" "s3://${S3_BUCKET}/${cam}/${day}/${name}" \
        --storage-class INTELLIGENT_TIERING \
        --only-show-errors; then
        rm -f "$file"
        echo "uploaded ${cam}/${day}/${name}"
    else
        # Left on disk on purpose. The next run retries it.
        echo "upload failed, keeping ${name} for the next run" >&2
    fi
done
