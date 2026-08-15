#!/usr/bin/env bash
# Publish a libcamera/PipeWire camera as an ordinary V4L2 webcam.
#
#   ./scripts/camera-bridge.sh start front
#   ./scripts/camera-bridge.sh run back        # foreground, for systemd
#   ./scripts/camera-bridge.sh stop front
#   ./scripts/camera-bridge.sh status          # both cameras
#
# Why this exists: these sensors reach userspace only through libcamera's software
# ISP, which PipeWire exposes as a Video/Source offering RGBx/BGRx and reachable
# just via the xdg camera portal. Chrome asks the portal from a windowless utility
# process, so GNOME refuses to show the permission dialog ("Only the focused app
# is allowed to show a system access dialog") and access is denied outright. A
# v4l2loopback device sidesteps all of that: every app -- Chrome, Firefox, Zoom,
# Teams, GNOME Snapshot -- speaks plain V4L2, with no flags and no portal.
#
# Two quirks are handled here rather than left to the client:
#   * on the front sensor (ov5693) the software ISP returns all-zero buffers below
#     ~1296px wide, so capture is pinned to 1920x1080 whatever the client asks for;
#   * clients overwhelmingly default to 640x480, which would be black, so each
#     loopback advertises one fixed 1280x720 YUY2 mode, downscaled from that
#     capture.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

readonly CAPTURE_W=1920 CAPTURE_H=1080   # must stay >= 1296 wide, see above
readonly OUT_W=1280 OUT_H=720            # what clients see

# location -> card label. The label is the contract between setup (which creates
# the devices) and this script (which finds them), and it is what users see in
# their browser's camera menu.
label_for() {
	case $1 in
	front) printf 'Surface Front Camera' ;;
	back) printf 'Surface Back Camera' ;;
	*) return 1 ;;
	esac
}

# Degrees to rotate each camera, clockwise.
#
# Not taken from api.libcamera.rotation, which does not describe what comes out of
# the pipeline: the front sensor reports 180 and libcamera already compensates, so
# its frames are upright; the back sensor reports 0 yet is physically mounted
# upside down, so nothing corrects it. These are the measured values. Override per
# machine with FRONT_ROTATION / BACK_ROTATION if a different model differs.
rotation_for() {
	case $1 in
	front) printf '%s' "${FRONT_ROTATION:-0}" ;;
	back) printf '%s' "${BACK_ROTATION:-180}" ;;
	*) printf '0' ;;
	esac
}

