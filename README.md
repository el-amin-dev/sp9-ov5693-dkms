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
./install.sh              # everything: kernel module, loopback device, bridge service
./install.sh --check      # report state, change nothing
./install.sh --uninstall  # undo it
```

Run it as your normal user — it calls `sudo` only for the steps that need it. Afterwards
every app (Chrome, Firefox, Zoom, Teams, GNOME Snapshot) sees one camera named
**Surface Front Camera**, with no browser flags to set.

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
