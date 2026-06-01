# shellcheck shell=bash

# Populated for the final summary / seed file.
DB_NAME=""
DB_USER=""
DB_PASS=""
DB_HOST="localhost"

_mysql_root() {
	# All admin SQL goes through here.
	mysql --protocol=socket -u root "$@"
}

_gen_password() {
	# 24 chars, alphanumeric only — avoids SQL/shell quoting hazards.
	# `tr </dev/urandom | head` makes tr take SIGPIPE; the trailing
	# `|| true` keeps that from tripping `set -e`/pipefail.
	local p
	p="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true)"
	[ "${#p}" -ge 24 ] || die "Failed to generate a database password."
	printf '%s' "$p"
}

_gen_db_ident() {
	# <prefix>_<8 lowercase alphanumeric chars> — short, readable in
	# admin tools, free of MySQL identifier-quoting headaches, and yields
	# ~36 bits of randomness (plenty to avoid collisions between forums
	# on one host).
	local prefix="$1"
	local s
	s="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8 || true)"
	[ "${#s}" -ge 8 ] || die "Failed to generate a DB identifier."
	printf '%s_%s' "$prefix" "$s"
}

setup_database() {
	log_step "Database (MariaDB)"

	if [ -n "${CFG_DB_NAME:-}" ]; then
		DB_NAME="$CFG_DB_NAME"
	else
		DB_NAME="$(_gen_db_ident esodb)"
		log_info "Generated database name: $DB_NAME"
	fi
	if [ -n "${CFG_DB_USER:-}" ]; then
		DB_USER="$CFG_DB_USER"
	else
		DB_USER="$(_gen_db_ident esouser)"
		log_info "Generated database user: $DB_USER"
	fi
	DB_HOST="${CFG_DB_HOST:-localhost}"

	[[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "Invalid DB name '$DB_NAME' (use letters, digits, underscore)."
	[[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || die "Invalid DB user '$DB_USER' (use letters, digits, underscore)."

	if [ -n "${CFG_DB_PASS:-}" ]; then
		case "$CFG_DB_PASS" in
			*\'* | *\\*) die "DB password must not contain single quotes or backslashes." ;;
		esac
		DB_PASS="$CFG_DB_PASS"
	else
		DB_PASS="$(_gen_password)"
		log_info "Generated a random database password (shown in the final summary)."
	fi

	if [ "${DRY_RUN:-0}" = "1" ]; then
		log_info "(dry-run) would create database '$DB_NAME' and user '$DB_USER'@'$DB_HOST'"
		return 0
	fi

	# Sanity-check root access before doing anything.
	_mysql_root -e "SELECT 1;" >/dev/null 2>&1 \
		|| die "Cannot connect to MariaDB as root via socket. Is mariadb running?"

	local sql
	sql="$(cat <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${DB_HOST}';
FLUSH PRIVILEGES;
SQL
)"
	log_info "Creating database '$DB_NAME' and user '$DB_USER'@'$DB_HOST'"
	printf '%s\n' "$sql" | _mysql_root \
		|| die "Database/user creation failed."

	# Verify the credentials actually work end-to-end.
	mysql --protocol=socket -u "$DB_USER" -p"$DB_PASS" -e "USE \`${DB_NAME}\`; SELECT 1;" >/dev/null 2>&1 \
		|| die "Created the DB user but could not authenticate with it."
	log_ok "Database ready and credentials verified."
}
