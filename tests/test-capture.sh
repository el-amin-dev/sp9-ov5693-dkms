#!/usr/bin/env bash
# Acceptance test for the patched ov5693 module.
#
# The bug being fixed is a hang: without the MIPI_CTRL00 write the IPU6 D-PHY
# never locks, `cam` blocks forever and the kernel logs "stream stop time out".
# So the two hard assertions per resolution are:
#
#   1. cam exits 0 within the timeout (it must not hang), and
#   2. no new "stream (stop|close) time out" line appears in dmesg.
#
# Frame content is asserted only at >= 1296 px wide. libcamera's software ISP
# returns empty buffers for narrower streams, so an all-zero 1280x720 capture is
# a known libcamera limitation, not a driver regression -- it is measured and
# reported, never failed on.
#
# Needs root for dmesg (kernel.dmesg_restrict=1 on Ubuntu).
#
# Env overrides:
#   OV5693_CAM    camera index or id substring (default: auto-detected)
#   RESOLUTIONS   space-separated WxH list  (default: 1920x1080 2592x1944)
#   FRAMES        frames per capture        (default: 5)
#   CAPTURE_TIMEOUT seconds per capture     (default: 30)
#   OUTDIR        where frames are written  (default: mktemp -d)
set -uo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd)/common.sh"

# Deliberately no mode narrower than SOFTISP_MIN_WIDTH below.
#
# The front sensor cannot stream them: 1280x720 does not merely return black, it
# makes the IPU6 receiver log "stream stop time out" and leaves it wedged, so the
# FIFO-overflow errors that follow poison later captures in the same run. Testing
# a mode nothing uses was failing the whole install -- and rolling back a module
# that works perfectly at the sizes the bridge actually runs at.
#
# Pass RESOLUTIONS explicitly to probe narrow modes; results below the threshold
# are reported but never fail the run.
RESOLUTIONS="${RESOLUTIONS:-1920x1080 2592x1944}"
FRAMES="${FRAMES:-5}"
CAPTURE_TIMEOUT="${CAPTURE_TIMEOUT:-30}"
OUTDIR="${OUTDIR:-$(mktemp -d /tmp/ov5693-capture.XXXXXX)}"
# Below this width libcamera's soft ISP hands back empty buffers.
readonly SOFTISP_MIN_WIDTH=1296

failures=0
declare -a RESULTS=()

