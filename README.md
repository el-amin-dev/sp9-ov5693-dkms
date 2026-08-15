# sp9-ov5693-dkms

> Patched OV5693 camera sensor driver, packaged for DKMS — fixes the front camera on
> Microsoft Surface devices that pair an OV5693 with an Intel IPU6.

## The problem

The sensor probes and binds, `cam -l` lists the camera, and then every capture hangs
forever with:

```
intel_ipu6_isys.isys intel_ipu6.isys.40: stream stop time out
intel_ipu6_isys.isys intel_ipu6.isys.40: stream close time out
```

The stock driver's stream-enable path writes only `SW_STREAM (0x0100)`; it never
programs `MIPI_CTRL00 (0x4800)`. The IPU6 CSI-2 receiver never locks its D-PHY, so no
frame ever arrives.

## The fix

Write `MIPI_CTRL00 = 0x2d` immediately before stream-on. Two patches on top of upstream
v6.19 `drivers/media/i2c/ov5693.c`:

| Patch | What |
|---|---|
| `patches/0001-add-OVTI5693-acpi-hid.patch` | the `OVTI5693` ACPI HID Surface firmware uses (carried from linux-surface, so the DKMS module binds like the stock one) |
| `patches/0002-write-mipi-ctrl00-on-stream-enable.patch` | the `0x4800` write, exposed as the `mipi_ctrl00` module parameter |

## Status

- created: 2026-08-15
- developed and verified on: Surface Pro 9, Ubuntu 26.04, kernel 6.19.8-surface-3
- applies to: any Surface with an OV5693 + IPU6; nothing here is model-specific

## Getting started

```bash
mkdir -p ~/projects && cd ~/projects
git clone https://github.com/el-amin-dev/sp9-ov5693-dkms
cd sp9-ov5693-dkms
./install.sh
```

Keep the clone somewhere permanent — `~/projects` is the convention used here. The
`camera-bridge@.service` unit points at wherever you cloned it, so moving or deleting
the directory afterwards stops the cameras. If you do move it, re-run `./install.sh`
to rewrite the unit's path.

That is the whole thing. Run it as your **normal user** — it calls `sudo` itself for
the steps that need root, and refuses to run as root because the services and the
PipeWire session belong to your login user.

```bash
./install.sh --check   # report state, change nothing
./uninstall.sh         # undo it
./uninstall.sh --all   # also remove the patched module and the packages it added
```

Afterwards every app — Chrome, Firefox, Zoom, Teams, GNOME Snapshot — sees two
ordinary webcams, **Surface Front Camera** and **Surface Back Camera**, with no
browser flags to set. Verify at <https://webcamtests.com>.

### What it installs

Packages, via apt (the installer aborts if apt would *remove* anything):

| Package | Why |
|---|---|
| `dkms`, `build-essential`, `linux-headers-$(uname -r)` | build the two out-of-tree modules |
| `v4l2loopback-dkms`, `v4l2loopback-utils` | the virtual webcam devices |
| `gstreamer1.0-tools`, `-plugins-base`, `-plugins-good`, `-pipewire` | `pipewiresrc`, `videoconvert`/`videoscale`, `v4l2sink` |
| `v4l-utils` | `v4l2-ctl`, to find and inspect the devices |
| `pipewire-bin` | `pw-dump`, to locate the camera nodes |
| `libcamera-tools` | `cam`, used by the test scripts |
| `python3` | the `surfacecam` package — the bridge itself, and the camera facts `install.sh` reads back from it |

Outside the repo it creates only these, all removed by `./uninstall.sh`:

- `~/.config/systemd/user/camera-bridge@.service` — one instance per camera, started at login
- `/etc/modprobe.d/v4l2loopback-surface.conf` and `/etc/modules-load.d/v4l2loopback-surface.conf`

It never touches `/boot`, the bootloader, or any kernel package, and never needs a reboot.

### Requirements

- a Surface with an OV5693 front camera behind an Intel IPU6 (developed on the Pro 9)
- a kernel with the linux-surface camera patches (`linux-surface` 6.19 or newer)
- Secure Boot **off**, or the DKMS modules signed with an enrolled MOK key

Just the kernel module, without the userspace plumbing:

```bash
sudo ./scripts/install-and-test.sh   # build, install, load, verify — rolls back on failure
sudo ./scripts/uninstall.sh          # back to the stock in-tree module
```

## Why the kernel fix alone is not enough

Patching the driver makes the sensor produce frames, but nothing else can use them:

- the sensor is only reachable through libcamera's **software ISP**, published by
  PipeWire — browsers enumerate `/dev/video*` instead and find only the ~30 IPU6 ISYS
  nodes, which advertise **zero pixel formats**. Chrome reports `NotFoundError`;
  Firefox lists dozens of blank `ipu6` entries.
