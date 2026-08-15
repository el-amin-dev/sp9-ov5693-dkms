#!/usr/bin/env bash
# Build, install and verify the patched ov5693 module -- the one privileged step.
#
#   sudo ./scripts/install-and-test.sh
#
# Safety contract: if anything below fails, the ERR trap rolls the package back
# and confirms the stock in-tree module is loadable again before exiting non-zero.
# The stock ov5693.ko is only ever shadowed, never modified or deleted.
#
# Touches: /usr/src/<pkg>-<ver>, /var/lib/dkms (dkms's own state) and
# /lib/modules/<kver>/updates/dkms + modules.dep (unavoidable for any DKMS
# install). Nothing in /boot, no bootloader config, no package manager, no reboot.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_root

STOCK_PATH=""
DMESG_MARK=0
ROLLED_BACK=0

# Runs on every exit; a zero status is the success path and does nothing.
rollback() {
	local rc=$1
	[[ ${rc} -eq 0 || ${ROLLED_BACK} -eq 1 ]] && exit "${rc}"
	ROLLED_BACK=1
	echo
	warn "failed (exit ${rc}) -- rolling back to the stock module"
	if [[ ${DMESG_MARK} -gt 0 ]]; then
		warn "kernel messages since the run started:"
		dmesg 2>/dev/null | tail -n "+$((DMESG_MARK + 1))" |
			grep -iE 'ov5693|ipu6|isys' | tail -20 >&2 || true
	fi
	"${REPO_ROOT}/scripts/uninstall.sh" || warn "rollback itself reported an error -- inspect 'dkms status' by hand"
	warn "stock module restored; see .claude/PROGRESS.md for the write-up"
	exit "${rc}"
}
# EXIT rather than ERR: die() exits directly, which an ERR trap would not catch.
trap 'rollback $?' EXIT

# --- 1. preflight -----------------------------------------------------------
log "Preflight"
[[ -d "/lib/modules/${KVER}/build" ]] ||
	die "no kernel headers for ${KVER} (install linux-headers-* for the running kernel)"
command -v dkms >/dev/null || die "dkms is not installed"
command -v cam >/dev/null || warn "libcamera's 'cam' is missing -- install/verify will run, capture tests will be skipped"
grep -qi surface /sys/class/dmi/id/product_name 2>/dev/null ||
	warn "this does not look like a Surface; the patch is harmless elsewhere but untested"
[[ -e /sys/bus/i2c/drivers/${MODULE} ]] ||
	warn "no ov5693 i2c device is currently bound -- is the sensor present?"
ok "kernel ${KVER}, headers present, dkms $(dkms --version 2>/dev/null || echo '?')"

if [[ "$(cat /sys/module/module/parameters/sig_enforce 2>/dev/null || echo N)" == "Y" ]]; then
	die "module signature enforcement is on -- the DKMS module would need a MOK-enrolled key"
fi

STOCK_PATH="$(module_path)"
DMESG_MARK="$(dmesg 2>/dev/null | wc -l)"
ok "stock module: ${STOCK_PATH:-<none loaded>}"

# --- 2. stage the source ----------------------------------------------------
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

# --- 3. build and install ---------------------------------------------------
log "dkms add / build / install for ${KVER}"
dkms add -m "${PKG_NAME}" -v "${PKG_VERSION}" >/dev/null
dkms build -m "${PKG_NAME}" -v "${PKG_VERSION}" -k "${KVER}" >/dev/null ||
	die "build failed -- see /var/lib/dkms/${PKG_NAME}/${PKG_VERSION}/build/make.log"
dkms install -m "${PKG_NAME}" -v "${PKG_VERSION}" -k "${KVER}" --force >/dev/null
depmod -a "${KVER}"
ok "$(dkms status -m "${PKG_NAME}" -v "${PKG_VERSION}")"

# --- 4. load it -------------------------------------------------------------
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

# --- 5. verify ---------------------------------------------------------------
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