# GStreamer videoflip method for a rotation in degrees.
flip_method_for() {
	case $1 in
	0) printf 'none' ;;
	90) printf 'clockwise' ;;
	180) printf 'rotate-180' ;;
	270) printf 'counterclockwise' ;;
	*) die "unsupported rotation '$1' (use 0, 90, 180 or 270)" ;;
	esac
}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m FAIL\033[0m %s\n' "$*" >&2; exit 1; }

pidfile_for() { printf 'out/camera-bridge-%s.pid' "$1"; }

# The loopback device carrying a given card label.
loopback_device() {
	local want=$1 d name
	for d in /dev/video*; do
		[[ -e ${d} ]] || continue
		name="$(v4l2-ctl -d "${d}" --info 2>/dev/null | sed -n 's/^\s*Card type\s*:\s*//p')"
		[[ ${name} == "${want}" ]] && { printf '%s' "${d}"; return 0; }
	done
	return 1
}

# object.serial of a camera's PipeWire node.
#
# Matched primarily on the ACPI path, not api.libcamera.location: that property is
# not reliably populated -- after one reboot the front reported "front" while the
# back reported nothing at all, so a location-only match silently lost the back
# camera and the bridge declared it missing for 120s. The path comes from firmware
# and has been stable across every boot: ...CAMF is the front, ...CAMR the rear.
camera_serial() {
	pw-dump 2>/dev/null | python3 -c '
import json, sys

want = sys.argv[1]
# Most specific signal first; each is checked against every node before falling
# back, so a weaker signal never wins while a stronger one is available.
suffix = {"front": "CAMF", "back": "CAMR"}.get(want, "")
model = {"front": "ov5693", "back": "ov13858"}.get(want, "")

nodes = [
    (o.get("info") or {}).get("props") or {}
    for o in json.load(sys.stdin)
]
nodes = [p for p in nodes
         if p.get("media.class") == "Video/Source" and p.get("device.api") == "libcamera"]

def pick(match):
    for p in nodes:
        if match(p):
            return p.get("object.serial", "")
    return ""

serial = (
    pick(lambda p: str(p.get("api.libcamera.path", "")).endswith(suffix))
    or pick(lambda p: p.get("api.libcamera.location") == want)
    or pick(lambda p: p.get("device.product.name") == model)
)
if serial:
    print(serial)
' "$1"
}

# Are the sensor drivers up? Distinguishes "drivers not ready yet" from
# "WirePlumber missed the camera", which need different responses.
#
# Deliberately reads sysfs rather than asking libcamera: `cam -l` blocks while
# another process is streaming a camera, ignores SIGTERM while blocked, and so
# hangs forever even under timeout(1) without -k. A bound i2c device is the same
# signal without the ability to wedge the service.
sensors_bound() {
	local d
	for d in /sys/bus/i2c/drivers/ov*/*:*; do
		[[ -e ${d} ]] && return 0
	done
	return 1
}

# Wait for the camera's PipeWire node, nudging WirePlumber if it clearly missed it.
#
# At boot WirePlumber enumerates libcamera once, before the IPU6 and sensor
# drivers are ready, finds no cameras, and never looks again -- so the node simply
# never appears and the bridge would fail forever. If libcamera can see the camera
# but PipeWire has no node for it, WirePlumber is the stale one: restart it. The
# lock keeps the two instances from restarting it on top of each other.
wait_for_node() {
	local loc=$1 deadline=$((SECONDS + 120)) nudged=0 lock=/tmp/camera-bridge-wp-nudge.lock
	while :; do
		SERIAL="$(camera_serial "${loc}")"
		[[ -n ${SERIAL} ]] && return 0
		if [[ ${nudged} -eq 0 ]] && [[ ${SECONDS} -gt 15 ]] && sensors_bound; then
			if mkdir "${lock}" 2>/dev/null; then
				log "libcamera sees the camera but PipeWire has no node; restarting wireplumber"
				systemctl --user restart wireplumber || true
				sleep 6
				rmdir "${lock}" 2>/dev/null || true
			else
				sleep 6 # another instance is doing it
			fi
			nudged=1
			continue
		fi
		[[ ${SECONDS} -lt ${deadline} ]] || return 1
		sleep 3
	done
}

resolve() {
	local loc=$1
	CARD="$(label_for "${loc}")" || die "unknown camera '${loc}' (use front or back)"
	command -v v4l2-ctl >/dev/null || die "v4l-utils is not installed"
	[[ -e /sys/module/v4l2loopback ]] ||
		die "v4l2loopback is not loaded; run: sudo ./scripts/camera-bridge-setup.sh"
	DEV="$(loopback_device "${CARD}")" || die "no loopback device labelled '${CARD}'"
	ROTATION="$(rotation_for "${loc}")"
	FLIP="$(flip_method_for "${ROTATION}")"
	wait_for_node "${loc}" ||
		die "no ${loc} camera in PipeWire after 120s (check: cam -l, systemctl --user status wireplumber)"
}

# A node can exist and still be dead: reloading the sensor module invalidates
# libcamera's camera objects while WirePlumber keeps advertising the old nodes, and
# the first format request then fails with "error set output format: -22". The
# node-missing path never fires for that, so treat a pipeline that dies almost
# immediately as the same stale-node symptom and re-enumerate once. Marker file,
# not a variable: systemd restarts us as a fresh process each time.
readonly NUDGE_MARKER=/tmp/camera-bridge-stale-nudge

handle_early_exit() {
	local loc=$1 elapsed=$2
	[[ ${elapsed} -lt 15 ]] || { rm -f "${NUDGE_MARKER}.${loc}"; return; }
	if [[ ! -e "${NUDGE_MARKER}.${loc}" ]]; then
		: >"${NUDGE_MARKER}.${loc}"
		log "pipeline died in ${elapsed}s; camera node looks stale, re-enumerating"
		systemctl --user restart wireplumber 2>/dev/null || true
		sleep 6
	fi
}

run_pipeline() {
	# videoflip before videoscale: at 180 the dimensions are unchanged either way,
	# but rotating the smaller frame after scaling would cost less only for 90/270,
	# where scaling first would also swap the output aspect.
	gst-launch-1.0 \
		pipewiresrc target-object="${SERIAL}" always-copy=true \
		! "video/x-raw,width=${CAPTURE_W},height=${CAPTURE_H}" \
		! videoconvert ! videoflip method="${FLIP}" ! videoscale \
		! "video/x-raw,format=YUY2,width=${OUT_W},height=${OUT_H}" \
		! v4l2sink device="${DEV}" sync=false
}

cmd=${1:-status}
loc=${2:-front}

case ${cmd} in
run)
	# Foreground: systemd supervises and restarts, so no pidfile is kept.
	resolve "${loc}"
	log "feeding ${DEV} from ${loc} camera (serial ${SERIAL}, rotate ${ROTATION}deg)"
	started=${SECONDS}
	run_pipeline
	rc=$?
	handle_early_exit "${loc}" $((SECONDS - started))
	exit "${rc}"
	;;
start)
	resolve "${loc}"
	pidfile="$(pidfile_for "${loc}")"
	if [[ -f ${pidfile} ]] && kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
		ok "${loc} already running (pid $(cat "${pidfile}"))"
		exit 0
	fi
	mkdir -p out
	log "feeding ${DEV} from ${loc} camera (serial ${SERIAL})"
	nohup "$0" run "${loc}" >"out/camera-bridge-${loc}.log" 2>&1 &
	echo $! >"${pidfile}"
	sleep 3
	if kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
		ok "${loc} bridge running -> ${DEV} @ ${OUT_W}x${OUT_H} YUY2"
	else
		tail -15 "out/camera-bridge-${loc}.log" >&2
		rm -f "${pidfile}"
		die "${loc} bridge died on startup"
	fi
	;;
stop)
	pidfile="$(pidfile_for "${loc}")"
	if [[ -f ${pidfile} ]]; then
		kill "$(cat "${pidfile}")" 2>/dev/null && ok "${loc} stopped"
		rm -f "${pidfile}"
	else
		ok "${loc} not running"
	fi
	;;
status)
	for l in front back; do
		card="$(label_for "${l}")"
		if dev="$(loopback_device "${card}")"; then
			printf '  %-5s device=%s' "${l}" "${dev}"
		else
			printf '  %-5s device=none  ' "${l}"
		fi
		if systemctl --user is-active --quiet "camera-bridge@${l}" 2>/dev/null; then
			printf '  service=active\n'
		elif [[ -f "$(pidfile_for "${l}")" ]] && kill -0 "$(cat "$(pidfile_for "${l}")")" 2>/dev/null; then
			printf '  manual=running\n'
		else
			printf '  not running\n'
		fi
	done
	;;
*) die "usage: $0 {start|run|stop|status} [front|back]" ;;
esac
