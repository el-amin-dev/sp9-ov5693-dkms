#!/usr/bin/env bash
# One-command setup for the Surface Pro 9 cameras on Debian/Ubuntu, Fedora, Arch
# and openSUSE (and their derivatives).
#
#   mkdir -p ~/projects && cd ~/projects
#   git clone https://github.com/el-amin-dev/sp9-ov5693-dkms
#   cd sp9-ov5693-dkms
#   ./install.sh
#
# Keep the clone where it is: the user service points at this directory, so moving
# or deleting it stops the cameras until ./install.sh is re-run.
#
#   ./install.sh --check       # report state, change nothing
#   ./install.sh --print-deps  # the packages this distro would get, change nothing
#   ./uninstall.sh             # undo it
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
readonly BIN_DIR="${HOME}/.local/bin"
readonly COMMANDS=(start-camera stop-camera surface-camera)
# Marker so the PATH line is added once and can be found again to remove it.
readonly PATH_MARKER="# added by sp9-ov5693-dkms (surface camera commands)"

# Package names per distro family live in scripts/pkg.sh.
# shellcheck source=scripts/pkg.sh
source scripts/pkg.sh

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

# Ask surfacecam/config.py, which is the single source of truth for what cameras
# exist and what they are called. Keeping a second copy here is exactly how the
# installer and the bridge used to end up disagreeing.
config_get() {
	local out
	out="$(python3 -m surfacecam.config "$1")" ||
		die "python3 -m surfacecam.config $1 failed; python3 must be installed and the repo intact"
	[[ -n ${out} ]] || die "surfacecam.config $1 returned nothing"
	printf '%s\n' "${out}"
}

