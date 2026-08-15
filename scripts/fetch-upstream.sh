#!/usr/bin/env bash
# Re-fetch the pristine upstream driver and check our vendored copy against it.
#
#   ./scripts/fetch-upstream.sh            # verify: reapply the patches and diff
#   ./scripts/fetch-upstream.sh --rebase   # write the result to src/ov5693.c
#
# src/ov5693.c is the upstream file named in patches/upstream.pin plus the two
# patches under patches/. This script is how that claim stays checkable, and how
# the package moves to a newer kernel:
#
#   UPSTREAM_TAG=v6.20 ./scripts/fetch-upstream.sh --rebase
#
# --rebase rewrites patches/upstream.pin with the new tag and sha, so the pin can
# never end up asserting a provenance src/ does not have.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

PIN_FILE="${REPO_ROOT}/patches/upstream.pin"
[[ -r ${PIN_FILE} ]] || die "cannot read ${PIN_FILE}"

# An explicit UPSTREAM_TAG in the environment wins over the pin -- that is how a
# rebase to a new kernel is started. Capture it before sourcing.
env_tag="${UPSTREAM_TAG:-}"
# shellcheck source=../patches/upstream.pin
source "${PIN_FILE}"
[[ -n ${UPSTREAM_TAG:-} && -n ${UPSTREAM_SHA256:-} ]] ||
	die "UPSTREAM_TAG / UPSTREAM_SHA256 missing from ${PIN_FILE}"
[[ -n ${env_tag} ]] && UPSTREAM_TAG="${env_tag}"

UPSTREAM_URL="https://raw.githubusercontent.com/torvalds/linux/${UPSTREAM_TAG}/drivers/media/i2c/ov5693.c"

rebase=0
[[ ${1:-} == "--rebase" ]] && rebase=1

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

log "Fetching ${UPSTREAM_URL}"
curl -fsSL -o "${workdir}/ov5693.c" "${UPSTREAM_URL}"

actual="$(sha256sum "${workdir}/ov5693.c" | cut -d' ' -f1)"
if [[ ${actual} != "${UPSTREAM_SHA256}" ]]; then
	if [[ ${rebase} -eq 1 ]]; then
		warn "upstream changed: ${actual}"
		warn "(was ${UPSTREAM_TAG:-?} ${UPSTREAM_SHA256}) -- the pin will be updated"
	else
		die "upstream sha256 mismatch: got ${actual}, pinned ${UPSTREAM_SHA256}"
	fi
else
	ok "upstream sha256 matches the pin"
fi

log "Applying patches/"
# Named target file, so the a/ b/ prefixes in the diffs need no -p juggling.
for p in "${REPO_ROOT}"/patches/[0-9]*.patch; do
	patch -s --no-backup-if-mismatch "${workdir}/ov5693.c" <"${p}" ||
		die "failed to apply $(basename "${p}")"
	ok "applied $(basename "${p}")"
done

if [[ ${rebase} -eq 1 ]]; then
	cp "${workdir}/ov5693.c" "${REPO_ROOT}/src/ov5693.c"
	cat >"${PIN_FILE}" <<-EOF
		# Upstream base for src/ov5693.c. Single source of truth: read by
		# scripts/fetch-upstream.sh and rewritten by its --rebase mode, so the pin can
		# never drift from what src/ actually contains. Do not duplicate these values
		# anywhere else (least of all in a code comment).
		UPSTREAM_TAG=${UPSTREAM_TAG}
		UPSTREAM_SHA256=${actual}
	EOF
	ok "src/ov5693.c rewritten from ${UPSTREAM_TAG} + patches/"
	ok "pin updated: ${UPSTREAM_TAG} ${actual}"
	warn "rebuild and retest before trusting this: sudo ./scripts/install-and-test.sh"
	exit 0
fi

if diff -u "${workdir}/ov5693.c" "${REPO_ROOT}/src/ov5693.c"; then
	ok "src/ov5693.c is exactly ${UPSTREAM_TAG} + patches/"
else
	die "src/ov5693.c has drifted from ${UPSTREAM_TAG} + patches/ (diff above)"
fi
