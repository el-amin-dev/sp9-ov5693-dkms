# Architecture Decision Records

> Append-only. One entry per significant decision. Newest on top.
> "Significant" = affects architecture, data model, security posture, or is hard to reverse.

<!--
Entry format (use exactly this shape):

## ADR-NNN — <title> (<date>)
- status: accepted | superseded-by-ADR-NNN
- context: <what forced a decision>
- decision: <what was chosen>
- alternatives: <what was rejected + why>
- consequences: <trade-offs accepted>
-->

<!-- append ADRs below, newest first -->

## ADR-005 — Stream on demand by parking the pipeline in PAUSED (2026-08-15)
- status: accepted, implemented, shipped DISABLED — the mechanism does not work in
  practice (see consequences). The code remains behind `config.ON_DEMAND`, which is
  `False`; the shipped bridge streams continuously and the privacy LED stays lit. The
  context and the `keep_format` finding below still hold and still rule out the
  obvious alternative, so this ADR is kept rather than withdrawn.
- context: the bridge held the sensor open for as long as the service ran, so the
  camera streamed 24/7 whether or not anything was watching. The privacy LED was
  therefore lit permanently — a security problem before it is a battery one, because
  an indicator that is always on carries no information: the user cannot tell an app
  using the camera from the bridge idling. The obvious fix — stop the pipeline while
  nobody is watching — does not work here. v4l2loopback 0.15.3 exposes no
  `keep_format` parameter (`modinfo v4l2loopback` lists `devices`, `video_nr`,
  `card_label`, `exclusive_caps`, `max_*` and nothing else), so a loopback with no
  producer reverts to `state=output` with an empty format, and apps then either skip
  the device or show a blank picture. Verified on this machine.
- decision (as taken; see status and consequences for how it ended up): the pipeline
  stays attached to the loopback for the life of the service
  and is moved between `PLAYING` and `PAUSED` instead of being torn down. `v4l2sink`
  keeps the device claimed with its format set, so it stays `state=capture` and every
  app keeps listing it, while `pipewiresrc` stops pulling and the sensor powers down —
  the PipeWire camera node drops to `suspended` and the LED goes out. The supervisor
  polls `fuser` on the device every 0.5s; any consumer resumes streaming, and the last
  consumer leaving starts a 5s linger before pausing again. The decision itself is a
  pure function, `decide(consumers, mode, idle_for)`, tested independently of the loop
  that feeds it. Measured first with `tests/pause-probe.py` — a throwaway probe that
  asked only "does PAUSED actually stop the sensor while the loopback keeps its
  format?" — before any of this was built on the assumption.
- alternatives: stopping the pipeline when idle — rejected, the loopback loses its
  format and the camera stops being listed, which is worse than an LED that is always
  on; unloading and reloading v4l2loopback per session — rejected, it drops any live
  client and needs root at exactly the wrong moment; leaving it streaming and
  documenting the LED — rejected, that is the security problem, not a workaround for
  it; no linger at all — rejected, apps routinely close and immediately reopen the
  device while negotiating, and pausing in that gap makes the stream visibly flap.
- consequences: **the decision did not survive contact with the hardware, and ships
  off.** Enabling it starves consumers: the supervisor detects a consumer and returns
  the pipeline to `PLAYING`, the journal logs `camera on (1 consumer(s))`, and the
  consumer then receives zero frames — measured with a 40s `ffmpeg` capture that
  produced no images and no error message. The pre-build probe (`tests/pause-probe.py`)
  asked only whether `PAUSED` stops the sensor while the loopback keeps its format; it
  did not ask whether a consumer that opens the device *during* the paused period ever
  gets frames after the resume, and that is the case that fails. `v4l2sink` and
  `v4l2loopback` evidently do not resume cleanly from `PAUSED` once a consumer holds
  the device. Trading a working camera for a truthful LED is the wrong trade, so
  `config.ON_DEMAND` is `False`: the bridge streams continuously, the LED is always on
  and therefore carries no information, and the security problem in the context above
  is unfixed rather than solved. What the work bought regardless: the policy is a
  tested pure function (`decide`), and the `keep_format` finding stands — the obvious
  "stop the producer when idle" design remains impossible on v4l2loopback 0.15.3, and
  Ubuntu resolute/universe ships no newer version. Had it been enabled, the costs would
  have been a ~0.5s poll (about 30ms of `fuser` each time, which is why sysfs and
  `fuser` replaced `v4l2-ctl` and a `/proc/*/fd` walk), up to about a second of latency
  on the first frame, and up to 5s of streaming after the last consumer leaves.
  `surfacecam.cli status` counts the bridge's own producer among a device's `watchers`
  either way, so an idle camera reads `watchers=1` rather than 0. Reviving this needs
  either a resume path `v4l2loopback` tolerates, or a future `keep_format` that makes
  the simpler "stop the producer" design available; until one exists, do not flip the
  flag.

## ADR-004 — Move the bridge into a Python package with a single source of truth (2026-08-15)
- status: accepted
- context: the bridge was a bash script that built its GStreamer pipeline inside a
  heredoc, and the facts about the cameras were copied by hand across the scripts that
  needed them — card labels in four files, the camera list in three, the `/dev/video`
  numbers in two. Neither half could be tested without the hardware: the only way to
  observe a policy decision was to watch an LED. Five bugs reached the user as a
  result — the bridge not surviving a reboot, the back camera upside down, a reboot
  guard that broke the back camera outright, stale camera nodes left by a module
  reload, and the back camera vanishing because it was matched on
  `api.libcamera.location`, which libcamera left empty for that sensor. Every one of
  them is a few lines of recorded JSON or a two-line assertion once the logic is
  callable without a camera.
