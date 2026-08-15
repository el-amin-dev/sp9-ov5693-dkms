#!/usr/bin/env bash
# Undo what install.sh set up.
#
#   ./uninstall.sh            # remove the bridge and the loopback devices
#   ./uninstall.sh --all      # also remove the patched ov5693 module and packages
#
# By default the patched ov5693 module is KEPT: it is the actual camera fix, it
# replaces nothing (the stock module stays on disk, merely shadowed), and removing
# it puts the front camera back to hanging on every capture. --all removes it too.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1

readonly USER_UNIT="${HOME}/.config/systemd/user/camera-bridge@.service"
readonly CAMERAS=(front back)
readonly PKGS=(v4l2loopback-dkms v4l2loopback-utils)

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m FAIL\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -ne 0 ]] || die "run as your normal user, not root (it calls sudo itself)"

all=0
case "${1:-}" in
--all) all=1 ;;
"") ;;
*) die "usage: $0 [--all]" ;;
esac

need_sudo() {
	sudo -n true 2>/dev/null && return 0
	log "sudo password needed for: $*"
	sudo -v || die "sudo required"
}

# --- bridge services ---------------------------------------------------------
log "Stopping the bridge services"
for cam in "${CAMERAS[@]}"; do
	systemctl --user disable --now "camera-bridge@${cam}" 2>/dev/null || true
done
# Also catch anything started by hand with camera-bridge.sh start.
for cam in "${CAMERAS[@]}"; do
	./scripts/camera-bridge.sh stop "${cam}" >/dev/null 2>&1 || true
done
rm -f "${USER_UNIT}"
systemctl --user daemon-reload 2>/dev/null || true
ok "services removed"

# --- loopback devices --------------------------------------------------------
log "Removing the v4l2loopback devices"
need_sudo "unload v4l2loopback"
sudo ./scripts/camera-bridge-setup.sh --undo || warn "module teardown reported an error"

if [[ ${all} -eq 0 ]]; then
	echo
	ok "Done. Kept on purpose:"
	echo "     - the patched ov5693 module (the actual camera fix)"
	echo "     - ${PKGS[*]}"
	echo "     Remove those too with: ./uninstall.sh --all"
	exit 0
fi

# --- the kernel module and packages -----------------------------------------
log "Removing the patched ov5693 module"
need_sudo "remove the ov5693 DKMS module"
sudo ./scripts/uninstall.sh || warn "ov5693 removal reported an error"

log "Removing packages"
# Only ever remove what we installed, and never let apt take anything else with
# it -- on this distro that can mean the desktop.
removals="$(apt-get -s remove "${PKGS[@]}" 2>/dev/null | grep -c '^Remv' || true)"
if [[ ${removals} -gt ${#PKGS[@]} ]]; then
	warn "apt would remove ${removals} packages, more than the ${#PKGS[@]} we installed; skipping"
	warn "inspect by hand: apt-get -s remove ${PKGS[*]}"
else
	need_sudo "remove ${PKGS[*]}"
	sudo apt-get remove -y "${PKGS[@]}" || warn "package removal reported an error"
fi

echo
ok "Fully removed. The stock in-tree ov5693 module is active again."
echo "     Note: the front camera will hang on capture again -- that is the bug this repo fixes."
