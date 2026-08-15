#!/usr/bin/env bash
# Load v4l2loopback so the Surface cameras can be published as normal webcams.
#
#   sudo ./scripts/camera-bridge-setup.sh           # load now
#   sudo ./scripts/camera-bridge-setup.sh --persist # also load on every boot
#   sudo ./scripts/camera-bridge-setup.sh --undo    # unload and remove persistence
#
# Creates one loopback device per camera described in surfacecam/config.py --
# device numbers, card labels and module options all come from there, so this
# script keeps no second copy of them.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly MODCONF=/etc/modprobe.d/v4l2loopback-surface.conf
readonly LOADCONF=/etc/modules-load.d/v4l2loopback-surface.conf

# Runs from the repo root so `python3 -m` finds the package whatever directory
# sudo left us in. Empty output is treated as failure: it would otherwise reach
# modprobe as an option-less load, quietly creating the wrong devices.
config() {
	local value
	value="$(cd -- "${REPO_ROOT}" && python3 -m surfacecam.config "$1")" && [[ -n ${value} ]] ||
		{ echo "cannot read '$1' from surfacecam.config in ${REPO_ROOT}" >&2; exit 1; }
	printf '%s\n' "${value}"
}

[[ ${EUID} -eq 0 ]] || { echo "must run as root: sudo $0 $*" >&2; exit 1; }

# Teardown deliberately stays ahead of any config lookup, so a broken python
# install cannot leave the machine with no way to unload the module.
case "${1:-}" in
--undo)
	modprobe -r v4l2loopback 2>/dev/null || true
	rm -f "${MODCONF}" "${LOADCONF}"
	echo "unloaded and persistence removed"
	exit 0
	;;
esac

OPTS="$(config modprobe-options)"
readonly OPTS

if [[ ${1:-} == --persist ]]; then
	printf 'options v4l2loopback %s\n' "${OPTS}" >"${MODCONF}"
	printf 'v4l2loopback\n' >"${LOADCONF}"
	echo "persistence written: ${MODCONF}, ${LOADCONF}"
fi

# Reloading drops any client mid-stream, so stop the feeders first if they run.
modprobe -r v4l2loopback 2>/dev/null || true
# shellcheck disable=SC2086  # OPTS is a deliberate multi-token argument list
eval modprobe v4l2loopback ${OPTS}

labels="$(config labels)"
mapfile -t LABELS <<<"${labels}"
readonly LABELS

echo "loaded; devices now present:"
for d in /dev/video*; do
	name="$(v4l2-ctl -d "${d}" --info 2>/dev/null | sed -n 's/^\s*Card type\s*:\s*//p')"
	for label in "${LABELS[@]}"; do
		[[ ${name} == "${label}" ]] || continue
		echo "  ${d}  <-- ${name}"
		break
	done
done
