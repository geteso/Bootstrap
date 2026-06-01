# shellcheck shell=bash

setup_ssl() {
	if [ "${SKIP_SSL:-0}" = "1" ]; then
		log_warn "Skipping TLS (--skip-ssl). The forum will be served over plain HTTP."
		SCHEME="http"
		return 0
	fi

	log_step "TLS certificate (Let's Encrypt)"
	SCHEME="https"

	local email="$CFG_LE_EMAIL"
	[ -n "$email" ] || die "--le-email is required for Let's Encrypt."

	local plugin
	case "$WEB_SERVER" in
		nginx)  plugin="--nginx" ;;
		apache) plugin="--apache" ;;
	esac

	local staging=""
	[ "${CFG_LE_STAGING:-0}" = "1" ] && staging="--staging"

	# certbot is idempotent: with --keep-until-expiring it reuses a valid
	# cert; --redirect ensures the HTTP->HTTPS rule exists either way.
	run "Requesting/installing certificate for $CFG_DOMAIN" \
		certbot "$plugin" \
			-d "$CFG_DOMAIN" \
			--non-interactive --agree-tos \
			-m "$email" \
			--redirect --keep-until-expiring \
			$staging

	# Debian's certbot package installs a systemd timer for renewal; make
	# sure it's active.
	if [ "${DRY_RUN:-0}" = "1" ]; then
		log_info "(dry-run) would ensure certbot.timer is enabled for auto-renewal"
	elif systemctl list-unit-files 2>/dev/null | grep -q '^certbot\.timer'; then
		run "Ensuring certbot renewal timer is enabled" \
			systemctl enable --now certbot.timer
	fi

	log_ok "TLS configured for https://$CFG_DOMAIN/"
}
