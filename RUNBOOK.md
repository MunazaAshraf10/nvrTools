# At the court

The order matters. Each step proves the one before it, so if a step fails you know
exactly what broke, rather than staring at an empty bucket a week later wondering which
of six things went wrong.

Budget two hours the first time.

## Take with you

- The box (laptop), its charger, and an **ethernet cable**
- A **USB to ethernet adapter** if the laptop has no ethernet port
- Your phone or a second laptop, **on the court WiFi**. You need a browser to reach the
  NVR's web interface, and Ubuntu Server does not have one.
- The NVR's admin password

## Before you leave home

Mint the box's AWS key. It can only add footage to the training bucket, nothing else.

```bash
aws iam create-access-key --user-name padelytix-court-box
```

Write both values down. AWS shows the secret once, and never again.

---

## 1. Get on the LAN

Plug the box into the **same switch or router as the NVR**, by cable. Not WiFi. Then:

```bash
ip -4 addr show          # what is my address, and therefore my subnet
```

Note the subnet, e.g. `<your-subnet>.x`.

## 2. Find the NVR

```bash
sudo apt install -y nmap
nmap -sn <your-subnet>/24  # substitute your subnet
```

The NVR is one of the addresses that comes back. If the cameras are on their own PoE
switch rather than plugged into the NVR, they will show up here too, as separate
addresses. If only the NVR appears, its PoE ports are hiding the cameras on a private
subnet and you will pull the streams through the NVR instead. Either is fine.

Give the box a **DHCP reservation** on the router, so its address never moves.

## 3. Fix the camera settings

**From your phone or second laptop**, open `http://<nvr-ip>` in a browser and log in.

Do this **before** collecting anything. Footage shot with the defaults is not a smaller
dataset, it is a worse one, and no quantity of it adds up to a good one.

| Setting | Set to |
|---|---|
| **Shutter / max exposure** | **1/500s** (1/250s at the absolute floor) |
| **Smart codec** (U-Code, H.265+) | **OFF** |
| **Bitrate** | CBR, 8 to 10 Mbps |
| **I-frame interval (GOP)** | 30 |
| **OSD / timestamp overlay** | OFF |

The shutter is the one that matters. These matches are at night under floodlights, and
a camera left to itself drags the shutter open to gather light, which turns a struck
ball into a metre-long smear no tracker can find. Freezing it costs brightness and buys
noise. Take that trade every time: a model can be trained through noise, and cannot be
trained through a ball that is not there.

Smart codec is on by default, looks perfectly fine to a human reviewing an incident,
and throws away exactly the detail a model needs.

While you are in there, **create a viewer user** for the streams rather than handing the
box the admin password.

## 4. Prove the box can see the cameras

```bash
sudo apt install -y ffmpeg

# cameras on their own switch, reachable directly:
ffprobe "rtsp://viewer:PASS@<camera-ip>:554/media/video1"

# cameras behind the NVR's PoE ports, so pull the channel off the NVR:
ffprobe "rtsp://viewer:PASS@<nvr-ip>:554/unicast/c1/s0/live"
```

A stream description (resolution, fps, codec) means it works. **Check the fps and
resolution it reports here**: that is the ground truth about what you are collecting,
not what the web UI claims.

Try `c1` and `c2` for the two cameras. Nothing below matters until this works.

## 5. Provision

```bash
cd ~/nvrTools
sudo ./provision.sh
```

Installs ffmpeg and the AWS CLI, creates the `padelytix` service user, installs the
systemd units, and disables sleep and lid-close. That last one is what stops a laptop
quietly dying at 19:05 every night when the lid goes down.

## 6. Cameras

```bash
sudo nano /etc/padelytix/cameras.env
```

Real RTSP URLs, from step 4, the ones you proved. Main stream only.

```
CAM_court1_left=rtsp://viewer:PASS@<nvr-ip>:554/unicast/c1/s0/live
CAM_court1_right=rtsp://viewer:PASS@<nvr-ip>:554/unicast/c2/s0/live
S3_BUCKET=padelytix-training-<account-id>
```

## 7. AWS credentials

```bash
sudo nano /var/lib/padelytix/.aws/credentials
```

```
[default]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
```

Prove it, **as the padelytix user**, because that is who will actually be doing it:

```bash
sudo -u padelytix aws s3 cp /etc/hostname s3://padelytix-training-<account-id>/_test.txt
```

Success here means the box can reach AWS from behind the court's router, which is the
entire outbound story, tested.

## 8. Prove you can get back in

**Do this before you leave. If you skip one step, do not let it be this one.**

```bash
sudo tailscale up --ssh
```

Then, **from your phone on mobile data, not the court WiFi**, SSH to the box.

Mobile data is the point: it proves you can reach the box from outside the venue. On
the court WiFi you would be proving nothing, because you are already on the LAN.

If this does not work, fix it now. Every future fix is a drive to the court otherwise.

## 9. Dry run, without waiting for 19:00

```bash
sudo systemctl start padelytix-session
sleep 90
ls -la /var/lib/padelytix/footage/*/     # .mp4 files appearing and growing?
```

Wait for a segment to close (they rotate every 10 minutes), then:

```bash
sudo systemctl start padelytix-upload
aws s3 ls s3://padelytix-training-<account-id>/ --recursive
```

Footage in the bucket means the whole chain works. Then stop it:

```bash
sudo systemctl stop padelytix-session
```

## 10. Hand it over to the timers

```bash
systemctl list-timers 'padelytix-*'
```

You should see the session starting at 19:00, stopping at 00:00, and the upload every
5 minutes. Nothing more to do: it runs tonight on its own.

Close the lid. Leave it plugged into power and ethernet. Go home.

---

## That night, from home

```bash
ssh <box>                      # over Tailscale
journalctl -fu 'padelytix-*'   # watch it
aws s3 ls s3://padelytix-training-<account-id>/ --recursive --human-readable | tail
```

## When something is wrong

**Footage piling up on disk** means recording works and uploads do not. Check the AWS
credentials. The footage is safe meanwhile, and will drain by itself once the path is
fixed, which is the whole point of the design.

**No footage at all** means the camera URL is wrong or the camera is unreachable. Go
back to step 4.

```bash
systemctl status padelytix-record@court1_left
journalctl -u padelytix-record@court1_left -n 50
```