- Chrome *can* use PipeWire cameras via `chrome://flags/#enable-webrtc-pipewire-camera`,
  and then finds the camera — but on GNOME the xdg portal refuses every request:
  `Only the focused app is allowed to show a system access dialog`. Chrome asks from a
  **windowless utility process**, so the permission dialog can never be shown.
- below roughly **1296px wide** this sensor's software ISP returns all-zero (black)
  buffers, and browsers default to 640x480.

So `install.sh` republishes the working stream through `v4l2loopback` as an ordinary
webcam, captured at 1920x1080 and offered as a single 1280x720 YUY2 mode. Full
reasoning and measurements are in [`docs/RUNBOOK.md`](docs/RUNBOOK.md).

## The bridge

The republishing is done by `surfacecam/`, a Python package that needs nothing beyond
the standard library and the PyGObject GStreamer bindings (`python3-gi`,
`gir1.2-gstreamer-1.0` — already present on an Ubuntu desktop). One user service per
camera runs `python3 -m surfacecam.cli run <front|back>`.

| Module | Responsibility |
|---|---|
| `surfacecam/config.py` | single source of truth: the camera list, card labels, `/dev/video` numbers, capture and output resolutions, thresholds |
| `surfacecam/pipewire.py` | finds a camera's PipeWire node — pure functions over `pw-dump` JSON |
| `surfacecam/loopback.py` | the loopback device: state and format from sysfs, consumers from `fuser` |
| `surfacecam/pipeline.py` | builds the GStreamer pipeline and moves it between states |
| `surfacecam/supervisor.py` | runs one camera's bridge; also holds the on-demand policy, which is disabled by default (see below) |
| `surfacecam/cli.py` | entry point: `run <front\|back>` and `status` |

`config.py` is also a CLI, so the shell scripts ask it rather than keeping a second
copy of the same facts:

```bash
python3 -m surfacecam.config keys              # front back
python3 -m surfacecam.config labels            # the card names apps display
python3 -m surfacecam.config devices           # /dev/video42, /dev/video43
python3 -m surfacecam.config services          # camera-bridge@front camera-bridge@back
python3 -m surfacecam.config modprobe-options  # the v4l2loopback arguments
```

### The camera streams continuously, and the privacy LED stays on

As shipped, the bridge holds the sensor open for as long as the service runs. The
privacy LED is therefore lit whenever the service is up, whether or not any app is
using the camera. That is worth knowing before you install this: an indicator that is
always on tells you nothing about whether you are being recorded.

On-demand streaming — parking the pipeline in `PAUSED` while no process has the
loopback open, so the sensor powers down and the LED goes out — is implemented in
`surfacecam/supervisor.py` but **disabled**, behind `ON_DEMAND` in
`surfacecam/config.py`. It is off because it does not work: the supervisor correctly
notices a consumer and returns the pipeline to `PLAYING`, and the journal duly logs
`camera on (1 consumer(s))`, but the consumer then receives no frames at all — a 40s
`ffmpeg` capture produced zero images and no error message. `v4l2sink` and
`v4l2loopback` evidently do not resume cleanly from `PAUSED` once a consumer has
already opened the device. Trading a working camera for a truthful LED is the wrong
trade, so it ships off; the code stays because the goal is still right.

Stopping the producer outright when idle is the obvious alternative, and it is not
available: v4l2loopback 0.15.3 has no `keep_format` parameter (`modinfo v4l2loopback`
lists only `debug`, `max_buffers`, `max_openers`, `devices`, `video_nr`, `card_label`,
`exclusive_caps`, `max_width`, `max_height`), so a device with no producer reverts to
`state=output` with no format, and apps then stop listing it. Ubuntu resolute/universe
ships no newer version. [`docs/RUNBOOK.md`](docs/RUNBOOK.md) has the commands to
inspect this on your own machine.

## Tests

Unit tests, standard library only — no pytest, no camera, no root:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

39 tests over camera identification against a recorded `pw-dump` (including a
regression test for the back camera vanishing when libcamera reported no
`api.libcamera.location`), the WirePlumber nudge guards, the pipeline description,
and the on-demand policy — which is tested but not enabled, see above.

The hardware tests — capture, rollback, and the browser probe — need the camera and,
for `dmesg`, root. See [`docs/RUNBOOK.md`](docs/RUNBOOK.md) for those and for the rest
of the setup, run, and debug commands.

## Documentation

- [`docs/RUNBOOK.md`](docs/RUNBOOK.md) — how to run, test, and debug the project
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — architecture decision records

## Credit

Root cause and the `0x4800 = 0x2d` value come from
[linux-surface discussion #2198](https://github.com/linux-surface/linux-surface/discussions/2198).
The driver itself is GPL-2.0, © 2013 Intel Corporation and the authors named in its header.
