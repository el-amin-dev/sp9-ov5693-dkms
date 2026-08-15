#!/usr/bin/env bash
# Load v4l2loopback so the front camera can be published as a normal webcam.
#
#   sudo ./scripts/camera-bridge-setup.sh          # load now
#   sudo ./scripts/camera-bridge-setup.sh --persist # also load on every boot
#   sudo ./scripts/camera-bridge-setup.sh --undo    # unload and remove persistence
#
# exclusive_caps=1 is what makes Chrome and Firefox treat the node as a capture
# device rather than an output; without it browsers skip it entirely.
set -euo pipefail

readonly CARD_LABEL="Surface Front Camera"
readonly VIDEO_NR=42
readonly MODCONF=/etc/modprobe.d/v4l2loopback-surface.conf
readonly LOADCONF=/etc/modules-load.d/v4l2loopback-surface.conf
readonly OPTS="devices=1 video_nr=${VIDEO_NR} card_label=\"${CARD_LABEL}\" exclusive_caps=1"

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

modprobe -r v4l2loopback 2>/dev/null || true
# shellcheck disable=SC2086  # OPTS is a deliberate multi-token argument list
eval modprobe v4l2loopback ${OPTS}

echo "loaded; devices now present:"
for d in /dev/video*; do
	name="$(v4l2-ctl -d "${d}" --info 2>/dev/null | sed -n 's/^\s*Card type\s*:\s*//p')"
	[[ ${name} == "${CARD_LABEL}" ]] && echo "  ${d}  <-- ${name}"
done