# One bridge instance per physical camera; CAMERAS[i] is published as LABELS[i].
#
# Loaded on demand rather than at startup, because reading it needs python3 and
# python3 is one of the packages Step 0 installs. Doing this at the top meant a
# minimal system died on "python3 must be installed" before it could install it.
CAMERAS=()
LABELS=()
load_camera_config() {
	[[ ${#CAMERAS[@]} -gt 0 ]] && return 0
	read -r -a CAMERAS <<<"$(config_get keys)"
	mapfile -t LABELS < <(config_get labels)
	# A die() inside a subshell above only kills that subshell, so verify here
	# too: continuing with an empty camera list would silently install nothing.
	[[ ${#CAMERAS[@]} -gt 0 && ${#CAMERAS[@]} -eq ${#LABELS[@]} ]] ||
		die "surfacecam.config gave ${#CAMERAS[@]} camera(s) and ${#LABELS[@]} label(s); cannot continue"
}

# Make sure ~/.local/bin is on PATH for whatever shell the user runs.
#
# Each shell reads a different file, and only some of them read ~/.profile:
# bash uses ~/.bashrc for interactive shells, zsh ignores ~/.profile entirely in
# favour of ~/.zshrc, and fish does not use POSIX syntax at all. So the line goes
# wherever it is needed, once, marked so it can be found and removed again.
ensure_on_path() {
	case ":${PATH}:" in
	*":${BIN_DIR}:"*)
		ok "${BIN_DIR} is already on PATH"
		return 0
		;;
	esac

	local rc added=()
	for rc in "${HOME}/.profile" "${HOME}/.bashrc" "${HOME}/.zshrc"; do
		[[ -e ${rc} ]] || continue
		grep -qF "${PATH_MARKER}" "${rc}" 2>/dev/null && continue
		printf '\n%s\nexport PATH="$HOME/.local/bin:$PATH"\n' "${PATH_MARKER}" >>"${rc}"
		added+=("${rc}")
	done

	local fish_conf="${HOME}/.config/fish/conf.d/sp9-camera.fish"
	if command -v fish >/dev/null && [[ ! -e ${fish_conf} ]]; then
		install -d -m 0755 "$(dirname "${fish_conf}")"
		printf '%s\nfish_add_path "$HOME/.local/bin"\n' "${PATH_MARKER}" >"${fish_conf}"
		added+=("${fish_conf}")
	fi

	if [[ ${#added[@]} -gt 0 ]]; then
		ok "added ${BIN_DIR} to PATH in: ${added[*]}"
		warn "open a new terminal (or source the file) before the commands resolve"
	else
		warn "${BIN_DIR} is not on PATH and no shell profile was found to edit"
		warn "run the commands by full path, e.g. ${BIN_DIR}/start-camera"
	fi
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

# Same test as module_is_patched in scripts/common.sh (which this script does not
# source): only the patched driver has a mipi_ctrl00 parameter, wherever the
# distro's DKMS chose to install it.
patched_module_installed() { modinfo -F parm ov5693 2>/dev/null | grep -q '^mipi_ctrl00:'; }

check() {
	local i cam want dev
	log "State"
	if patched_module_installed; then
		ok "patched ov5693 active"
		[[ -r /sys/module/ov5693/parameters/mipi_ctrl00 ]] &&
			ok "mipi_ctrl00 = $(cat /sys/module/ov5693/parameters/mipi_ctrl00)"
	else
		warn "patched ov5693 NOT active"
	fi
	if [[ -e /sys/module/v4l2loopback ]]; then ok "v4l2loopback loaded"; else warn "v4l2loopback not loaded"; fi

	# --check is a diagnostic and must stay useful on a half-installed system, so
	# a missing python3 downgrades the report rather than aborting it.
	if ! python3 -m surfacecam.config keys >/dev/null 2>&1; then
		warn "cannot read surfacecam.config (is python3 installed?); skipping per-camera state"
		return 1
	fi
	load_camera_config

	for i in "${!CAMERAS[@]}"; do
		cam="${CAMERAS[i]}"
		want="${LABELS[i]}"
		if dev="$(device_for "${want}")"; then ok "${want}: ${dev}"; else warn "no '${want}' device"; fi
		if systemctl --user is-active --quiet "camera-bridge@${cam}"; then
			ok "  bridge@${cam} active"
		else
			warn "  bridge@${cam} not active"
		fi
	done
}

# Detected up front so --print-deps works without sudo or a package manager.
FAMILY="$(detect_family)" || FAMILY=""

print_deps() {
	[[ -n ${FAMILY} && ${FAMILY} != none ]] && deps_for "${FAMILY}" >/dev/null ||
		{ manual_needs >&2; exit 1; }
	echo "family: ${FAMILY}"
	echo "deps: $(deps_for "${FAMILY}")"
	echo "headers: $(headers_pkg "${FAMILY}")"
	echo "loopback: $(loopback_pkgs "${FAMILY}")"
}

case "${1:-}" in
--check) check; exit 0 ;;
--print-deps) print_deps; exit 0 ;;
--uninstall) exec ./uninstall.sh ;;
"") ;;
*) die "usage: $0 [--check | --print-deps]" ;;
esac

# --- 0. dependencies ---------------------------------------------------------
log "Step 0/4: dependencies"
# Checked before installing anything: with Secure Boot on, both out-of-tree
# modules need a signing key enrolled in MOK, or they are refused at load time
# after dozens of packages have already gone in.
if mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
	warn "Secure Boot is ON: ov5693 and v4l2loopback load only if signed with an enrolled MOK key"
	warn "see README 'Requirements'; continuing, but expect a module load failure otherwise"
fi
if [[ ${FAMILY} == none ]]; then
	warn "PKG_FAMILY=none: skipping package installation, assuming it was done by hand"
elif [[ -z ${FAMILY} ]] || ! deps_for "${FAMILY}" >/dev/null; then
	manual_needs >&2
	exit 1
else
	ok "package family: ${FAMILY}"
	# Only demand RPM Fusion when there is actually something to fetch from it;
	# a loopback installed another way (COPR, by hand) is fine as it is.
	if [[ ${FAMILY} == dnf ]]; then
		for p in $(loopback_pkgs dnf); do
			pkg_installed dnf "${p}" || { ensure_rpmfusion; break; }
		done
	fi
	# Headers first, and on their own: they must match the running kernel, and
	# installing them before akmod-v4l2loopback stops its kernel-devel dependency
	# being resolved against some other kernel.
	# shellcheck disable=SC2046  # deliberate word splitting into package names
	pkg_install "${FAMILY}" "$(headers_pkg "${FAMILY}")" $(headers_matched_pkg "${FAMILY}")
	# shellcheck disable=SC2046
	pkg_install "${FAMILY}" $(deps_for "${FAMILY}") $(loopback_pkgs "${FAMILY}")
	# akmods normally builds at boot; build now so modprobe finds it. A build the
	# package's own scriptlet started may be running too -- akmods serialises them.
	if [[ ${FAMILY} == dnf ]] && ! modinfo v4l2loopback >/dev/null 2>&1; then
		need_sudo "build v4l2loopback with akmods"
		sudo akmods --force --kernels "$(uname -r)" || die "akmods could not build v4l2loopback for $(uname -r)"
	fi
fi
[[ -d "/lib/modules/$(uname -r)/build" ]] ||
	die "no kernel headers for $(uname -r) even after install; a custom kernel, or one older than the installed one (reboot into the newest)?"
ok "kernel headers present for $(uname -r)"

# Safe now: python3 is installed.
load_camera_config
ok "cameras: ${CAMERAS[*]}"

# --- 1. the kernel module ----------------------------------------------------
log "Step 1/4: patched ov5693 kernel module"
if patched_module_installed; then
	ok "already installed and active"
else
	need_sudo "install the ov5693 DKMS module"
	sudo ./scripts/install-and-test.sh || die "ov5693 install failed -- see output above"
	# Reloading ov5693 invalidates libcamera's camera objects, but WirePlumber goes
	# on advertising the old nodes. They look present and healthy, so nothing
	# retries -- and the first format request on one fails with EINVAL. Force a
	# re-enumeration while we know the module has just changed underneath it.
	log "Refreshing WirePlumber after the module reload"
	systemctl --user restart wireplumber 2>/dev/null || true
	sleep 5
	ok "camera nodes re-enumerated"
fi

# --- 2. the loopback devices -------------------------------------------------
log "Step 2/4: v4l2loopback devices"
have=0
for label in "${LABELS[@]}"; do
	device_for "${label}" >/dev/null && have=$((have + 1))
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
log "Step 3/4: PipeWire -> V4L2 bridge services"
mkdir -p "$(dirname "${USER_UNIT}")"
# Older versions shipped a single non-templated unit. Left behind, its dangling
# autostart symlink fails on every boot, so clear it before installing the template.
if [[ -e "${HOME}/.config/systemd/user/camera-bridge.service" ]] ||
	[[ -L "${HOME}/.config/systemd/user/default.target.wants/camera-bridge.service" ]]; then
	systemctl --user disable --now camera-bridge.service 2>/dev/null || true
	rm -f "${HOME}/.config/systemd/user/camera-bridge.service" \
		"${HOME}/.config/systemd/user/default.target.wants/camera-bridge.service"
	ok "removed the superseded single-camera unit"
fi
sed "s|%REPO%|$(pwd)|" "scripts/camera-bridge@.service" >"${USER_UNIT}"
systemctl --user daemon-reload
# Installed but deliberately NOT enabled and NOT started.
#
# The bridge holds the sensor open for as long as it runs, which keeps the
# privacy LED lit, so the cameras stay off until asked for. start-camera turns
# them on; nothing does it automatically, including at login.
# --now as well as disable: `disable` alone leaves an already-running bridge
# streaming, so a re-run would end with the installer claiming the cameras are
# off while the LED is still lit.
for cam in "${CAMERAS[@]}"; do
	systemctl --user disable --now "camera-bridge@${cam}" 2>/dev/null || true
done
ok "bridge services installed, left stopped and disabled (use start-camera)"

# --- 4. the start/stop commands ----------------------------------------------
log "Step 4/4: start-camera / stop-camera"
install -d -m 0755 "${BIN_DIR}"
sed "s|%REPO%|$(pwd)|" bin/surface-camera >"${BIN_DIR}/surface-camera"
chmod 0755 "${BIN_DIR}/surface-camera"
# Symlinks rather than copies: one implementation, dispatching on the name it was
# invoked as.
for cmd in "${COMMANDS[@]}"; do
	[[ ${cmd} == surface-camera ]] && continue
	ln -sf surface-camera "${BIN_DIR}/${cmd}"
done
ok "installed ${COMMANDS[*]} into ${BIN_DIR}"

ensure_on_path

check
echo
shown="$(printf ", '%s'" "${LABELS[@]}")"
ok "Done. Apps will show ${shown:2} once the cameras are started."
echo
echo "     start-camera     turn the cameras on"
echo "     stop-camera      turn them off (sensors powered down, LED off)"
echo "     surface-camera status"
echo
echo "     The cameras are OFF right now, and stay off until you start them --"
echo "     nothing starts them at login."
echo "     Try it:   start-camera && xdg-open https://webcamtests.com"
echo "     Undo:     ./uninstall.sh"
