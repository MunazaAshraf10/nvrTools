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
#
# -an drops the audio, and it is not an optimisation. The cameras offer G.711
# (pcm_mulaw), which MP4 cannot hold, so the muxer refuses to write a header and
# ffmpeg dies before a single byte reaches disk. Every segment comes out zero
# bytes and the service restart-loops forever.
#
# Dropping it is the right answer anyway. Audio is useless for training a model
# that measures how people move, and a camera at a public venue should not be
# recording the conversations of people who came to play padel.
#
# Matroska, not MP4, and this is not a preference.
#
# MP4 writes its index (the moov atom) when the file closes, so a segment that
# was interrupted is not a short video, it is an unreadable one. Kill ffmpeg,
# lose power, pull a plug: ten minutes of footage becomes garbage. A truncated
# MKV simply plays up to the point it stopped.
#
# It is also the tolerant container. A camera whose HEVC parameter sets do not
# arrive cleanly at the head of a segment produces an MP4 that ffmpeg itself
# cannot read back, and an MKV that reads fine. We hit exactly that.
#
# Nothing downstream cares: ffmpeg, OpenCV, decord and every torch loader read
# MKV without noticing.
exec ffmpeg \
  -hide_banner -loglevel warning \
  -rtsp_transport tcp \
  -timeout 10000000 \
  -i "$RTSP_URL" \
  -map 0:v:0 -an \
  -c copy \
  -f segment \
  -segment_time 600 \
  -segment_format matroska \
  -reset_timestamps 1 \
  -strftime 1 \
  "${OUT}/%Y-%m-%d_%H-%M-%S.mkv"