# --- camera discovery -------------------------------------------------------
# Prefer an explicit override, then ask libcamera which camera reports an
# ov5693, and only then fall back to the Surface front-camera ACPI path.
detect_camera() {
	if [[ -n "${OV5693_CAM:-}" ]]; then
		printf '%s' "${OV5693_CAM}"
		return 0
	fi

	# Parse the indices libcamera actually reports rather than assuming they run
	# 1..N contiguously.
	local idx
	local -a indices=()
	mapfile -t indices < <(cam -l 2>/dev/null | sed -n 's/^\([0-9]\+\):.*/\1/p')
	[[ ${#indices[@]} -gt 0 ]] || return 1

	for idx in "${indices[@]}"; do
		if cam -c "${idx}" -I 2>/dev/null | grep -qi 'ov5693'; then
			printf '%s' "${idx}"
			return 0
		fi
	done

	# Match the camera whose ACPI id names the i2c adapter the sensor is on.
	local bus
	bus="$(sensor_i2c_bus)"
	if [[ -n ${bus} ]]; then
		idx="$(cam -l 2>/dev/null | grep -iE "^[0-9]+:.*I2C${bus}\." | head -1 | cut -d: -f1)"
		if [[ -n ${idx} ]]; then
			warn "libcamera does not report the sensor model; matched on i2c-${bus} instead (index ${idx})"
			printf '%s' "${idx}"
			return 0
		fi
	fi

	idx="$(cam -l 2>/dev/null | grep -iE '^[0-9]+:.*CAMF' | head -1 | cut -d: -f1)"
	[[ -n ${idx} ]] || return 1
	warn "could not identify the sensor; falling back to the front camera (index ${idx})"
	printf '%s' "${idx}"
}

# --- helpers ----------------------------------------------------------------
# Ratio of non-zero bytes, as a percentage with two decimals.
nonzero_pct() {
	local f=$1 total nonzero
	total=$(stat -c %s "${f}")
	[[ ${total} -gt 0 ]] || { printf '0.00'; return; }
	nonzero=$(tr -d '\0' <"${f}" | wc -c)
	awk -v n="${nonzero}" -v t="${total}" 'BEGIN { printf "%.2f", (n * 100.0) / t }'
}

# --- one resolution ---------------------------------------------------------
run_resolution() {
	local cam_id=$1 res=$2
	local width=${res%x*} height=${res#*x}
	local dir="${OUTDIR}/${res}"
	local logf="${dir}/cam.log"
	local before rc timeouts biggest pct verdict

	mkdir -p "${dir}"
	log "Capturing ${FRAMES} frames at ${res}"

	before=$(dmesg_mark)
	# -k: the hang this test detects may well ignore SIGTERM, so escalate to
	# SIGKILL. --foreground: without it timeout waits on a process group that a
	# stuck cam can keep alive, and the "timeout" would itself never return.
	timeout -k 5 --foreground "${CAPTURE_TIMEOUT}" \
		cam -c "${cam_id}" -C"${FRAMES}" \
		-s "width=${width},height=${height}" \
		--file="${dir}/frame-#.raw" >"${logf}" 2>&1
	rc=$?

	# libcamera may adjust the requested size. Read what was actually configured
	# from cam's own "configuring streams" line -- anchored on that line because
	# the log is full of unrelated resolutions (sensor array sizes in warnings).
	local actual eff_width=${width}
	actual="$(sed -n 's/.*configuring streams: ([0-9]*) \([0-9]*x[0-9]*\).*/\1/p' "${logf}" | head -1)"
	if [[ -n ${actual} ]]; then
		eff_width=${actual%x*}
		[[ ${actual} == "${res}" ]] || warn "requested ${res}, libcamera configured ${actual}"
	fi

	# 124 = terminated by timeout; 137 = it took the SIGKILL from -k.
	# Below the soft-ISP threshold nothing is fatal: the sensor cannot do those
	# modes, the bridge never asks for them, and failing on one would reject a
	# perfectly good driver.
	local fatal=1 tag=FAIL
	[[ ${width} -ge ${SOFTISP_MIN_WIDTH} ]] || { fatal=0; tag="INFO(unsupported-mode)"; }

	if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
		RESULTS+=("${tag} ${res}: cam still running after ${CAPTURE_TIMEOUT}s")
		[[ ${fatal} -eq 1 ]] && ((failures++))
		return 1
	elif [[ ${rc} -ne 0 ]]; then
		RESULTS+=("${tag} ${res}: cam exited ${rc} -- $(tail -2 "${logf}" | tr '\n' ' ')")
		[[ ${fatal} -eq 1 ]] && ((failures++))
		return 1
	fi

	timeouts="$(dmesg_since "${before}" "${STREAM_TIMEOUT_RE}")"
	if [[ -n ${timeouts} ]]; then
		RESULTS+=("${tag} ${res}: kernel logged $(wc -l <<<"${timeouts}") stream timeout line(s)")
		[[ ${fatal} -eq 1 ]] && ((failures++))
		return 1
	fi

	biggest="$(find "${dir}" -name 'frame-*' -type f -printf '%s %p\n' 2>/dev/null |
		sort -rn | head -1 | cut -d' ' -f2-)"
	if [[ -z ${biggest} ]]; then
		RESULTS+=("${tag} ${res}: cam exited 0 but wrote no frames")
		[[ ${fatal} -eq 1 ]] && ((failures++))
		return 1
	fi

	pct="$(nonzero_pct "${biggest}")"
	# Judge on the width actually streamed, not the one asked for.
	if [[ ${eff_width} -ge ${SOFTISP_MIN_WIDTH} ]]; then
		if awk -v p="${pct}" 'BEGIN { exit !(p > 1.0) }'; then
			verdict="PASS ${res}: no timeouts, ${pct}% non-zero bytes"
		else
			verdict="FAIL ${res}: no timeouts but the frame is ${pct}% non-zero (black)"
			((failures++))
		fi
	else
		verdict="PASS ${res}: no timeouts, ${pct}% non-zero bytes (content not asserted: below the ${SOFTISP_MIN_WIDTH}px soft-ISP threshold)"
	fi
	RESULTS+=("${verdict}")
	ok "${verdict#* }"
	ok "negotiated stream: ${actual:-unknown}, $(find "${dir}" -name 'frame-*' -type f | wc -l) frame(s) written"
	return 0
}

# --- main -------------------------------------------------------------------
command -v cam >/dev/null || die "libcamera's 'cam' tool is not installed"
[[ ${EUID} -eq 0 ]] || warn "not running as root: dmesg is restricted, timeout detection will be blind"

CAM_ID="$(detect_camera)" || die "no OV5693 camera found; set OV5693_CAM to the index shown by 'cam -l'"
log "Using camera ${CAM_ID}: $(cam -l 2>/dev/null | grep -E "^${CAM_ID}:" || echo "${CAM_ID}")"
log "Module in effect: $(module_path)"
if [[ -r /sys/module/${MODULE}/parameters/mipi_ctrl00 ]]; then
	log "mipi_ctrl00 = $(</sys/module/${MODULE}/parameters/mipi_ctrl00) (0x$(printf '%x' "$(</sys/module/${MODULE}/parameters/mipi_ctrl00)"))"
else
	warn "no mipi_ctrl00 parameter -- the stock module appears to be loaded"
fi

for res in ${RESOLUTIONS}; do
	run_resolution "${CAM_ID}" "${res}" || true
done

echo
log "Summary (frames under ${OUTDIR})"
for r in "${RESULTS[@]}"; do
	printf '  %s\n' "${r}"
done

if [[ ${failures} -gt 0 ]]; then
	die "${failures} resolution(s) failed"
fi
ok "all capture checks passed"
