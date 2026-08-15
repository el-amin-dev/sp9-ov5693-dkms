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

What the install touches outside this repo: `/usr/src/ov5693-surface-1.0.0`,
DKMS's own state under `/var/lib/dkms`, and
`/lib/modules/<kver>/updates/dkms` + `modules.dep` (unavoidable for any DKMS
package). Nothing in `/boot`, no bootloader config, no package manager, no reboot.

On Ubuntu, DKMS also generates a MOK signing keypair under
`/var/lib/shim-signed/mok/` if one does not exist yet, and signs the module with
it. That is stock DKMS behaviour: the key is **not** enrolled (enrolling needs
`mokutil --import` plus a reboot), and with Secure Boot off the signature is
simply ignored.

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
software ISP is reported to hand back empty (all-zero) buffers for narrow streams, so
a black 1280x720 frame is a libcamera limitation, not a driver fault.

Observed here, though: capturing the **rear** camera (unaffected by this bug) at
1280x720 returned 100% non-zero bytes, i.e. the narrow-width limitation did not
reproduce on this setup. The threshold is kept as a non-fatal caveat rather than an
assertion, so a black narrow frame is reported but never fails the run.

Manual equivalent:

```bash
timeout 30 cam -c 1 -C5 -s width=1920,height=1080 --file=/tmp/frame-#.raw
sudo dmesg | grep -E 'stream (stop|close) time out'   # expect no output
```

## Making the camera usable in browsers and apps

The kernel fix alone does not give you a webcam. The sensor reaches userspace only
through libcamera's software ISP, which PipeWire publishes as a `Video/Source`.
Ordinary apps do not see that, so a bridge republishes it as a normal V4L2 device.

```bash
./install.sh          # does all of it: packages, module, devices, services
./install.sh --check  # report state only
./uninstall.sh        # undo
```

Manually, if you prefer the steps:

```bash
sudo apt-get install -y v4l2loopback-dkms v4l2loopback-utils v4l-utils \
    gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-pipewire pipewire-bin libcamera-tools
sudo ./scripts/camera-bridge-setup.sh --persist   # /dev/video42 + /dev/video43

mkdir -p ~/.config/systemd/user
sed "s|%REPO%|$PWD|" "scripts/camera-bridge@.service" > ~/.config/systemd/user/camera-bridge@.service
systemctl --user daemon-reload
systemctl --user enable --now camera-bridge@front camera-bridge@back
```

Check it:

```bash
./scripts/camera-bridge.sh status
systemctl --user status camera-bridge@front
v4l2-ctl -d /dev/video42 --list-formats-ext      # expect one: YUYV 1280x720 @30fps
```

After this, Chrome, Firefox, Zoom, Teams and GNOME Snapshot see two cameras,
**Surface Front Camera** and **Surface Back Camera**. No browser flags, no
`chrome://flags`, no portal.

### Picture is upside down

Each camera is rotated in the bridge, not by libcamera. The values are measured
rather than read from `api.libcamera.rotation`, because that property does not
describe what leaves the pipeline: the front sensor reports `180` and libcamera
already compensates, so its frames are upright, while the back sensor reports `0`
yet is physically mounted upside down and nothing corrects it.

Defaults are front `0`, back `180`. Override per machine:

```bash
systemctl --user edit camera-bridge@back
# [Service]
# Environment=BACK_ROTATION=0
systemctl --user restart camera-bridge@back
```

Accepted values are `0`, `90`, `180`, `270`. Check what is in effect with:

```bash
journalctl --user -u camera-bridge@back -n 20 | grep rotate
```

### Cameras gone after a reboot

Symptom: everything worked, you reboot, and the browser shows no camera. Check:

```bash
systemctl --user status camera-bridge@front
pw-dump | grep -c libcamera        # 0 means WirePlumber has no camera nodes
cam -l                             # but libcamera itself still sees them
```

Cause: WirePlumber enumerates libcamera **once**, at startup. At boot it can run
before the IPU6 and sensor drivers are ready, find no cameras, and never look again,
so the PipeWire nodes never appear. The bridge then has nothing to read from.

The bridge handles this itself now: it waits up to 120s for its node, and if
libcamera can see the camera while PipeWire cannot, it restarts WirePlumber once.
The unit also sets `Restart=always` with `StartLimitIntervalSec=0`, because the
default start limit put it permanently in `failed` after a few quick retries -- which
is what left the camera dead until the service was restarted by hand.

