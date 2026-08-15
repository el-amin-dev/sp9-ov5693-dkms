#!/usr/bin/env bash
# One-command setup for the Surface Pro 9 cameras on Ubuntu.
#
#   git clone https://github.com/el-amin-dev/sp9-ov5693-dkms
#   cd sp9-ov5693-dkms
#   ./install.sh
#
#   ./install.sh --check   # report state, change nothing
#   ./uninstall.sh         # undo it
#
# What it sets up, in order:
#   0. build tools, kernel headers, GStreamer and V4L2 utilities
#   1. the patched ov5693 kernel module, via DKMS       (makes the sensor stream)
#   2. v4l2loopback: /dev/video42 and /dev/video43      (devices apps can open)
#   3. one user service per camera, bridging PipeWire into those devices
#
# Step 1 is what makes the front sensor produce frames at all; steps 2 and 3 are
# what make browsers and video-call apps able to use them. docs/RUNBOOK.md explains
# why the PipeWire route alone is not enough on GNOME.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1

readonly USER_UNIT="${HOME}/.config/systemd/user/camera-bridge@.service"
# One bridge instance per physical camera.
readonly CAMERAS=(front back)

# Everything the pipeline needs, by the command it provides:
#   dkms/build-essential/headers -> building both out-of-tree modules
#   gstreamer1.0-*               -> pipewiresrc, videoconvert/videoscale, v4l2sink
#   v4l-utils                    -> v4l2-ctl, used to find and inspect the devices
#   pipewire-bin                 -> pw-dump, used to locate the camera nodes
#   libcamera-tools              -> cam, used by the test scripts
readonly DEPS=(
	dkms build-essential
	gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good
	gstreamer1.0-pipewire
	v4l-utils pipewire-bin libcamera-tools
	v4l2loopback-dkms v4l2loopback-utils
)

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m FAIL\033[0m %s\n' "$*" >&2; exit 1; }

# Never run the whole script under sudo: the systemd unit and the PipeWire session
# both belong to the login user, and root's session has neither.
[[ ${EUID} -ne 0 ]] || die "run as your normal user, not root (it calls sudo itself)"

need_sudo() {
	sudo -n true 2>/dev/null && return 0
	log "sudo password needed for: $*"
	sudo -v || die "sudo required"
}

# Install packages, but never at the cost of removing any. On this distro pulling
# the wrong package can take the desktop with it, so a non-empty removal list is
# a hard stop rather than a prompt.
apt_install() {
	local want=("$@") missing=() removals p
	for p in "${want[@]}"; do
		dpkg -l "${p}" 2>/dev/null | grep -q '^ii' || missing+=("${p}")
	done
	[[ ${#missing[@]} -eq 0 ]] && { ok "already present: ${want[*]}"; return 0; }

	removals="$(apt-get -s install "${missing[@]}" 2>/dev/null | grep -c '^Remv' || true)"
	[[ ${removals} -eq 0 ]] ||
		die "apt would REMOVE ${removals} package(s); refusing. Check: apt-get -s install ${missing[*]}"

	need_sudo "install ${missing[*]}"
	sudo apt-get install -y "${missing[@]}" || die "package install failed: ${missing[*]}"
	ok "installed ${missing[*]}"
}

device_for() {
	local label=$1 d
	for d in /dev/video*; do
		[[ -e ${d} ]] || continue
		[[ "$(v4l2-ctl -d "${d}" --info 2>/dev/null | sed -n 's/^\s*Card type\s*:\s*//p')" == "${label}" ]] &&
			{ printf '%s' "${d}"; return 0; }
	done
	return 1
}

check() {
	local cam want dev
	log "State"
	if modinfo -F filename ov5693 2>/dev/null | grep -q updates/dkms; then
		ok "patched ov5693 active"
		[[ -r /sys/module/ov5693/parameters/mipi_ctrl00 ]] &&
			ok "mipi_ctrl00 = $(cat /sys/module/ov5693/parameters/mipi_ctrl00)"
	else
		warn "patched ov5693 NOT active"
	fi
	if [[ -e /sys/module/v4l2loopback ]]; then ok "v4l2loopback loaded"; else warn "v4l2loopback not loaded"; fi

	for cam in "${CAMERAS[@]}"; do
		want="Surface ${cam^} Camera"
		if dev="$(device_for "${want}")"; then ok "${want}: ${dev}"; else warn "no '${want}' device"; fi
		if systemctl --user is-active --quiet "camera-bridge@${cam}"; then
			ok "  bridge@${cam} active"
		else
			warn "  bridge@${cam} not active"
		fi
	done
}

case "${1:-}" in
--check) check; exit 0 ;;
--uninstall) exec ./uninstall.sh ;;
"") ;;
*) die "usage: $0 [--check]" ;;
esac

# --- 0. dependencies ---------------------------------------------------------
log "Step 0/3: dependencies"
apt_install "${DEPS[@]}"
# Headers must match the running kernel, whatever it is.
apt_install "linux-headers-$(uname -r)"
[[ -d "/lib/modules/$(uname -r)/build" ]] ||
	die "no kernel headers for $(uname -r) even after install; is this a custom kernel?"
ok "kernel headers present for $(uname -r)"

# --- 1. the kernel module ----------------------------------------------------
log "Step 1/3: patched ov5693 kernel module"
if modinfo -F filename ov5693 2>/dev/null | grep -q updates/dkms; then
	ok "already installed and active"
else
	need_sudo "install the ov5693 DKMS module"
	sudo ./scripts/install-and-test.sh || die "ov5693 install failed -- see output above"
fi

# --- 2. the loopback devices -------------------------------------------------
log "Step 2/3: v4l2loopback devices"
have=0
for cam in "${CAMERAS[@]}"; do
	device_for "Surface ${cam^} Camera" >/dev/null && have=$((have + 1))
done
if [[ ${have} -eq ${#CAMERAS[@]} ]]; then
	ok "loopback devices already present"
else
	need_sudo "load v4l2loopback"
	# Reloading the module drops live streams, so stop the feeders first.
	for cam in "${CAMERAS[@]}"; do
		systemctl --user stop "camera-bridge@${cam}" 2>/dev/null || true
	done
	sudo ./scripts/camera-bridge-setup.sh --persist || die "could not set up v4l2loopback"
fi

# --- 3. the bridge services --------------------------------------------------
log "Step 3/3: PipeWire -> V4L2 bridge services"
mkdir -p "$(dirname "${USER_UNIT}")"
sed "s|%REPO%|$(pwd)|" "scripts/camera-bridge@.service" >"${USER_UNIT}"
systemctl --user daemon-reload
for cam in "${CAMERAS[@]}"; do
	systemctl --user enable --now "camera-bridge@${cam}" ||
		warn "could not start camera-bridge@${cam}"
done
sleep 4
for cam in "${CAMERAS[@]}"; do
	# One camera failing must not hide a working other one.
	if systemctl --user is-active --quiet "camera-bridge@${cam}"; then
		ok "bridge@${cam} running"
	else
		warn "bridge@${cam} failed: systemctl --user status camera-bridge@${cam}"
	fi
done

check
echo
ok "Done. Apps now show 'Surface Front Camera' and 'Surface Back Camera'."
echo "     Try it:   https://webcamtests.com"
echo "     Undo:     ./uninstall.sh"
