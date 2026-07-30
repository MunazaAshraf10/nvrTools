#!/usr/bin/env bash
# Drain finished segments to S3, but only the ones inside a booked window.
#
# The box records continuously. It does not keep everything: it asks the app which windows
# on this venue are booked and uploads only the segments that fall inside one. Footage nobody
# booked is deleted, not stored, which is the privacy and the storage story in one rule.
#
# Three rules, and the whole offline and extension story falls out of them:
#
#   A segment is closed once ffmpeg has moved on to the next file. We treat a file not written
#   to for two minutes as closed. Uploading a file still being written gives a truncated MKV.
#
#   If the app cannot be reached, keep everything and retry. We must never delete footage we
#   could not classify: the link being down is not evidence a match was not played. The disk
#   is the retry queue, exactly as before.
#
#   A segment outside every booked window is kept until it ages past the buffer, then deleted.
#   The buffer is there so a booking extended mid-match (its window_end grows) still claims the
#   segment on the next poll before it is thrown away.
set -euo pipefail

# shellcheck source=/dev/null
source /etc/padelytix/cameras.env

FOOTAGE=/var/lib/padelytix/footage
CLOSED_MIN=2      # a file untouched this long is closed and safe to upload
KEEP_BUFFER_MIN=30  # keep an unbooked-but-recent segment this long, for a late extension

: "${S3_BUCKET:?S3_BUCKET missing from cameras.env}"
: "${VENUE_ID:?VENUE_ID missing from cameras.env}"
: "${PDX_API_BASE_URL:?PDX_API_BASE_URL missing from cameras.env}"
: "${CAMERA_HMAC_SECRET:?CAMERA_HMAC_SECRET missing from cameras.env}"

sign() { printf '%s' "$1" | openssl dgst -sha256 -hmac "$CAMERA_HMAC_SECRET" | awk '{print $NF}'; }

# Ask the app which windows are booked on this venue. Signed with the camera secret, the same
# one the heartbeat uses. On any failure we keep everything and retry next run.
body=$(printf '{"signed_at":%s,"venue_id":%s}' "$(date -u +%s)" "$VENUE_ID")
if ! plan=$(curl -fsS -X POST "${PDX_API_BASE_URL}/internal/recording/plan" \
        -H 'content-type: application/json' \
        -H "x-pdx-signature: $(sign "$body")" \
        -d "$body" 2>/dev/null); then
    echo "recording plan unreachable, keeping all footage for the next run" >&2
    exit 0
fi

now=$(date -u +%s)

# All windows for a court, as "start_epoch end_epoch" lines. Empty if the court is not booked.
windows_for() {
    printf '%s' "$plan" | jq -r --arg c "$1" \
        '.courts[] | select(.court_folder==$c) | .windows[] | "\(.window_start) \(.window_end)"' \
        | while read -r ws we; do
            echo "$(date -u -d "$ws" +%s) $(date -u -d "$we" +%s)"
        done
}

find "$FOOTAGE" -type f -name '*.mkv' -mmin +${CLOSED_MIN} -print0 | while IFS= read -r -d '' file; do
    cam=$(basename "$(dirname "$file")")     # e.g. court1_cam5
    court=${cam%_cam*}                        # e.g. court1
    name=$(basename "$file")                  # 2026-07-31_16-20-00.mkv
    day=${name%%_*}

    # The filename is local venue time; the box is at the venue, so its clock is that time.
    stamp=${name%.mkv}
    seg_start=$(date -d "${stamp:0:10} ${stamp:11:2}:${stamp:14:2}:${stamp:17:2}" +%s)
    seg_end=$((seg_start + 600))

    booked=0
    while read -r ws we; do
        [ -z "$ws" ] && continue
        if [ "$seg_start" -lt "$we" ] && [ "$seg_end" -gt "$ws" ]; then
            booked=1
            break
        fi
    done < <(windows_for "$court")

    if [ "$booked" -eq 1 ]; then
        if aws s3 cp "$file" "s3://${S3_BUCKET}/${cam}/${day}/${name}" \
                --storage-class INTELLIGENT_TIERING --only-show-errors; then
            rm -f "$file"
            echo "uploaded ${cam}/${day}/${name}"
        else
            echo "upload failed, keeping ${name} for the next run" >&2
        fi
    elif [ $(((now - seg_start) / 60)) -ge "$KEEP_BUFFER_MIN" ]; then
        # Aged out and never booked: nobody paid for this, so it is not stored.
        rm -f "$file"
        echo "dropped unbooked ${cam}/${day}/${name}"
    fi
    # Otherwise: recent and unbooked. Keep it, a late extension may yet claim it.
done
