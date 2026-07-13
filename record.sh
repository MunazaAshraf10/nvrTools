#!/usr/bin/env bash
# Record one camera into a rolling set of 10 minute segments.
#
# -c copy is the whole trick: the camera has already encoded H.264/H.265, so we
# copy those bytes to disk rather than decoding and re-encoding them. It costs
# almost no CPU, which is why a used office laptop is enough hardware, and it
# means the training footage is bit for bit what the sensor produced.
#
# systemd restarts this if the camera drops, so no retry logic lives here.
set -euo pipefail

CAM_NAME="${1:?usage: record.sh <camera-name>}"

# shellcheck source=/dev/null
source /etc/padelytix/cameras.env

VAR="CAM_${CAM_NAME}"
RTSP_URL="${!VAR:?no CAM_${CAM_NAME} in /etc/padelytix/cameras.env}"

OUT="/var/lib/padelytix/footage/${CAM_NAME}"
mkdir -p "$OUT"

# rtsp_transport tcp: UDP silently drops packets under load and corrupts frames.
# timeout: give up on a dead camera after 10s (microseconds here) so systemd can
# restart us, rather than hanging forever on a socket that will never answer.
exec ffmpeg \
  -hide_banner -loglevel warning \
  -rtsp_transport tcp \
  -timeout 10000000 \
  -i "$RTSP_URL" \
  -c copy \
  -f segment \
  -segment_time 600 \
  -segment_format mp4 \
  -reset_timestamps 1 \
  -strftime 1 \
  "${OUT}/%Y-%m-%d_%H-%M-%S.mp4"
