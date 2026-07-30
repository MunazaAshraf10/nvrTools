#!/usr/bin/env bash
# Turn a fresh Ubuntu box at a court into a recorder. Run once, as root.
#
#   sudo ./provision.sh
#
# Idempotent: safe to run again after editing a unit.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "run as root: sudo ./provision.sh" >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> packages"
apt-get update -qq
# jq parses the booking plan the sync step fetches; openssl signs that request. curl fetches
# it. All small, all standard.
apt-get install -y -qq ffmpeg awscli curl jq openssl

echo "==> a user that owns the footage and nothing else"
if ! id padelytix &>/dev/null; then
    useradd --system --create-home --home-dir /var/lib/padelytix --shell /usr/sbin/nologin padelytix
fi
install -d -o padelytix -g padelytix /var/lib/padelytix/footage

echo "==> scripts"
install -d /opt/padelytix
install -m 0755 "$HERE/record.sh" "$HERE/sync.sh" "$HERE/session.sh" /opt/padelytix/

echo "==> config"
install -d /etc/padelytix
if [[ ! -f /etc/padelytix/cameras.env ]]; then
    install -m 0640 -o root -g padelytix "$HERE/cameras.env.example" /etc/padelytix/cameras.env
    echo "    wrote /etc/padelytix/cameras.env  <-- EDIT THIS, it has placeholder URLs"
else
    echo "    /etc/padelytix/cameras.env exists, left alone"
fi

echo "==> aws credentials for the padelytix user"
install -d -o padelytix -g padelytix -m 0700 /var/lib/padelytix/.aws
if [[ ! -f /var/lib/padelytix/.aws/credentials ]]; then
    cat > /var/lib/padelytix/.aws/credentials <<'EOF'
[default]
aws_access_key_id = REPLACE_ME
aws_secret_access_key = REPLACE_ME
EOF
    cat > /var/lib/padelytix/.aws/config <<'EOF'
[default]
region = ap-southeast-1
EOF
    chown -R padelytix:padelytix /var/lib/padelytix/.aws
    chmod 0600 /var/lib/padelytix/.aws/credentials
    echo "    wrote /var/lib/padelytix/.aws/credentials  <-- EDIT THIS"
fi

echo "==> a laptop must not sleep, and must not care about its lid"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/padelytix.conf <<'EOF'
# The lid will be shut. The box keeps recording.
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
systemctl restart systemd-logind

echo "==> units"
install -m 0644 "$HERE"/systemd/*.service "$HERE"/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now padelytix-session.timer padelytix-session-stop.timer padelytix-sync.timer

cat <<'EOF'

==> provisioned.

Three things left, and each is a one line proof. Do them before you leave.

  1. Cameras. Edit /etc/padelytix/cameras.env with the real RTSP URLs, then:
       ffprobe "rtsp://viewer:PASS@<ip>:554/unicast/c1/s0/live"
     A stream description means the box can see the camera. An error means it
     cannot, and nothing below matters yet.

  2. AWS. Edit /var/lib/padelytix/.aws/credentials, then:
       sudo -u padelytix aws s3 cp /etc/hostname s3://padelytix-training-<account-id>/_test.txt
     That proves the outbound path works from behind the court's router.

  3. Remote access, so you never have to drive back:
       curl -fsSL https://tailscale.com/install.sh | sh
       sudo tailscale up --ssh
     Then SSH to it from home. TEST THIS WHILE YOU ARE STILL AT THE COURT.

Then dry run tonight's session without waiting for 19:00:

    sudo systemctl start padelytix-session
    ls -la /var/lib/padelytix/footage/*/     # segments appearing?
    sudo systemctl start padelytix-sync      # do booked ones reach S3?
    sudo systemctl stop padelytix-session

Watch it live:
    journalctl -fu 'padelytix-*'
EOF
