# shellcheck shell=bash

# _render <template> <dest> — substitute placeholders safely (values may
# contain slashes, so use a literal-safe replacement, not sed s///).
_render_vhost() {
	local tmpl="$1" dest="$2"
	if [ "${DRY_RUN:-0}" = "1" ]; then
		log_info "(dry-run) would render $tmpl -> $dest"
		log_info "          DOMAIN=$CFG_DOMAIN ROOT=$FORUM_ROOT PHP_SOCK=$PHP_FPM_SOCKET"
		return 0
	fi
	local content
	content="$(cat "$tmpl")"
	content="${content//__DOMAIN__/$CFG_DOMAIN}"
	content="${content//__ROOT__/$FORUM_ROOT}"
	content="${content//__PHP_SOCK__/$PHP_FPM_SOCKET}"
	printf '%s\n' "$content" >"$dest"
	log_ok "Wrote $dest"
}

configure_web_server() {
	log_step "Web server vhost ($WEB_SERVER)"
	case "$WEB_SERVER" in
		nginx)  _configure_nginx ;;
		apache) _configure_apache ;;
	esac
}

_configure_nginx() {
	local avail="/etc/nginx/sites-available/eso.conf"
	local enabled="/etc/nginx/sites-enabled/eso.conf"

	_render_vhost "$TEMPLATES_DIR/nginx.vhost.conf.tmpl" "$avail"
	run "Enabling site" ln -sfn "$avail" "$enabled"

	if [ -e /etc/nginx/sites-enabled/default ]; then
		run "Disabling nginx default site" rm -f /etc/nginx/sites-enabled/default
	fi

	run "Testing nginx configuration" nginx -t
	svc_reload nginx
}

_configure_apache() {
	local avail="/etc/apache2/sites-available/eso.conf"

	_render_vhost "$TEMPLATES_DIR/apache.vhost.conf.tmpl" "$avail"
	run "Enabling site" a2ensite eso.conf
	if [ -e /etc/apache2/sites-enabled/000-default.conf ]; then
		run "Disabling Apache default site" a2dissite 000-default.conf
	fi

	run "Testing Apache configuration" apache2ctl configtest
	svc_reload apache2
}
