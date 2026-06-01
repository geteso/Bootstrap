# shellcheck shell=bash
# OS detection and a thin abstraction layer over the package manager and
# service manager. Only the apt (Debian/Ubuntu) backend is implemented;
# other families are detected and rejected with a clear message so the
# abstraction can be extended later without touching callers.

DISTRO_FAMILY=""   # debian | rhel | unknown
DISTRO_ID=""       # ubuntu | debian | ...
WEB_USER=""        # www-data | apache | ...

detect_distro() {
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		DISTRO_ID="${ID:-unknown}"
		case " ${ID:-} ${ID_LIKE:-} " in
			*" debian "* | *" ubuntu "*) DISTRO_FAMILY="debian" ;;
			*" rhel "* | *" fedora "* | *" centos "*) DISTRO_FAMILY="rhel" ;;
			*) DISTRO_FAMILY="unknown" ;;
		esac
	else
		DISTRO_FAMILY="unknown"
	fi

	# Under --dry-run we only print an action plan, so a non-target OS is
	# fine for previewing; assume the Debian backend.
	if [ "$DISTRO_FAMILY" != "debian" ] && [ "${DRY_RUN:-0}" = "1" ]; then
		log_warn "Non-Debian/undetectable OS (${DISTRO_ID:-unknown}); continuing for --dry-run preview only."
		DISTRO_FAMILY="debian"
	fi

	case "$DISTRO_FAMILY" in
		debian) WEB_USER="www-data" ;;
		rhel)
			die "RHEL/Fedora family detected ($DISTRO_ID). Only Debian/Ubuntu (apt) is supported right now."
			;;
		*)
			die "Unsupported or undetectable OS. Only Debian/Ubuntu (apt) is supported right now."
			;;
	esac
	log_ok "Detected $DISTRO_ID (family: $DISTRO_FAMILY); web user: $WEB_USER"
}

# --- package manager abstraction ------------------------------------------

_apt_updated=0

pkg_refresh() {
	[ "$_apt_updated" = "1" ] && return 0
	run "Refreshing apt package index" env DEBIAN_FRONTEND=noninteractive apt-get update -y --allow-releaseinfo-change
	_apt_updated=1
}

# pkg_installed <pkg> -> 0 if installed
pkg_installed() {
	dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

# pkg_install <pkg...> — installs only the packages not already present.
pkg_install() {
	local missing=()
	local p
	for p in "$@"; do
		if pkg_installed "$p"; then
			log_ok "$p already installed"
		else
			missing+=("$p")
		fi
	done
	[ "${#missing[@]}" -eq 0 ] && return 0
	pkg_refresh
	run "Installing: ${missing[*]}" \
		env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

# --- service manager abstraction ------------------------------------------

svc_enable_now() {
	run "Enabling and starting service: $1" systemctl enable --now "$1"
}

svc_reload() {
	run "Reloading service: $1" systemctl reload "$1"
}

svc_restart() {
	run "Restarting service: $1" systemctl restart "$1"
}
