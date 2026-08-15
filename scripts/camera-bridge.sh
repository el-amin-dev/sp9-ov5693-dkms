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

# object.serial of a camera's PipeWire node, keyed on the physical location the
# firmware reports, so nothing depends on ids that change between sessions.
camera_serial() {
	pw-dump 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
for o in json.load(sys.stdin):
    p = (o.get("info") or {}).get("props") or {}
    if p.get("media.class") == "Video/Source" and p.get("api.libcamera.location") == want:
        print(p.get("object.serial", ""))
        break
' "$1"
}

# Does libcamera itself see this camera? Distinguishes "drivers not up yet" from
# "WirePlumber missed the camera", which need different responses.
libcamera_sees_any() {
	timeout 20 cam -l 2>/dev/null | grep -qE '^[0-9]+:'
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
		if [[ ${nudged} -eq 0 ]] && [[ ${SECONDS} -gt 15 ]] && libcamera_sees_any; then
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
	wait_for_node "${loc}" ||
		die "no ${loc} camera in PipeWire after 120s (check: cam -l, systemctl --user status wireplumber)"
}

run_pipeline() {
	exec gst-launch-1.0 \
		pipewiresrc target-object="${SERIAL}" always-copy=true \
		! "video/x-raw,width=${CAPTURE_W},height=${CAPTURE_H}" \
		! videoconvert ! videoscale \
		! "video/x-raw,format=YUY2,width=${OUT_W},height=${OUT_H}" \
		! v4l2sink device="${DEV}" sync=false
}

cmd=${1:-status}
loc=${2:-front}

case ${cmd} in
run)
	# Foreground: systemd supervises and restarts, so no pidfile is kept.
	resolve "${loc}"
	log "feeding ${DEV} from ${loc} camera (serial ${SERIAL})"
	run_pipeline
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
