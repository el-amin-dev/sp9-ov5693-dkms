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
git clone https://github.com/el-amin-dev/sp9-ov5693-dkms
cd sp9-ov5693-dkms
./install.sh
```

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

See [`docs/RUNBOOK.md`](docs/RUNBOOK.md) for setup, run, and test commands.

## Documentation

- [`docs/RUNBOOK.md`](docs/RUNBOOK.md) — how to run, test, and debug the project
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — architecture decision records

## Credit

Root cause and the `0x4800 = 0x2d` value come from
[linux-surface discussion #2198](https://github.com/linux-surface/linux-surface/discussions/2198).
The driver itself is GPL-2.0, © 2013 Intel Corporation and the authors named in its header.
