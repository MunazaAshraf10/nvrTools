# nvrTools

The court box: a small always-on machine at the venue, on the same LAN as the NVR. It
records every camera around the clock, asks the Padelytix app which windows are booked,
uploads only that footage to S3, and deletes the rest.

It shares no code with the app. All it knows is a bucket name, a venue id and one shared
secret. Every connection is outbound, so the court needs no port forwarding, static IP
or inbound VPN.

## How it works

- `record.sh` runs `ffmpeg -c copy` per camera and writes 10 minute MKV segments to
  `/var/lib/padelytix/footage/<cam>/`. Copy, not re-encode: near zero CPU, and the
  footage is exactly what the sensor produced.
- `sync.sh` runs on a timer. It fetches the booking plan from the app, uploads closed
  segments that fall inside a booked window to `s3://<bucket>/<cam>/<date>/`, and
  deletes everything else once it is old enough that a late extension cannot claim it.
  If the app or S3 is unreachable nothing is deleted; the disk is the retry queue.
- `session.sh` starts or stops one `padelytix-record@<cam>` unit per line in
  `cameras.env`.

## Install

On a fresh Ubuntu Server 24.04 box at the court:

```bash
git clone https://github.com/MunazaAshraf10/nvrTools.git
cd nvrTools
sudo ./provision.sh
```

Then fill in `/etc/padelytix/cameras.env` (see [cameras.env.example](cameras.env.example))
and `/var/lib/padelytix/.aws/credentials`, and run the three proofs the script prints:
the box sees a camera, the box reaches S3, you can SSH in over Tailscale.

[RUNBOOK.md](RUNBOOK.md) is the step-by-step for the day at the court, including the
camera settings that matter (fast shutter, smart codec off, main stream only).

## AWS, once

From a machine with admin credentials, not the court box:

```bash
./aws-setup.sh
```

It creates a private, encrypted bucket with no lifecycle rule and an IAM user whose only
permission is `s3:PutObject` on it ([iam-policy.json](iam-policy.json)). The box sits in
a public venue, so its key cannot read, list or delete anything.

## When something is wrong

```bash
journalctl -fu 'padelytix-*'
systemctl status 'padelytix-record@*'
ls -la /var/lib/padelytix/footage/*/   # piling up means uploads are failing
```
