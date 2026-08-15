#!/usr/bin/env bash
# Shared constants and helpers. Sourced by the other scripts; not executable on
# its own. Everything here is derived at runtime -- no kernel version, no camera
# index and no device model is hardcoded, so the package works on any Surface
# that pairs an OV5693 with an Intel IPU6.

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# Single source of truth for name/version: parse the dkms.conf we ship.
DKMS_CONF="${REPO_ROOT}/src/dkms.conf"
[[ -r ${DKMS_CONF} ]] || { echo "cannot read ${DKMS_CONF}" >&2; exit 1; }
PKG_NAME="$(sed -n 's/^PACKAGE_NAME="\(.*\)"$/\1/p' "${DKMS_CONF}")"
PKG_VERSION="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "${DKMS_CONF}")"
# Never let these go empty: DKMS_SRC below is passed to rm -rf.
[[ -n ${PKG_NAME} && -n ${PKG_VERSION} ]] ||
	{ echo "could not parse PACKAGE_NAME/PACKAGE_VERSION from ${DKMS_CONF}" >&2; exit 1; }
readonly PKG_NAME PKG_VERSION
# shellcheck disable=SC2034  # consumed by the scripts that source this file
readonly DKMS_ID="${PKG_NAME}/${PKG_VERSION}"
# shellcheck disable=SC2034
readonly DKMS_SRC="/usr/src/${PKG_NAME}-${PKG_VERSION}"

KVER="${KVER:-$(uname -r)}"
readonly KVER
readonly MODULE="ov5693"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m FAIL\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
	[[ ${EUID} -eq 0 ]] || die "must run as root: sudo $0"
}

# Absolute path of the ov5693.ko modprobe would load right now.
module_path() { modinfo -F filename "${MODULE}" 2>/dev/null || true; }

# True when the DKMS-built module (in updates/dkms) is the one in effect.
module_is_patched() { [[ "$(module_path)" == *"/updates/dkms/"* ]]; }

# --- kernel log cursor ------------------------------------------------------
# A line count is not a usable cursor into a ring buffer: once it wraps, dmesg
# still returns about as many lines while the old ones have been evicted, so
# "everything after line N" silently becomes empty exactly when the driver is
# logging hardest. Use the monotonic timestamp of the last line instead.

# Timestamp (seconds, float) of the newest kernel log line; "0" if unreadable.
dmesg_mark() {
	local last
	last="$(dmesg 2>/dev/null | tail -1)"
	[[ ${last} =~ ^\[[[:space:]]*([0-9]+\.[0-9]+)\] ]] &&
		{ printf '%s' "${BASH_REMATCH[1]}"; return 0; }
	printf '0'
}

# Kernel log lines newer than mark $1, optionally filtered by regex $2.
dmesg_since() {
	local mark=$1 pattern=${2:-.}
	dmesg 2>/dev/null |
		awk -v mark="${mark}" '
			match($0, /^\[[ ]*[0-9]+\.[0-9]+\]/) {
				ts = substr($0, RSTART + 1, RLENGTH - 2) + 0
				if (ts > mark)
					print
			}' |
		grep -E "${pattern}" || true
}

# The failure signature this project exists to remove.
# shellcheck disable=SC2034  # consumed by tests/test-capture.sh
readonly STREAM_TIMEOUT_RE='stream (stop|close) time out'

# i2c devices currently bound to the sensor driver, one per line
# (e.g. "i2c-OVTI5693:00"). Empty output means nothing is bound.
bound_devices() {
	local d
	for d in "/sys/bus/i2c/drivers/${MODULE}/"*:*; do
		[[ -e ${d} ]] || continue
		basename "${d}"
	done
}

# i2c adapter number the sensor is bound to (e.g. "3" for i2c-3), empty if none.
# Surface firmware names the libcamera camera after that adapter -- SP9's front
# sensor sits on i2c-3 and shows up as "\_SB_.PC00.I2C3.CAMF" -- which is what
# lets the test pick the right camera without hardcoding a model.
sensor_i2c_bus() {
	local dev parent
	dev="$(bound_devices | head -1)"
	[[ -n ${dev} ]] || return 0
	parent="$(basename "$(dirname "$(readlink -f "/sys/bus/i2c/drivers/${MODULE}/${dev}")")")"
	[[ ${parent} =~ ^i2c-([0-9]+)$ ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# Reload the sensor module, tolerating it not being loaded yet.
# Fails loudly if a loaded module cannot be removed: modprobe would then be a
# no-op and the old code would still be running, which every later assertion
# based on modinfo(1) -- which reports the file on disk, not the loaded module --
# would happily accept.
reload_module() {
	if [[ -d "/sys/module/${MODULE}" ]]; then
		modprobe -r "${MODULE}" ||
			{ echo "cannot unload ${MODULE}: still in use? (close any camera app)" >&2; return 1; }
	fi
	modprobe "${MODULE}"
}
