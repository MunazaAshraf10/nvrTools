#!/usr/bin/env bash
# Start or stop every camera named in cameras.env.
#
# The camera list lives in one place. This reads it, so nothing has to be kept
# in sync by hand.
set -euo pipefail

ACTION="${1:?usage: session.sh start|stop}"

# shellcheck source=/dev/null
source /etc/padelytix/cameras.env

cams=()
while IFS='=' read -r key _; do
    [[ $key == CAM_* ]] && cams+=("${key#CAM_}")
done < <(grep -E '^CAM_' /etc/padelytix/cameras.env)

if [[ ${#cams[@]} -eq 0 ]]; then
    echo "no CAM_* entries in /etc/padelytix/cameras.env" >&2
    exit 1
fi

for cam in "${cams[@]}"; do
    echo "${ACTION}: ${cam}"
    systemctl "$ACTION" "padelytix-record@${cam}.service"
done
