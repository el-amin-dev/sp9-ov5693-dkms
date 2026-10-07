#!/usr/bin/env bash
# Package-manager abstraction for install.sh and uninstall.sh. Sourced, not run.
#
# Covers the four families that between them carry nearly every desktop distro:
#   apt     Debian, Ubuntu, Mint, Pop!_OS, ...
#   dnf     Fedora, RHEL, Alma, Rocky, ...
#   pacman  Arch, Manjaro, EndeavourOS, ...
#   zypper  openSUSE Tumbleweed / Leap, SLES
#
# Expects the caller to define ok, warn, die and need_sudo.
#
# Test hooks (all optional):
#   OS_RELEASE  os-release file to read          (default /etc/os-release)
#   PKG_DRYRUN_CMD  test hook: replaces the package manager in dry runs
#   PKG_FAMILY  skip detection, use this family ("none": install nothing)
#   KVER        kernel release                   (default uname -r)

PKG_KVER="${KVER:-$(uname -r)}"

# Map one os-release ID token to a family; nothing printed if unknown.
_family_of() {
	case "$1" in
	debian | ubuntu) echo apt ;;
	fedora | rhel | centos) echo dnf ;;
	arch) echo pacman ;;
	opensuse* | suse | sles) echo zypper ;;
	esac
}

# Print the family for this system, or return 1. ID wins over ID_LIKE, so a
# derivative that lists several parents still lands on its own family first.
detect_family() {
	if [[ -n ${PKG_FAMILY:-} ]]; then
		printf '%s\n' "${PKG_FAMILY}"
		return 0
	fi
	local file="${OS_RELEASE:-/etc/os-release}" ID="" ID_LIKE="" tok fam
	# os-release(5): /usr/lib/os-release is the fallback when /etc has none.
	[[ -r ${file} || -n ${OS_RELEASE:-} ]] || file=/usr/lib/os-release
	[[ -r ${file} ]] || return 1
	# Read just the two keys: os-release is shell syntax, but sourcing it would
	# clobber our own variables (NAME, VERSION, ...).
	ID="$(sed -n 's/^ID=//p' "${file}" | tr -d '"'\''')"
	ID_LIKE="$(sed -n 's/^ID_LIKE=//p' "${file}" | tr -d '"'\''')"
	for tok in ${ID} ${ID_LIKE}; do
		fam="$(_family_of "${tok}")"
		[[ -n ${fam} ]] && { printf '%s\n' "${fam}"; return 0; }
	done
	return 1
}

# Everything the pipeline needs, by the command it provides:
#   dkms + compiler        -> building the out-of-tree ov5693 module
#   python3 + PyGObject    -> surfacecam/, and the Gst bindings surfacecam.pipeline
#                             imports (gi.require_version("Gst", "1.0"))
#   gstreamer + plugins    -> pipewiresrc, videoconvert/videoscale, v4l2sink
#   pw-dump                -> locating the camera nodes
#   v4l-utils              -> v4l2-ctl, finding and inspecting the devices
#   psmisc                 -> fuser, how the bridge sees who has a camera open
#   libcamera tools        -> cam, used by the test scripts
deps_for() {
	case "$1" in
	apt)
		echo dkms build-essential \
			python3 python3-gi gir1.2-gstreamer-1.0 \
			gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
			gstreamer1.0-pipewire pipewire-bin \
			v4l-utils psmisc libcamera-tools
		;;
	dnf)
		echo dkms make gcc \
			python3 python3-gobject \
			gstreamer1 gstreamer1-plugins-base gstreamer1-plugins-good \
			pipewire-gstreamer pipewire-utils \
			v4l-utils psmisc libcamera-tools
		;;
	pacman)
		echo dkms base-devel \
			python python-gobject \
			gstreamer gst-plugins-base gst-plugins-good \
			gst-plugin-pipewire pipewire \
			v4l-utils psmisc libcamera-tools
		;;
	zypper)
		echo dkms make gcc \
			python3 python3-gobject typelib-1_0-Gst-1_0 \
			gstreamer gstreamer-plugins-base gstreamer-plugins-good \
			gstreamer-plugin-pipewire pipewire-tools \
			v4l-utils psmisc libcamera-cam
		;;
	*) return 1 ;;
	esac
}

# openSUSE kernel flavour: 6.11.0-1-default -> default, ...-longterm -> longterm.
_suse_flavor() {
	case "${PKG_KVER##*-}" in
	default | longterm | rt | kvmsmall | 64kb) echo "${PKG_KVER##*-}" ;;
	*) echo default ;;
	esac
}

# The v4l2loopback module and its utilities. Kept separate because uninstall.sh
# removes exactly these and nothing else.
loopback_pkgs() {
	case "$1" in
	apt | pacman) echo v4l2loopback-dkms v4l2loopback-utils ;;
	# RPM Fusion: akmod rebuilds the module itself on every kernel update.
	dnf) echo akmod-v4l2loopback v4l2loopback ;;
	# The KMP is built per kernel flavour, like the headers.
	zypper) echo "v4l2loopback-kmp-$(_suse_flavor) v4l2loopback-utils" ;;
	*) return 1 ;;
	esac
}

