#!/usr/bin/env bash
# Revert to the stock in-tree ov5693 module.
#
# The stock ov5693.ko is never modified or deleted by this package -- it is only
# shadowed by the DKMS copy in updates/dkms -- so removing that copy and running
# depmod is the whole rollback.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_root

log "Removing ${DKMS_ID}"
if dkms status -m "${PKG_NAME}" -v "${PKG_VERSION}" 2>/dev/null | grep -q .; then
	dkms remove "${DKMS_ID}" --all || warn "dkms remove reported an error, continuing"
else
	warn "${DKMS_ID} is not registered with dkms"
fi

rm -rf "${DKMS_SRC}"
depmod -a "${KVER}"

log "Reloading the stock module"
reload_module

path="$(module_path)"
if module_is_patched; then
	die "still loading ${path} -- the patched module was not removed"
fi
ok "stock module in effect: ${path:-<not found>}"

devices="$(bound_devices | tr '\n' ' ')"
if [[ -n ${devices} ]]; then
	ok "bound devices: ${devices}"
else
	warn "stock module loaded but bound no i2c device -- check 'dmesg | grep ov5693'"
fi
