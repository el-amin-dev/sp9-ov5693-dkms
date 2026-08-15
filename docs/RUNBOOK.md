# Runbook — sp9-ov5693-dkms

> Commands only. Not rationale. Not architecture.
> Every command here MUST work as-typed on a fresh clone.
> If behavior changes → this file changes in the SAME PR.

Patched OV5693 sensor driver for Microsoft Surface devices whose front camera is an
OmniVision OV5693 behind an Intel IPU6. Developed on a Surface Pro 9; nothing in the
driver or the scripts is model-specific.

## Setup

Requirements: `dkms`, `build-essential`, kernel headers for the running kernel,
`libcamera-tools` (for `cam`). Secure Boot must be off **or** the DKMS module must be
signed with an enrolled MOK key — the installer refuses to continue if signature
enforcement is on.

```bash
# one command: stage, build, install, load, verify (rolls back on any failure)
sudo ./scripts/install-and-test.sh
```

Roll back completely at any time:

```bash
sudo ./scripts/uninstall.sh
```

The stock in-tree `ov5693.ko` is never modified or deleted. DKMS installs to
`/lib/modules/<kver>/updates/dkms/`, which `modprobe` searches before
`kernel/drivers/`, so uninstalling is only ever "stop shadowing it".

## Run

Nothing to run — this is a kernel module. It loads on boot once installed, and DKMS
rebuilds it for every new kernel (`AUTOINSTALL="yes"`).

```bash
# which ov5693.ko is in effect (expect .../updates/dkms/ov5693.ko* when installed)
modinfo -F filename ov5693

# current MIPI_CTRL00 value (45 == 0x2d)
cat /sys/module/ov5693/parameters/mipi_ctrl00

# reload the module
sudo modprobe -r ov5693 && sudo modprobe ov5693
```

## Test

```bash
# full acceptance test (needs root: dmesg is restricted)
sudo ./tests/test-capture.sh

# one resolution, longer timeout
sudo RESOLUTIONS=1920x1080 CAPTURE_TIMEOUT=60 ./tests/test-capture.sh

# keep the frames somewhere you can look at them
sudo OUTDIR=/tmp/ov5693 ./tests/test-capture.sh
```

Env knobs: `OV5693_CAM` (camera index or id substring), `RESOLUTIONS`, `FRAMES`,
`CAPTURE_TIMEOUT`, `OUTDIR`.

What it asserts, per resolution:

1. `cam` exits 0 within the timeout — the bug being fixed is an infinite hang.
2. No new `stream (stop|close) time out` line in `dmesg`.
3. At ≥1296 px wide only: the frame is >1% non-zero bytes.

Widths below 1296 px are captured and measured but not content-asserted: libcamera's
software ISP hands back empty (all-zero) buffers for narrow streams, so a black
1280x720 frame is a libcamera limitation, not a driver fault.

Manual equivalent:

```bash
timeout 30 cam -c 1 -C5 -s width=1920,height=1080 --file=/tmp/frame-#.raw
sudo dmesg | grep -E 'stream (stop|close) time out'   # expect no output
```

## Source provenance

`src/ov5693.c` is upstream Linux **v6.19** `drivers/media/i2c/ov5693.c` plus the two
patches in `patches/`. That claim is machine-checkable:

```bash
./scripts/fetch-upstream.sh            # re-download, reapply, diff against src/
./scripts/fetch-upstream.sh --rebase   # regenerate src/ov5693.c from upstream+patches
UPSTREAM_TAG=v6.20 ./scripts/fetch-upstream.sh --rebase   # move to a newer kernel
```

## Lint / Format

```bash
shellcheck -S warning scripts/*.sh tests/*.sh
bash -n scripts/*.sh tests/*.sh
```

## Smoke checks

```bash
dkms status -m ov5693-surface                 # expect: ..., <kver>, x86_64: installed
modinfo -F filename ov5693 | grep updates/dkms
cat /sys/module/ov5693/parameters/mipi_ctrl00 # expect: 45
ls /sys/bus/i2c/drivers/ov5693/               # expect an i2c-OVTI5693:00 style entry
cam -l                                        # expect the front camera listed
```

## Troubleshooting

**`cam` still hangs / `stream stop time out` persists.** The 0x2d value is documented
in prose only (linux-surface discussion #2198 ships no diff) and 0x20 is mentioned
there as another value tried. Sweep candidates without rebuilding — the register value
is a live module parameter:

```bash
for v in 0x2d 0x20 0x24 0x04 0x14; do
  sudo modprobe -r ov5693 && sudo modprobe ov5693 mipi_ctrl00=$v
  echo "== $v"; sudo RESOLUTIONS=1920x1080 ./tests/test-capture.sh | tail -3
done
```

Make the winner permanent in `/etc/modprobe.d/ov5693.conf`
(`options ov5693 mipi_ctrl00=0x20`), then change the default in `src/ov5693.c` and
re-run the installer.

**Confirm the fix is what's doing the work.** `-1` skips the register write and
restores stock behaviour without uninstalling — the capture should hang again:

```bash
sudo modprobe -r ov5693 && sudo modprobe ov5693 mipi_ctrl00=-1
sudo RESOLUTIONS=1920x1080 CAPTURE_TIMEOUT=20 ./tests/test-capture.sh   # expect FAIL
sudo modprobe -r ov5693 && sudo modprobe ov5693                          # back to 0x2d
```

**Build fails.** Read `/var/lib/dkms/ov5693-surface/1.0.0/build/make.log`.
`warning: the compiler differs from the one used to build the kernel` is expected on
Ubuntu (kernel built with gcc 11, userland ships gcc 15) and is harmless — the module
links and its vermagic matches. Only a hard error matters.

**Module refuses to load, `Key was rejected by service`.** Signature enforcement is on.
Either disable Secure Boot or sign the module with an enrolled MOK key. Check with
`mokutil --sb-state` and `cat /sys/module/module/parameters/sig_enforce`.

**Camera stops binding entirely after install.** That means the `OVTI5693` ACPI HID
was lost — `modinfo ov5693 | grep OVTI5693` must show the alias. Roll back with
`sudo ./scripts/uninstall.sh` and re-check `patches/0001-add-OVTI5693-acpi-hid.patch`.

**`dmesg` prints nothing as a normal user.** `kernel.dmesg_restrict=1` on Ubuntu; use
`sudo dmesg`. The test script warns when it is run unprivileged because timeout
detection goes blind.

**Wrong camera picked by the test.** `cam -l`, then
`sudo OV5693_CAM=<index> ./tests/test-capture.sh`.
