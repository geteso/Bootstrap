#!/usr/bin/env bash
#
# esoBB Bootstrap — automated server provisioning for an esoBB forum.
#
# Usage:
#   sudo ./setup.sh --source /path/to/esoBB \
#                     --domain forum.example.com \
#                     --le-email you@example.com
#   sudo ./setup.sh --config myforum.conf
#   sudo ./setup.sh --config setup.conf.example --dry-run
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

# --- defaults / globals shared with the lib modules -----------------------
DRY_RUN=0
ASSUME_YES=0
SKIP_SSL=0
REFRESH_SOURCE=0
WEB_SERVER="nginx"
SCHEME="https"

CFG_DOMAIN=""
CFG_FORUM_ROOT=""
CFG_SOURCE=""
CFG_DB_NAME=""
CFG_DB_USER=""
CFG_DB_PASS=""
CFG_DB_HOST="localhost"
CFG_LE_EMAIL=""
CFG_LE_STAGING=0

# shellcheck source=lib/log.sh
. "$LIB_DIR/log.sh"
# shellcheck source=lib/distro.sh
. "$LIB_DIR/distro.sh"
# shellcheck source=lib/packages.sh
. "$LIB_DIR/packages.sh"
# shellcheck source=lib/database.sh
. "$LIB_DIR/database.sh"
# shellcheck source=lib/deploy.sh
. "$LIB_DIR/deploy.sh"
# shellcheck source=lib/webserver.sh
. "$LIB_DIR/webserver.sh"
# shellcheck source=lib/ssl.sh
. "$LIB_DIR/ssl.sh"
# shellcheck source=lib/seed.sh
. "$LIB_DIR/seed.sh"

usage() {
	cat <<'EOF'
esoBB Bootstrap — provisions a server for an esoBB forum.

Required:
  --source <path-or-url>   Local path to an esoBB checkout (with index.php
                           + install/), OR a direct http(s):// link to a
                           .tar.gz / .tgz / .zip archive of the source.
                           Settable as CFG_SOURCE in a config file.
  --domain <fqdn>          Domain the forum will be served from
  --forum-root <path>      Absolute path to the document root
                           (e.g. /var/www/eso)
  --le-email <email>       Email registered with Let's Encrypt. Required
                           unless --skip-ssl is set.

Optional:
  --config <file>          Load settings from a config file (KEY=VALUE)
  --web-server <nginx|apache>   Default: nginx
  --db-name <name>         Default: auto-generated as esodb_<random>
  --db-user <name>         Default: auto-generated as esouser_<random>
  --db-pass <pass>         Default: randomly generated
  --le-staging             Use the Let's Encrypt staging environment
  --skip-ssl               Serve over plain HTTP (no certbot)
  --refresh-source         Force re-download even if the source cache is
                           populated (only meaningful when --source is a URL)
  --dry-run                Print every action; change nothing
  --yes                    Don't prompt for confirmation
  -h, --help               Show this help

Flags override values loaded from --config.

Note: when --source is an http(s):// URL, the archive is fetched over
HTTPS but esoBB does not publish signed releases, so authenticity is
only as strong as the host's account/repo security. For high-assurance
installs, pre-stage the source and pass a local path.

Placeholders: any flag value (except --source and --domain) may include
<Nrand> tokens, each replaced with N lowercase alphanumeric chars (1..64;
<rand> alone means 8). Example: --db-name "myforum_<8rand>".
EOF
}

_RAND_TOKEN_RE='<([0-9]*)rand>'

# Expand every <Nrand> token in the given string with an independent run
# of N lowercase alphanumeric characters. <rand> with no number means 8.
# N must be 1..64. Returns the expanded string on stdout.
_expand_rand() {
	local s="$1"
	while [[ "$s" =~ $_RAND_TOKEN_RE ]]; do
		local match="${BASH_REMATCH[0]}"
		local n="${BASH_REMATCH[1]:-8}"
		# shellcheck disable=SC2086
		if [ "$n" -lt 1 ] || [ "$n" -gt 64 ]; then
			die "Random-token width must be 1..64 (got <${BASH_REMATCH[1]}rand>)."
		fi
		local r
		r="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c "$n" || true)"
		[ "${#r}" -eq "$n" ] || die "Failed to generate <${n}rand> characters."
		# Replace only the first occurrence per iteration.
		s="${s/$match/$r}"
	done
	printf '%s' "$s"
}

# Expand <Nrand> tokens in templatable CFG_* variables.
_expand_rand_inputs() {
	local var val expanded
	for var in CFG_FORUM_ROOT \
	           CFG_DB_NAME CFG_DB_USER CFG_DB_PASS CFG_LE_EMAIL; do
		val="${!var}"
		[ -n "$val" ] || continue
		[[ "$val" =~ $_RAND_TOKEN_RE ]] || continue
		expanded="$(_expand_rand "$val")"
		printf -v "$var" '%s' "$expanded"
	done
}

load_config() {
	local f="$1"
	[ -f "$f" ] || die "Config file not found: $f"
	# The config file is a trusted, admin-owned shell snippet of CFG_*
	# assignments.
	# shellcheck disable=SC1090
	. "$f"
	log_ok "Loaded config: $f"
}