- decision: `surfacecam/`, a Python package split so that each decision is reachable
  from a test — `config.py` (every camera fact, and the only place any of them is
  written down), `pipewire.py` (pure functions over parsed `pw-dump` output),
  `loopback.py` (device state from sysfs, consumers from `fuser`), `pipeline.py`
  (builds a pipeline description as a string, moves states), `supervisor.py` (the
  on-demand policy), `cli.py` (argument parsing only). `config.py` doubles as a CLI —
  `python3 -m surfacecam.config {keys,labels,devices,services,modprobe-options}` — so
  the shell scripts that remain read the same facts instead of keeping a copy. The
  systemd unit runs `python3 -m surfacecam.cli run %i` with `WorkingDirectory` set to
  the repo. Tests are stdlib `unittest` only, run with
  `python3 -m unittest discover -s tests -p 'test_*.py'`: 26 of them, no pytest, no
  hardware, milliseconds.
- alternatives: keeping bash and adding a bats suite — rejected, the parts that
  actually broke are JSON matching and a state machine, which bash can only express as
  string surgery over `jq` output; a Python package with a `pyproject.toml` and
  dependencies — rejected, this is a system-level tool that must run before anything
  is set up, so the standard library plus the PyGObject GStreamer bindings
  (`python3-gi` and `gir1.2-gstreamer-1.0`, already present on an Ubuntu desktop) is
  the whole dependency budget; a single
  `bridge.py` — rejected, the point is that policy is separable from I/O, and one file
  invites putting the `pw-dump` call back inside the matching code.
- consequences: `python3` joins the package dependency list, and the shell scripts now
  fail loudly if `surfacecam.config` cannot be imported rather than proceeding on a
  stale copy of the camera list. `scripts/camera-bridge.sh` was deleted in the same
  commit and the `uninstall.sh` call to it removed; nothing references it any more, and
  `python3 -m surfacecam.cli status` replaces its `status`. GStreamer is
  imported lazily inside `Pipeline`, so the package stays importable — and testable —
  on a machine with no GObject bindings; the price is that a missing `python3-gi`
  surfaces when the bridge starts rather than at import, on a distro where the desktop
  does not already carry it.

## ADR-003 — Ship the register value as a module parameter, not a constant (2026-08-15)
- status: accepted
- context: the fix is `MIPI_CTRL00 (0x4800) = 0x2d`, but that value is documented in
  prose only — linux-surface discussion #2198 contains no diff, and it names `0x20` as
  another value that was tried. We have no OV5693 datasheet to confirm what the bits
  mean, so the value is empirical.
- decision: `mipi_ctrl00` is an `int` module parameter (mode 0644) defaulting to
  `0x2d`; `-1` skips the write entirely.
- alternatives: a bare `#define` — rejected, every candidate value would cost an
  edit/rebuild/reinstall cycle on hardware that can only be tested interactively.
- consequences: one extra symbol and a writable sysfs knob. In exchange, sweeping
  candidate values is a `modprobe` argument, and `-1` gives a same-module A/B that
  proves the register write is what fixes the hang rather than some side effect of
  reloading the driver.

## ADR-002 — Vendor the whole driver, keep the deltas as patches (2026-08-15)
- status: accepted
- context: DKMS builds a source tree, not a patch. But a 1400-line vendored copy with
  no provenance rots silently against upstream.
- decision: `src/ov5693.c` is the build input; `patches/0001..0002` record the deltas
  against upstream v6.19; `scripts/fetch-upstream.sh` re-downloads the pinned upstream
  file (sha256-verified), reapplies the patches and diffs the result against `src/`.
- alternatives: patching at build time inside `dkms.conf` (`PATCH[0]=`) — rejected,
  it hides the real build input and fails opaquely mid-install; a bare vendored copy
  with no patches — rejected, provenance becomes unverifiable.
- consequences: two representations to keep in sync, at the cost of one command
  (`./scripts/fetch-upstream.sh`) that fails loudly if they drift. Moving to a newer
  kernel is `UPSTREAM_TAG=vX.Y ./scripts/fetch-upstream.sh --rebase`.

## ADR-001 — Shadow the in-tree module via DKMS instead of replacing it (2026-08-15)
- status: accepted
- context: the front camera needs a patched `ov5693.ko`, but the machine must keep a
  working, loadable sensor driver at all times, and kernel upgrades must not silently
  drop the fix.
- decision: a DKMS package (`ov5693-surface`) installing to
  `/lib/modules/<kver>/updates/dkms/`, which `modprobe` searches before
  `kernel/drivers/`. `AUTOINSTALL="yes"` rebuilds it on kernel upgrades.
- alternatives: overwriting the in-tree `.ko` — rejected, no rollback and any kernel
  package update silently reverts it; carrying a full patched kernel tree — rejected,
  disproportionate for a two-hunk change.
- consequences: the stock module stays on disk untouched, so rollback is
  `dkms remove` + `depmod` and nothing else. The vendored source is pinned to the
  v6.19 driver API, so a future kernel that reworks `ov5693.c` (e.g. the
  `s_stream` → `enable_streams` conversion) will need a rebase, not just a rebuild —
  DKMS will report a build failure rather than fail silently.
