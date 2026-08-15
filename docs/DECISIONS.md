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