# loopback_pkgs plus whatever was built from them on this machine: akmods turns
# akmod-v4l2loopback into one kmod-v4l2loopback-<kver> RPM per kernel, and those
# go with it -- otherwise they count as unexpected removals and block teardown.
loopback_installed() {
	loopback_pkgs "$1" || return 1
	[[ $1 == dnf ]] && rpm -qa --qf '%{NAME}\n' 'kmod-v4l2loopback*' 2>/dev/null | sort -u
	return 0
}

# Headers for the RUNNING kernel, named after the package that owns it, so a
# linux-surface, -lts or -zen kernel gets its own headers, not the stock ones.
headers_pkg() {
	local name
	case "$1" in
	apt) echo "linux-headers-${PKG_KVER}" ;;
	dnf)
		# kernel-core -> kernel-devel, kernel-surface -> kernel-surface-devel.
		name="$(rpm -qf --qf '%{NAME}' "/lib/modules/${PKG_KVER}/vmlinuz" 2>/dev/null)" || name=""
		name="${name%-core}"
		echo "${name:-kernel}-devel-${PKG_KVER}"
		;;
	pacman)
		name="$(pacman -Qqo "/usr/lib/modules/${PKG_KVER}/vmlinuz" 2>/dev/null)" || name=""
		echo "${name:-linux}-headers"
		;;
	zypper) echo "kernel-$(_suse_flavor)-devel" ;;
	*) return 1 ;;
	esac
}

# dnf only: akmods requires kernel-devel-matched, and the stock one requires the
# stock kernel-core -- on a linux-surface system dnf would satisfy that by
# installing a second, stock kernel. Naming the running kernel's own
# -devel-matched in the same transaction stops that. It is pinned to the running
# kernel's exact version: unversioned, dnf picks the newest, which requires
# (and so installs) a newer kernel. Empty for the stock kernel.
headers_matched_pkg() {
	local name
	[[ $1 == dnf ]] || return 0
	name="$(rpm -qf --qf '%{NAME}' "/lib/modules/${PKG_KVER}/vmlinuz" 2>/dev/null)" || return 0
	name="${name%-core}"
	[[ -n ${name} && ${name} != kernel ]] && echo "${name}-devel-matched-${PKG_KVER}"
	return 0
}

pkg_installed() {
	case "$1" in
	apt) dpkg -l "$2" 2>/dev/null | grep -q '^ii' ;;
	dnf | zypper) rpm -q "$2" >/dev/null 2>&1 ;;
	pacman) pacman -Q "$2" >/dev/null 2>&1 ;;
	esac
}

_pkg_bin() {
	case "$1" in
	apt) echo apt-get ;;
	*) echo "$1" ;;
	esac
}

# How many packages a dry run of "$1 install|remove pkgs..." would remove.
# Prints the count; returns 1 if the dry run failed or its output was not
# recognised. That must fail closed: a parser that silently reads 0 is a guard
# that lets the package manager take whatever it likes.
#
# Every dry run is forced into the C locale, because the parsers match English
# text -- a German dnf says "Transaktionszusammenfassung", not "Transaction Summary".
_pkg_removals() {
	local fam=$1 op=$2 out
	shift 2
	local LC_ALL=C LANG=C LANGUAGE=C
	export LC_ALL LANG LANGUAGE
	case "${fam}" in
	apt)
		out="$(${PKG_DRYRUN_CMD:-apt-get} -s "${op}" "$@" 2>/dev/null)" || return 1
		grep -c '^Remv' <<<"${out}" || true
		;;
	dnf)
		# --assumeno always exits non-zero; judge by the summary instead. Matches
		# both dnf5 (" Removing:  3 packages") and dnf4 ("Remove  3 Packages").
		# No autoremove: "unused" dependencies are not ours to judge.
		out="$(${PKG_DRYRUN_CMD:-dnf} "${op}" --assumeno --setopt=clean_requirements_on_remove=False "$@" 2>&1)" || true
		grep -qE 'Transaction Summary|Nothing to do' <<<"${out}" || return 1
		sed -nE 's/^ *Remov(e|ing):? +([0-9]+) [Pp]ackages?.*/\2/p' <<<"${out}" | head -1 | grep . || echo 0
		;;
	zypper)
		out="$(${PKG_DRYRUN_CMD:-sudo LC_ALL=C zypper} --non-interactive "${op}" --dry-run "$@" 2>&1)" || return 1
		# A summary we recognise, or nothing at all to do; anything else is unknown.
		grep -qE 'going to be|Nothing to do' <<<"${out}" || return 1
		if grep -q 'going to be REMOVED' <<<"${out}"; then
			# "The following 3 packages are ..." -- the count is absent when it is 1.
			sed -nE 's/^The following ([0-9]+) .*going to be REMOVED.*/\1/p' <<<"${out}" | head -1 | grep . || echo 1
		else
			echo 0
		fi
		;;
	pacman)
		if [[ ${op} == install ]]; then
			# pacman never removes on -S without asking, and --noconfirm answers
			# its conflict prompt with the default "N". Only check resolution.
			${PKG_DRYRUN_CMD:-pacman} -Sp --needed "$@" >/dev/null 2>&1 || return 1
			echo 0
		else
			out="$(${PKG_DRYRUN_CMD:-pacman} -Rp "$@" 2>/dev/null)" || return 1
			grep -c . <<<"${out}" || true
		fi
		;;
	esac
}

