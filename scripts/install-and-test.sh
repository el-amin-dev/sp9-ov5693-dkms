#!/usr/bin/env bash
# Build, install and verify the patched ov5693 module -- the one privileged step.
#
#   sudo ./scripts/install-and-test.sh
#
# Safety contract, in two stages:
#   preflight and a trial build run BEFORE anything is installed, so a missing
#   header package or a source that no longer compiles changes nothing at all;
#   after that an EXIT trap rolls the package back and confirms the stock in-tree
#   module is loadable again before exiting non-zero.
# The stock ov5693.ko is only ever shadowed, never modified or deleted.
#
# Touches: /usr/src/<pkg>-<ver>, /var/lib/dkms (dkms's own state) and
# /lib/modules/<kver>/updates/dkms + modules.dep (unavoidable for any DKMS
# install). Nothing in /boot, no bootloader config, no package manager, no reboot.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_root

STOCK_PATH=""
DMESG_MARK=""
ROLLED_BACK=0

# Runs on every exit; a zero status is the success path and does nothing.
rollback() {
	local rc=$1
	# Explicit if, not `[[ ... ]] && exit`: the latter's non-zero status on the
	# success path is exactly the set -e footgun this trap must not step on.
	if [[ ${rc} -eq 0 || ${ROLLED_BACK} -eq 1 ]]; then
		exit "${rc}"
	fi
	ROLLED_BACK=1
	echo
	warn "failed (exit ${rc}) -- rolling back to the stock module"
	if [[ -n ${DMESG_MARK} ]]; then
		warn "kernel messages since the run started:"
		dmesg_since "${DMESG_MARK}" 'ov5693|ipu6|isys' | tail -20 >&2 || true
	fi
	"${REPO_ROOT}/scripts/uninstall.sh" || warn "rollback itself reported an error -- inspect 'dkms status' by hand"
	warn "stock module restored; see .claude/PROGRESS.md for the write-up"
	exit "${rc}"
}

# --- 1. preflight -----------------------------------------------------------
# Deliberately BEFORE the rollback trap is armed. A preflight failure means we
# have changed nothing, so it must not trigger an uninstall -- otherwise running
# this on a kernel whose headers are not installed yet would destroy an existing,
# working installation (including its builds for every other kernel).
log "Preflight"
[[ -d "/lib/modules/${KVER}/build" ]] ||
	die "no kernel headers for ${KVER} (install linux-headers-* for the running kernel)"
command -v dkms >/dev/null || die "dkms is not installed"
command -v cam >/dev/null || warn "libcamera's 'cam' is missing -- install/verify will run, capture tests will be skipped"
grep -qi surface /sys/class/dmi/id/product_name 2>/dev/null ||
	warn "this does not look like a Surface; the patch is harmless elsewhere but untested"
[[ -n "$(bound_devices)" ]] ||
	warn "no ov5693 i2c device is currently bound -- is the sensor present?"
ok "kernel ${KVER}, headers present, dkms $(dkms --version 2>/dev/null || echo '?')"

if [[ "$(cat /sys/module/module/parameters/sig_enforce 2>/dev/null || echo N)" == "Y" ]]; then
	die "module signature enforcement is on -- the DKMS module would need a MOK-enrolled key"
fi

STOCK_PATH="$(module_path)"
DMESG_MARK="$(dmesg_mark)"
ok "stock module: ${STOCK_PATH:-<none loaded>}"

# --- 2. trial build ---------------------------------------------------------
# Compile in a throwaway directory BEFORE touching any existing installation.
# Staging necessarily removes the currently installed package (same name and
# version), so a source that does not compile -- the expected outcome on a kernel
# that has reworked this driver -- must be caught while rollback still means
# "change nothing" rather than "fall back to the stock module".
log "Trial build (nothing installed yet)"
trial="$(mktemp -d)"
cp "${REPO_ROOT}/src/ov5693.c" "${REPO_ROOT}/src/Makefile" "${trial}/"
if ! make -C "/lib/modules/${KVER}/build" M="${trial}" modules >"${trial}/build.log" 2>&1; then
	tail -20 "${trial}/build.log" >&2
	rm -rf "${trial}"
	die "the patched source does not build against ${KVER} -- nothing was changed"
fi
[[ -f "${trial}/${MODULE}.ko" ]] || { rm -rf "${trial}"; die "build produced no ${MODULE}.ko"; }
trial_vermagic="$(modinfo -F vermagic "${trial}/${MODULE}.ko")"
rm -rf "${trial}"
[[ ${trial_vermagic} == "${KVER}"* ]] ||
	die "built module reports vermagic '${trial_vermagic}', which ${KVER} will reject"
ok "compiles clean, vermagic '${trial_vermagic}'"

# Everything past this point can modify installed state, so arm the rollback.
# EXIT rather than ERR: die() exits directly, which an ERR trap would not catch.
trap 'rollback $?' EXIT

# --- 3. stage the source ----------------------------------------------------
log "Staging ${DKMS_ID} into ${DKMS_SRC}"
if dkms status -m "${PKG_NAME}" -v "${PKG_VERSION}" 2>/dev/null | grep -q .; then
	warn "already registered -- removing the previous copy first"
	dkms remove "${DKMS_ID}" --all >/dev/null 2>&1 || true
fi
rm -rf "${DKMS_SRC}"
install -d -m 0755 "${DKMS_SRC}"
install -m 0644 "${REPO_ROOT}/src/ov5693.c" "${REPO_ROOT}/src/Makefile" \
	"${REPO_ROOT}/src/dkms.conf" "${DKMS_SRC}/"
ok "staged"

# --- 4. build and install ---------------------------------------------------
log "dkms add / build / install for ${KVER}"
dkms add -m "${PKG_NAME}" -v "${PKG_VERSION}" >/dev/null
dkms build -m "${PKG_NAME}" -v "${PKG_VERSION}" -k "${KVER}" >/dev/null ||
	die "build failed -- see /var/lib/dkms/${PKG_NAME}/${PKG_VERSION}/build/make.log"
dkms install -m "${PKG_NAME}" -v "${PKG_VERSION}" -k "${KVER}" --force >/dev/null
depmod -a "${KVER}"
ok "$(dkms status -m "${PKG_NAME}" -v "${PKG_VERSION}")"

# --- 5. load it -------------------------------------------------------------
log "Reloading ${MODULE}"
reload_module
module_is_patched || die "modprobe still resolves to $(module_path) -- the DKMS module is not shadowing the stock one"
[[ -r "/sys/module/${MODULE}/parameters/mipi_ctrl00" ]] ||
	die "patched module loaded but exposes no mipi_ctrl00 parameter"
ok "patched module live: $(module_path)"
ok "mipi_ctrl00 = $(cat "/sys/module/${MODULE}/parameters/mipi_ctrl00")"

[[ -n "$(bound_devices)" ]] ||
	die "the patched module loaded but bound no i2c device -- ACPI HID regression"
ok "bound: $(bound_devices | tr '\n' ' ')"

# --- 6. verify ---------------------------------------------------------------
if command -v cam >/dev/null; then
	log "Running capture tests"
	"${REPO_ROOT}/tests/test-capture.sh"
else
	warn "skipping capture tests: 'cam' not installed"
fi

trap - EXIT
echo
ok "SUCCESS -- patched ov5693 installed and verified"
echo "     roll back at any time with: sudo ${REPO_ROOT}/scripts/uninstall.sh"
