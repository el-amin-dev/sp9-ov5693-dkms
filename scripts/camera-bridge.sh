#!/usr/bin/env bash
# Publish the libcamera/PipeWire front camera as an ordinary V4L2 webcam.
#
#   ./scripts/camera-bridge.sh start     # begin feeding /dev/video<N>
#   ./scripts/camera-bridge.sh stop
#   ./scripts/camera-bridge.sh status
#
# Why this exists: the sensor only reaches userspace through libcamera's software
# ISP, which PipeWire exposes as a Video/Source offering RGBx/BGRx only, reachable
# just via the xdg camera portal. Chrome asks the portal from a windowless utility
# process, so GNOME refuses to show the permission dialog ("Only the focused app
# is allowed to show a system access dialog") and access is denied outright. A
# v4l2loopback device sidesteps all of that: every app -- Chrome, Firefox, Zoom,
# Teams, GNOME Snapshot -- speaks plain V4L2, with no flags and no portal.
#
# Two sensor quirks are handled here rather than left to the client:
#   * below ~1296px wide the software ISP returns all-zero (black) buffers, so the
#     capture side is pinned to 1920x1080 no matter what the client asks for;
#   * clients overwhelmingly default to 640x480, which would be black, so the
#     loopback advertises a single fixed 1280x720 YUY2 format that every client
#     accepts, downscaled from the good 1080p capture.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

readonly CARD_LABEL="Surface Front Camera"
readonly CAPTURE_W=1920 CAPTURE_H=1080   # must stay >= 1296 wide, see above
readonly OUT_W=1280 OUT_H=720            # what clients see
readonly PIDFILE="out/camera-bridge.pid"
readonly LOGFILE="out/camera-bridge.log"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m FAIL\033[0m %s\n' "$*" >&2; exit 1; }

# The loopback device, identified by the card label we set when loading it.
loopback_device() {
	local d name
	for d in /dev/video*; do
		[[ -e ${d} ]] || continue
		name="$(v4l2-ctl -d "${d}" --info 2>/dev/null | sed -n 's/^\s*Card type\s*:\s*//p')"
		[[ ${name} == "${CARD_LABEL}" ]] && { printf '%s' "${d}"; return 0; }
	done
	return 1
}

# object.serial of the front camera's PipeWire node, so the pipeline does not
# depend on a node id that changes between sessions.
front_camera_serial() {
	pw-dump 2>/dev/null | python3 -c '
import json, sys
for o in json.load(sys.stdin):
    p = (o.get("info") or {}).get("props") or {}
    if p.get("media.class") == "Video/Source" and p.get("api.libcamera.location") == "front":
        print(p.get("object.serial", "")); break
'
}

# Build the pipeline argv once, so 'start' and 'run' can never drift apart.
build_pipeline() {
	local serial=$1 dev=$2
	PIPELINE=(
		gst-launch-1.0
		pipewiresrc target-object="${serial}" always-copy=true
		! "video/x-raw,width=${CAPTURE_W},height=${CAPTURE_H}"
		! videoconvert ! videoscale
		! "video/x-raw,format=YUY2,width=${OUT_W},height=${OUT_H}"
		! v4l2sink device="${dev}" sync=false
	)
}

# Shared preflight for both start and run.
resolve_targets() {
	command -v v4l2-ctl >/dev/null || die "v4l-utils is not installed"
	[[ -e /sys/module/v4l2loopback ]] ||
		die "v4l2loopback is not loaded; run: sudo ./scripts/camera-bridge-setup.sh"
	DEV="$(loopback_device)" || die "no loopback device labelled '${CARD_LABEL}'"
	SERIAL="$(front_camera_serial)"
	[[ -n ${SERIAL} ]] || die "front camera not found in PipeWire"
}

case "${1:-status}" in
run)
	# Foreground mode for systemd: it supervises and restarts, so no pidfile.
	resolve_targets
	build_pipeline "${SERIAL}" "${DEV}"
	log "feeding ${DEV} from PipeWire serial ${SERIAL} (foreground)"
	exec "${PIPELINE[@]}"
	;;
start)
	command -v v4l2-ctl >/dev/null || die "v4l-utils is not installed"
	[[ -e /sys/module/v4l2loopback ]] ||
		die "v4l2loopback is not loaded; run: sudo ./scripts/camera-bridge-setup.sh"

	dev="$(loopback_device)" || die "no loopback device labelled '${CARD_LABEL}'"
	serial="$(front_camera_serial)"
	[[ -n ${serial} ]] || die "front camera not found in PipeWire"

	if [[ -f ${PIDFILE} ]] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
		ok "already running (pid $(cat "${PIDFILE}"))"
		exit 0
	fi

	log "feeding ${dev} from PipeWire serial ${serial}"
	mkdir -p out
	# videorate + a fixed output caps keeps the loopback format stable, which is
	# what lets clients negotiate without ever seeing the black low-res modes.
	nohup gst-launch-1.0 \
		pipewiresrc target-object="${serial}" always-copy=true \
		! "video/x-raw,width=${CAPTURE_W},height=${CAPTURE_H}" \
		! videoconvert ! videoscale \
		! "video/x-raw,format=YUY2,width=${OUT_W},height=${OUT_H}" \
		! v4l2sink device="${dev}" sync=false \
		>"${LOGFILE}" 2>&1 &
	echo $! >"${PIDFILE}"
	sleep 3
	if kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
		ok "bridge running (pid $(cat "${PIDFILE}")) -> ${dev} @ ${OUT_W}x${OUT_H} YUY2"
	else
		tail -15 "${LOGFILE}" >&2
		rm -f "${PIDFILE}"
		die "bridge died on startup, see ${LOGFILE}"
	fi
	;;
stop)
	if [[ -f ${PIDFILE} ]]; then
		kill "$(cat "${PIDFILE}")" 2>/dev/null && ok "stopped"
		rm -f "${PIDFILE}"
	else
		ok "not running"
	fi
	;;
status)
	if dev="$(loopback_device)"; then ok "loopback: ${dev}"; else echo "  no loopback device"; fi
	if [[ -f ${PIDFILE} ]] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
		ok "bridge pid $(cat "${PIDFILE}")"
	else
		echo "  bridge not running"
	fi
	;;
*) die "usage: $0 {start|stop|status}" ;;
esac