To fix it manually:

```bash
systemctl --user restart wireplumber
systemctl --user restart camera-bridge@front camera-bridge@back
```

### "Device is not a output device"

`exclusive_caps=1` means a loopback flips to capture-only once a consumer opens it,
after which the feeder can no longer attach. If a bridge fails with this, something
else grabbed the device first -- usually a browser tab left open, or an orphaned
`gst-launch` from a previous run:

```bash
for p in /proc/[0-9]*; do ls -l $p/fd 2>/dev/null | grep -q video42 && \
  echo "$p $(cat $p/comm)"; done
```

Close the consumer, then `systemctl --user restart camera-bridge@front`.

### Why a loopback rather than the PipeWire path

Chrome can talk to PipeWire cameras via `chrome://flags/#enable-webrtc-pipewire-camera`,
and that flag does work — Chrome finds the camera. But every access then goes through
the xdg camera portal, and on GNOME it is refused:

```
xdg-desktop-portal-gnome: Failed to associate portal window with parent window
xdg-desktop-portal: AccessDenied: Only the focused app is allowed to show a system access dialog
webrtc/.../camera_portal.cc: Camera access denied by the XDG portal.
```

Chrome requests the camera from its **video-capture utility process**, which owns no
window. GNOME only shows the permission dialog for the focused window, so the dialog
can never appear and the request is denied. Clicking, focusing, or running Chrome
under native Wayland does not change it. The loopback sidesteps the portal entirely.

The other route would be to pre-authorise the portal:

```bash
gdbus call --session --dest org.freedesktop.impl.portal.PermissionStore \
  --object-path /org/freedesktop/impl/portal/PermissionStore \
  --method org.freedesktop.impl.portal.PermissionStore.SetPermission \
  "devices" true "camera" "" "['yes']"
```

That was not used here: it only helps portal-aware apps, whereas the loopback works
for everything.

### The resolution trap

Measured on this sensor through PipeWire:

| Requested | Result |
|---|---|
| 640x480 | **all-zero (black)** |
| 1280x720 | **all-zero (black)** |
| 1920x1080 | real picture, mean ≈ 147 |
| 2592x1944 | no frames within 60s |

Anything under ~1296px wide comes back black from the software ISP. Browsers default
to 640x480, so a direct connection looks black even when everything is wired
correctly. The bridge therefore **captures at 1920x1080 always** and downscales to a
single advertised 1280x720 YUY2 mode, so clients get a real picture whatever they ask
for. Do not "simplify" the bridge by capturing at the output size.

### Undoing all of it

```bash
systemctl --user disable --now camera-bridge@front camera-bridge@back
rm ~/.config/systemd/user/camera-bridge@.service && systemctl --user daemon-reload
sudo ./scripts/camera-bridge-setup.sh --undo      # unload module, remove /etc files
sudo apt-get remove v4l2loopback-dkms v4l2loopback-utils   # optional
```

Files created outside this repo: `~/.config/systemd/user/camera-bridge.service`,
`/etc/modprobe.d/v4l2loopback-surface.conf`, `/etc/modules-load.d/v4l2loopback-surface.conf`.

### Testing the browser end

```bash
./tests/browser-camera-test.sh                 # Chrome, PipeWire backend (will fail: portal)
./tests/browser-camera-test.sh --no-pipewire   # Chrome via the loopback (expect PASS)
./tests/browser-camera-test.sh --headful       # visible window
```

The probe saves the frame the browser itself captured to `out/chrome-capture.jpg` and
its verdict to `out/browser-result.json`. Headless runs are unreliable for this —
Chrome throttles timers in hidden pages and reuses an already-running instance for the
same `--user-data-dir`, so use a fresh profile directory when a run seems to ignore
page changes.

## Source provenance

`src/ov5693.c` is the upstream `drivers/media/i2c/ov5693.c` named in
`patches/upstream.pin` (currently **v6.19**) plus the two patches in `patches/`. The
tag and sha256 live only in that pin file — never duplicated in a code comment — and
`--rebase` rewrites it, so the pin cannot end up claiming a provenance `src/` does not
have. The claim is machine-checkable:

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

Valid values are `0`–`255` (the register is 8-bit) or `-1` to skip the write.
Anything else is rejected with `EINVAL`/`ERANGE` at load or sysfs-write time rather
than being truncated, so a sweep cannot silently retest a value it already tried.

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