# Install what is missing, but never at the cost of removing anything: pulling
# the wrong package can take a desktop with it, so a non-empty removal list is a
# hard stop rather than a prompt.
pkg_install() {
	local fam=$1 missing=() removals p bin
	shift
	bin="$(_pkg_bin "${fam}")"
	command -v "${bin}" >/dev/null || die "${bin} not found, though this looks like a ${fam} system"
	for p in "$@"; do
		pkg_installed "${fam}" "${p}" || missing+=("${p}")
	done
	[[ ${#missing[@]} -eq 0 ]] && { ok "already present: $*"; return 0; }

	need_sudo "install ${missing[*]}"
	removals="$(_pkg_removals "${fam}" install "${missing[@]}")" ||
		die "${fam} cannot resolve: ${missing[*]}
       missing repository (see README), stale package database, or a running kernel
       older than the installed one (reboot into the newest kernel, then re-run)"
	[[ ${removals:-0} -eq 0 ]] ||
		die "${fam} would REMOVE ${removals} package(s) to install ${missing[*]}; refusing"

	case "${fam}" in
	# --no-remove: apt itself aborts on any removal, so the guard holds even if
	# the package lists changed between the dry run and this call.
	apt) sudo apt-get install -y --no-remove "${missing[@]}" ;;
	dnf) sudo dnf install -y "${missing[@]}" ;;
	zypper) sudo zypper --non-interactive install "${missing[@]}" ;;
	pacman) sudo pacman -S --needed --noconfirm "${missing[@]}" ;;
	esac || die "package install failed: ${missing[*]}"
	ok "installed ${missing[*]}"
}

# Remove exactly these packages; skip (warn, not die) if the package manager
# wants to take anything more with them. Teardown should never be fatal.
pkg_remove() {
	local fam=$1 present=() removals p
	shift
	for p in "$@"; do
		pkg_installed "${fam}" "${p}" && present+=("${p}")
	done
	[[ ${#present[@]} -eq 0 ]] && { ok "none of $* installed"; return 0; }

	need_sudo "remove ${present[*]}"
	removals="$(_pkg_removals "${fam}" remove "${present[@]}")" || removals=""
	if [[ -z ${removals} || ${removals} -gt ${#present[@]} ]]; then
		warn "${fam} would remove ${removals:-an unknown number of} packages, more than the ${#present[@]} we installed; skipping"
		warn "inspect by hand: ${fam} remove ${present[*]}"
		return 0
	fi
	case "${fam}" in
	apt) sudo apt-get remove -y "${present[@]}" ;;
	dnf) sudo dnf remove -y --setopt=clean_requirements_on_remove=False "${present[@]}" ;;
	zypper) sudo zypper --non-interactive remove "${present[@]}" ;;
	pacman) sudo pacman -R --noconfirm "${present[@]}" ;;
	esac || warn "package removal reported an error"
}

# dnf only: v4l2loopback lives in RPM Fusion. Enabling a third-party repository
# is the user's call, so say how and stop rather than doing it for them.
ensure_rpmfusion() {
	grep -q '^rpmfusion-free' <<<"$(dnf repolist 2>/dev/null)" && return 0
	die "v4l2loopback needs RPM Fusion (free). Enable it, then re-run:
       sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-\$(rpm -E %fedora).noarch.rpm
       (RHEL/Alma/Rocky: enable EPEL first, then use the 'el' release from rpmfusion.org)"
}

# What an unsupported distro has to provide by hand.
manual_needs() {
	cat <<-'EOF'
		unsupported distribution. Install the equivalents of these yourself, then
		re-run as `PKG_FAMILY=none ./install.sh` to skip the package step -- or set
		PKG_FAMILY to the closest of apt|dnf|pacman|zypper. For reference,
		`PKG_FAMILY=dnf ./install.sh --print-deps` shows one family's names.
		  dkms, a C compiler and make, headers for the running kernel
		  python3 with PyGObject and the Gst-1.0 typelib
		  GStreamer with base, good and pipewire plugins (pipewiresrc, v4l2sink)
		  pw-dump, v4l2-ctl, fuser, libcamera's cam
		  the v4l2loopback kernel module
	EOF
}
