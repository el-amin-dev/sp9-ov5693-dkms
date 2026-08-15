#!/usr/bin/env bash
# One-command setup for the Surface Pro 9 front camera on Ubuntu.
#
#   ./install.sh              # do everything (prompts for sudo where needed)
#   ./install.sh --uninstall  # undo everything this script did
#   ./install.sh --check      # report state, change nothing
#
# What it sets up, in order:
#   1. the patched ov5693 kernel module, via DKMS          (fixes the sensor itself)
#   2. v4l2loopback, providing /dev/video42                (a device apps can open)
#   3. a user service bridging PipeWire -> that device     (fills it with frames)
#
# Step 1 is what makes the camera produce frames at all; steps 2 and 3 are what
# make browsers and video-call apps able to use them. See docs/RUNBOOK.md for why
# the PipeWire route alone is not enough on GNOME.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1

readonly SERVICE_NAME="camera-bridge.service"
readonly USER_UNIT="${HOME}/.config/systemd/user/${SERVICE_NAME}"
readonly PKGS=(v4l2loopback-dkms v4l2loopback-utils)

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m FAIL\033[0m %s\n' "$*" >&2; exit 1; }

# Never run the whole script under sudo: the systemd unit and the PipeWire session
# both belong to the login user, and root's session has neither.
[[ ${EUID} -ne 0 ]] || die "run as your normal user, not root (it will call sudo itself)"

need_sudo() {
	sudo -n true 2>/dev/null && return 0
	log "sudo password needed for: $*"
	sudo -v || die "sudo required"
}

# --- checks -----------------------------------------------------------------
check() {
	local dev
	log "State"

	if modinfo -F filename ov5693 2>/dev/null | grep -q updates/dkms; then
		ok "patched ov5693 active ($(modinfo -F filename ov5693))"
		[[ -r /sys/module/ov5693/parameters/mipi_ctrl00 ]] &&
			ok "mipi_ctrl00 = $(cat /sys/module/ov5693/parameters/mipi_ctrl00)"
	else
		warn "patched ov5693 NOT active (run scripts/install-and-test.sh first)"
	fi

	if [[ -e /sys/module/v4l2loopback ]]; then ok "v4l2loopback loaded"; else warn "v4l2loopback not loaded"; fi

	dev=""
	for d in /dev/video*; do
		[[ -e ${d} ]] || continue
		[[ "$(v4l2-ctl -d "${d}" --info 2>/dev/null | sed -n 's/^\s*Card type\s*:\s*//p')" == "Surface Front Camera" ]] &&
			{ dev=${d}; break; }
	done
	if [[ -n ${dev} ]]; then
		ok "camera device: ${dev}"
		v4l2-ctl -d "${dev}" --list-formats-ext 2>/dev/null | grep -E 'Size|\[[0-9]\]' | sed 's/^/     /' | head -4
	else
		warn "no 'Surface Front Camera' device"
	fi

	if systemctl --user is-active --quiet camera-bridge; then
		ok "bridge service active"
	else
		warn "bridge service not active"
	fi
}

# --- uninstall ---------------------------------------------------------------
uninstall() {
	log "Removing the bridge service"
	systemctl --user disable --now camera-bridge 2>/dev/null || true
	rm -f "${USER_UNIT}"
	systemctl --user daemon-reload 2>/dev/null || true
	ok "service removed"

	log "Unloading v4l2loopback and removing its config"
	need_sudo "unload v4l2loopback"
	sudo ./scripts/camera-bridge-setup.sh --undo || warn "module teardown reported an error"

	echo
	ok "done. Left in place on purpose:"
	echo "     - the patched ov5693 module (that is the actual camera fix)"
	echo "       remove with: sudo ./scripts/uninstall.sh"
	echo "     - the ${PKGS[*]} packages"
	echo "       remove with: sudo apt-get remove ${PKGS[*]}"
}

case "${1:-}" in
--check) check; exit 0 ;;
--uninstall) uninstall; exit 0 ;;
"") ;;
*) die "usage: $0 [--check|--uninstall]" ;;
esac

# --- 1. the kernel module ----------------------------------------------------
log "Step 1/3: patched ov5693 kernel module"
if modinfo -F filename ov5693 2>/dev/null | grep -q updates/dkms; then
	ok "already installed and active"
else
	warn "not installed; running the DKMS installer (this needs sudo)"
	need_sudo "install the ov5693 DKMS module"
	sudo ./scripts/install-and-test.sh || die "ov5693 install failed -- see its output above"
fi

# --- 2. the loopback device --------------------------------------------------
log "Step 2/3: v4l2loopback device"
missing=()
for p in "${PKGS[@]}"; do
	dpkg -l "${p}" 2>/dev/null | grep -q '^ii' || missing+=("${p}")
done
if [[ ${#missing[@]} -gt 0 ]]; then
	# Refuse to proceed if apt would remove anything -- on this distro pulling the
	# wrong package can take the desktop with it.
	removals="$(apt-get -s install "${missing[@]}" 2>/dev/null | grep -c '^Remv' || true)"
	[[ ${removals} -eq 0 ]] ||
		die "apt would REMOVE ${removals} package(s); refusing. Check: apt-get -s install ${missing[*]}"
	need_sudo "install ${missing[*]}"
	sudo apt-get install -y "${missing[@]}" || die "package install failed"
	ok "installed ${missing[*]}"
else
	ok "packages already present"
fi

if [[ -e /sys/module/v4l2loopback ]] &&
	v4l2-ctl --list-devices 2>/dev/null | grep -q "Surface Front Camera"; then
	ok "loopback already set up"
else
	need_sudo "load v4l2loopback"
	sudo ./scripts/camera-bridge-setup.sh --persist || die "could not set up v4l2loopback"
fi

# --- 3. the bridge service ---------------------------------------------------
log "Step 3/3: PipeWire -> V4L2 bridge service"
mkdir -p "$(dirname "${USER_UNIT}")"
sed "s|%REPO%|$(pwd)|" scripts/camera-bridge.service >"${USER_UNIT}"
systemctl --user daemon-reload
systemctl --user enable --now camera-bridge || die "could not start the bridge service"
sleep 4
systemctl --user is-active --quiet camera-bridge ||
	die "bridge service failed: systemctl --user status camera-bridge"
ok "bridge running"

check
echo
ok "Setup complete. Apps will show one camera named 'Surface Front Camera'."
echo "     Verify in a browser:  ./tests/browser-camera-test.sh --headful"
echo "     Undo everything:      ./install.sh --uninstall"