parse_args() {
	# First pass: pick up --config so flags can override it.
	local args=("$@") i
	for ((i = 0; i < ${#args[@]}; i++)); do
		if [ "${args[$i]}" = "--config" ]; then
			load_config "${args[$((i + 1))]}"
		fi
	done

	while [ $# -gt 0 ]; do
		case "$1" in
			--config)            shift 2 ;;
			--source)            CFG_SOURCE="$2"; shift 2 ;;
			--domain)            CFG_DOMAIN="$2"; shift 2 ;;
			--forum-root)        CFG_FORUM_ROOT="$2"; shift 2 ;;
			--web-server)        WEB_SERVER="$2"; shift 2 ;;
			--db-name)           CFG_DB_NAME="$2"; shift 2 ;;
			--db-user)           CFG_DB_USER="$2"; shift 2 ;;
			--db-pass)           CFG_DB_PASS="$2"; shift 2 ;;
			--le-email)          CFG_LE_EMAIL="$2"; shift 2 ;;
			--le-staging)        CFG_LE_STAGING=1; shift ;;
			--skip-ssl)          SKIP_SSL=1; shift ;;
			--refresh-source)    REFRESH_SOURCE=1; shift ;;
			--dry-run)           DRY_RUN=1; shift ;;
			--yes | -y)          ASSUME_YES=1; shift ;;
			-h | --help)         usage; exit 0 ;;
			*) die "Unknown argument: $1 (try --help)" ;;
		esac
	done
}

validate_inputs() {
	case "$WEB_SERVER" in
		nginx | apache) ;;
		*) die "--web-server must be 'nginx' or 'apache' (got '$WEB_SERVER')" ;;
	esac

	# Prompt for required values if a TTY is available; otherwise fail.
	if [ -z "$CFG_SOURCE" ]; then
		if [ -t 0 ] && [ "$DRY_RUN" = "0" ]; then
			printf 'esoBB source (path or http(s):// archive URL): '; read -r CFG_SOURCE
		fi
		[ -n "$CFG_SOURCE" ] \
			|| die "--source is required (a local path or an http(s):// archive URL)."
	fi
	if [ -z "$CFG_DOMAIN" ]; then
		if [ -t 0 ] && [ "$DRY_RUN" = "0" ]; then
			printf 'Domain (FQDN) for the forum: '; read -r CFG_DOMAIN
		fi
		[ -n "$CFG_DOMAIN" ] || die "--domain is required."
	fi
	# --le-email is required when TLS is on (certbot registers it with
	# Let's Encrypt). With --skip-ssl it's unused.
	if [ "${SKIP_SSL:-0}" = "0" ] && [ -z "$CFG_LE_EMAIL" ]; then
		if [ -t 0 ] && [ "$DRY_RUN" = "0" ]; then
			printf 'Email for Let'"'"'s Encrypt registration: '
			read -r CFG_LE_EMAIL
		fi
		[ -n "$CFG_LE_EMAIL" ] \
			|| die "--le-email is required when TLS is enabled (or pass --skip-ssl)."
	fi
	if [ -z "$CFG_FORUM_ROOT" ]; then
		if [ -t 0 ] && [ "$DRY_RUN" = "0" ]; then
			printf 'Forum document root (absolute path, e.g. /var/www/eso): '
			read -r CFG_FORUM_ROOT
		fi
		[ -n "$CFG_FORUM_ROOT" ] || die "--forum-root is required."
	fi

	# Expand <Nrand> placeholders before any further validation so the
	# expanded values are what get checked.
	_expand_rand_inputs

	[[ "$CFG_FORUM_ROOT" == /* ]] \
		|| die "--forum-root must be an absolute path (got '$CFG_FORUM_ROOT')."

	[[ "$CFG_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] \
		|| die "Domain '$CFG_DOMAIN' looks invalid."
	[ -z "$CFG_LE_EMAIL" ] \
		|| [[ "$CFG_LE_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
		|| die "Let's Encrypt email '$CFG_LE_EMAIL' looks invalid."
}

require_root() {
	[ "${DRY_RUN:-0}" = "1" ] && return 0
	[ "$(id -u)" -eq 0 ] || die "This script must run as root (use sudo)."
}

print_summary() {
	cat <<EOF

$_C_BOLD========================================================$_C_RESET
$_C_GREEN esoBB Bootstrap complete$_C_RESET
$_C_BOLD========================================================$_C_RESET

  Forum root : $FORUM_ROOT
  Web server : $WEB_SERVER
  URL        : ${SCHEME}://${CFG_DOMAIN}/

  Database
    host     : $DB_HOST
    name     : $DB_NAME
    user     : $DB_USER
    password : $DB_PASS
  $_C_YELLOW(Store the database password now — it is not shown again.)$_C_RESET

  Next step: open the installer and finish in your browser —
  every field is pre-filled except the admin password:

    $_C_BOLD${INSTALLER_URL}$_C_RESET

  After you click through, esoBB writes config/config.php and a
  lock file; the seed (with the DB password) auto-deletes.
EOF
}

main() {
	parse_args "$@"
	validate_inputs
	require_root

	log_step "esoBB Bootstrap"
	log_info "Domain=$CFG_DOMAIN  WebServer=$WEB_SERVER  Root=$CFG_FORUM_ROOT  DryRun=$DRY_RUN"
	if ! confirm "Proceed with provisioning on this host?"; then
		die "Aborted by user."
	fi

	detect_distro
	install_php
	install_web_server
	install_database
	install_certbot
	deploy_forum
	setup_database
	configure_web_server
	setup_ssl
	write_seed

	print_summary
}

main "$@"
