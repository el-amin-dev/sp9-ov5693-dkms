#!/usr/bin/env bash
# Re-fetch the pristine upstream driver and check our vendored copy against it.
#
#   ./scripts/fetch-upstream.sh            # verify: reapply the patches and diff
#   ./scripts/fetch-upstream.sh --rebase   # write the result to src/ov5693.c
#
# src/ov5693.c is upstream v6.19 plus the two patches under patches/. This script
# is how that claim stays checkable, and how the package is moved to a newer
# kernel: bump UPSTREAM_TAG, run --rebase, fix any patch fuzz, retest.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

UPSTREAM_TAG="${UPSTREAM_TAG:-v6.19}"
UPSTREAM_SHA256="e4d5f9c4c148f1664bb1d4ae37c1095d9de42109907db71439f2f26f6519ea1c"
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
		warn "upstream sha256 changed: ${actual} (expected ${UPSTREAM_SHA256}); update UPSTREAM_SHA256"
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
	ok "src/ov5693.c rewritten from ${UPSTREAM_TAG} + patches/"
	exit 0
fi

if diff -u "${workdir}/ov5693.c" "${REPO_ROOT}/src/ov5693.c"; then
	ok "src/ov5693.c is exactly ${UPSTREAM_TAG} + patches/"
else
	die "src/ov5693.c has drifted from ${UPSTREAM_TAG} + patches/ (diff above)"
fi
