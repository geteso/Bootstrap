# shellcheck shell=bash

PHP_FPM_SERVICE=""
PHP_FPM_SOCKET=""

install_php() {
	log_step "PHP + extensions"
	pkg_install php-fpm php-cli php-mysql php-mbstring php-gd

	# Resolve the installed PHP-FPM version, service name, and socket path.
	if [ "${DRY_RUN:-0}" = "1" ]; then
		PHP_FPM_SERVICE="php8.x-fpm"
		PHP_FPM_SOCKET="/run/php/php8.x-fpm.sock"
		log_info "(dry-run) assuming PHP-FPM service $PHP_FPM_SERVICE / socket $PHP_FPM_SOCKET"
		return 0
	fi

	local ver
	ver="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)"
	[ -n "$ver" ] || die "PHP did not install correctly (php -v failed)."
	PHP_FPM_SERVICE="php${ver}-fpm"
	PHP_FPM_SOCKET="/run/php/php${ver}-fpm.sock"

	systemctl cat -- "${PHP_FPM_SERVICE}.service" >/dev/null 2>&1 \
		|| die "Expected service ${PHP_FPM_SERVICE} not found."
	svc_enable_now "$PHP_FPM_SERVICE"
	log_ok "PHP $ver installed; FPM socket: $PHP_FPM_SOCKET"
}

install_web_server() {
	log_step "Web server ($WEB_SERVER)"
	case "$WEB_SERVER" in
		nginx)
			pkg_install nginx
			svc_enable_now nginx
			;;
		apache)
			pkg_install apache2
			# php-fpm via proxy_fcgi: enable the needed modules.
			run "Enabling Apache modules (proxy_fcgi, setenvif, rewrite, ssl, headers)" \
				a2enmod proxy_fcgi setenvif rewrite ssl headers
			# php<ver>-fpm Apache conf is shipped by the libapache2 glue;
			# enabling it is handled in webserver.sh via the vhost.
			svc_enable_now apache2
			;;
		*) die "Unknown web server: $WEB_SERVER (expected nginx or apache)" ;;
	esac
}

install_database() {
	log_step "MariaDB"
	pkg_install mariadb-server mariadb-client
	svc_enable_now mariadb
}

install_certbot() {
	[ "${SKIP_SSL:-0}" = "1" ] && { log_info "Skipping certbot (--skip-ssl)"; return 0; }
	log_step "certbot"
	case "$WEB_SERVER" in
		nginx)  pkg_install certbot python3-certbot-nginx ;;
		apache) pkg_install certbot python3-certbot-apache ;;
	esac
}
