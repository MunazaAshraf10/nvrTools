# nvrTools

The court box. A machine at the venue, on the same LAN as the NVR, that records every
night from 19:00 to 00:00 and drains the footage to S3.

It exists to build a **training set**. It is not the production recorder, and it shares
no code with the Padelytix app: no database, no credentials, no identity, nothing but
the name of an S3 bucket. That is why it is its own repository.

## The distinction that matters

The product never stores footage until somebody pays, and then stores only JPEG frames
of one paid window, which it deletes 48 hours after the report.

This box is the opposite. It keeps **whole video, forever**, because a model has to be
trained on something before any of that can work.

So it writes to its own bucket, `padelytix-training`, which has **no lifecycle rule**.
Do not point it at the app's media bucket: that bucket deletes its contents after 48
hours and would quietly eat the dataset.

## Why nothing needs to reach into the court

Every connection is outbound. The box dials S3, the box dials Tailscale. Nothing
outside ever opens a connection to the venue, which is why no port forwarding, no
static IP and no VPN into the court is needed, and why "I cannot reach the NVR from
outside" was never actually a problem.

```
  [cameras] --> [NVR] --+
                        +-- court LAN, private
             [court box]-+
                   |
                   +--> outbound HTTPS 443 --> S3
```

The box reaches the cameras because it is *on the LAN*. It reaches S3 because outbound
443 works from behind any router. The two facts are independent, and neither requires
the court to be reachable from anywhere.

## What it does

`ffmpeg -c copy` pulls each camera's main stream and writes 10 minute MP4 segments to
local disk. Copy, not re-encode: the camera has already produced H.264/H.265, so the
box only moves those bytes. It costs near zero CPU, which is why a used office laptop
is enough hardware, and it means the training footage is exactly what the sensor
produced rather than a generation-loss copy of it.

Every 5 minutes, `upload.sh` pushes any segment older than 11 minutes to S3 and deletes
it locally. Two details carry the whole offline story:

- **Older than 11 minutes.** Segments rotate every 10, so an 11 minute old file is one
  ffmpeg has closed and will never write to again. Upload a file that is still being
  written and you get a truncated MP4.
- **Delete only on success.** If the link is down the upload fails, the file stays on
  disk, and the next run retries it. There is no queue to build. There is a disk and
  an `&&`.

If a camera drops mid match, systemd restarts that stream within 5 seconds. One blip at
19:20 does not cost the night.

## Install

On a fresh Ubuntu Server 24.04 box at the court:

```bash
git clone https://github.com/MunazaAshraf10/nvrTools.git
cd nvrTools
sudo ./provision.sh
```

That installs ffmpeg and the AWS CLI, creates a `padelytix` service user, installs the
systemd units, and disables sleep and lid-close, which is the thing that otherwise
quietly kills a laptop-as-server at 19:05 every night.

Then the three proofs the script prints. **Do all three before leaving the court**,
especially Tailscale: if you cannot SSH in from home, every future fix is a drive.

```bash
ffprobe "rtsp://viewer:PASS@<ip>:554/unicast/c1/s0/live"                      # box sees the camera
sudo -u padelytix aws s3 cp /etc/hostname s3://padelytix-training/_test.txt   # box reaches S3
sudo tailscale up --ssh                                                       # you reach the box
```

## AWS setup, once

From any machine with admin credentials, not from the court box:

```bash
./aws-setup.sh
```

It creates the bucket (private, encrypted, and with **no lifecycle rule**, because this
is the one bucket that keeps things) and an IAM user whose only power is `s3:PutObject`
on it. Then it prints an access key, once, which goes on the court box and nowhere
else.

The key cannot read the bucket, cannot delete from it, and cannot see any other bucket.
See [iam-policy.json](iam-policy.json). That box sits in a public sports venue where
anybody could walk off with it, so its key should not be able to empty a bucket.

## Layout

| | |
|---|---|
| `/etc/padelytix/cameras.env` | the camera list and the bucket. The only file you edit. |
| `/opt/padelytix/*.sh` | record, upload, session |
| `/var/lib/padelytix/footage/<cam>/` | segments in flight, deleted once in S3 |
| `s3://padelytix-training/<cam>/<date>/` | where they land |

## Adding a camera

One line in `/etc/padelytix/cameras.env`, then `systemctl restart padelytix-session`.
The units read the camera list from that file, so there is nothing to keep in sync.

Always the **main stream** (`s0`), never the sub stream. The sub stream is a low
resolution preview and is worthless as training data.

## Changing the window

19:00 and 00:00 live in `padelytix-session.timer` and `padelytix-session-stop.timer`.
Edit, then `systemctl daemon-reload`.

## When something is wrong

```bash
journalctl -fu 'padelytix-*'            # everything, live
systemctl status padelytix-record@court1_left
ls -la /var/lib/padelytix/footage/*/    # piling up means uploads are failing
```

A growing footage directory is the signal that matters: recording works, the S3 path
does not. The footage is safe on disk meanwhile, which is the point of the design.

## Sizing and cost

Two cameras, five hours a night, H.265 at roughly 5 Mbps is about **22 GB a night**,
near 650 GB a month, roughly **$15/month** in S3 Singapore for the first month and less
as Intelligent Tiering ages it down. Upload needs about 10 Mbps sustained.

Uploads drain the disk continuously, so local storage only has to cover a backlog:
256 GB holds about ten nights with the internet down.

## The hardware

Anything x86 and always-on. The job is I/O, not compute: two RTSP streams copied to
disk is around 10 Mbps in and 10 Mbps out, and `-c copy` barely touches the CPU.

- **Pilot:** an old laptop. It has a screen, a keyboard and a battery, which is a UPS.
  Perfect for proving the pipeline in a week. Not right for a year: the battery degrades
  held at 100%, and consumer thermals are not built for 24/7.
- **Permanent:** a used Dell OptiPlex Micro or Lenovo ThinkCentre Tiny, PKR 20,000 to
  35,000, plus a UPS.
- **A Raspberry Pi works too**, but it needs a real SSD. Never write continuous video to
  a microSD card: it wears out and corrupts, and you will not notice when it started.
  Once you add the PSU, case and NVMe HAT it costs about the same as a used x86 box that
  is strictly better.

**The scripts do not change between any of them.** That is the point of them, and it is
why the hardware choice is not worth agonising over.

## Check the camera fps before collecting a few hundred GB

Most UNV cameras are 30fps. Padel is fast, and if the model later turns out to need
60fps for ball tracking, every frame collected until then is training data at the wrong
rate. Worth pinning down on day one, not month three.
