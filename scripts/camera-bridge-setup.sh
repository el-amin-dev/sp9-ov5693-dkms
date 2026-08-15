#!/usr/bin/env bash
# Load v4l2loopback so the Surface cameras can be published as normal webcams.
#
#   sudo ./scripts/camera-bridge-setup.sh           # load now
#   sudo ./scripts/camera-bridge-setup.sh --persist # also load on every boot
#   sudo ./scripts/camera-bridge-setup.sh --undo    # unload and remove persistence
#
# Creates two devices, one per physical camera:
#   /dev/video42  "Surface Front Camera"   (ov5693)
#   /dev/video43  "Surface Back Camera"    (ov13858)
#
# exclusive_caps=1 is what makes browsers treat these as capture devices rather
# than outputs; without it Chrome and Firefox skip them entirely.
set -euo pipefail

readonly LABELS="Surface Front Camera,Surface Back Camera"
readonly VIDEO_NRS="42,43"
readonly MODCONF=/etc/modprobe.d/v4l2loopback-surface.conf
readonly LOADCONF=/etc/modules-load.d/v4l2loopback-surface.conf
readonly OPTS="devices=2 video_nr=${VIDEO_NRS} card_label=\"${LABELS}\" exclusive_caps=1"

[[ ${EUID} -eq 0 ]] || { echo "must run as root: sudo $0 $*" >&2; exit 1; }

case "${1:-}" in
--undo)
	modprobe -r v4l2loopback 2>/dev/null || true
	rm -f "${MODCONF}" "${LOADCONF}"
	echo "unloaded and persistence removed"
	exit 0
	;;
--persist)
	printf 'options v4l2loopback %s\n' "${OPTS}" >"${MODCONF}"
	printf 'v4l2loopback\n' >"${LOADCONF}"
	echo "persistence written: ${MODCONF}, ${LOADCONF}"
	;;
esac

# Reloading drops any client mid-stream, so stop the feeders first if they run.
modprobe -r v4l2loopback 2>/dev/null || true
# shellcheck disable=SC2086  # OPTS is a deliberate multi-token argument list
eval modprobe v4l2loopback ${OPTS}

echo "loaded; devices now present:"
for d in /dev/video*; do
	name="$(v4l2-ctl -d "${d}" --info 2>/dev/null | sed -n 's/^\s*Card type\s*:\s*//p')"
	case ${name} in
	"Surface "*" Camera") echo "  ${d}  <-- ${name}" ;;
	esac
done
