# shellcheck shell=bash

FORUM_ROOT=""

# Set by _fetch_source so deploy_forum can pick up the extracted path
FETCHED_SOURCE=""

_SOURCE_CACHE_ROOT="/var/cache/esoBB-bootstrap"
_SOURCE_CACHE_DIR="$_SOURCE_CACHE_ROOT/source"

# Directories the installer checks for write access
_WRITABLE_DIRS=(. avatars plugins skins config install upgrade sessions)

# Download and extract an esoBB tarball or zip into the cache dir.
_fetch_source() {
	local url="$1"
	local ext
	case "$url" in
		*.tar.gz | *.tgz) ext="tar.gz" ;;
		*.zip)            ext="zip" ;;
		*) die "Unsupported archive type for $url (expected .tar.gz / .tgz / .zip)." ;;
	esac

	# Reuse a valid cache unless the user asked for a refresh.
	if [ "${REFRESH_SOURCE:-0}" != "1" ] \
		&& [ -f "$_SOURCE_CACHE_DIR/index.php" ] \
		&& [ -d "$_SOURCE_CACHE_DIR/install" ]; then
		log_ok "Reusing cached source at $_SOURCE_CACHE_DIR (pass --refresh-source to re-download)"
		FETCHED_SOURCE="$_SOURCE_CACHE_DIR"
		return 0
	fi

	pkg_install ca-certificates curl tar
	[ "$ext" = "zip" ] && pkg_install unzip

	if [ "${DRY_RUN:-0}" = "1" ]; then
		log_info "(dry-run) would download $url -> $_SOURCE_CACHE_DIR ($ext)"
		FETCHED_SOURCE="$_SOURCE_CACHE_DIR"
		return 0
	fi

	run "Creating source cache: $_SOURCE_CACHE_ROOT" mkdir -p "$_SOURCE_CACHE_ROOT"

	local archive="$_SOURCE_CACHE_ROOT/download.$ext"
	local tmp="$_SOURCE_CACHE_DIR.tmp"

	run "Downloading $url" curl -fsSL "$url" -o "$archive"
	rm -rf "$tmp"
	mkdir -p "$tmp"

	if [ "$ext" = "zip" ]; then
		run "Extracting zip" unzip -q "$archive" -d "$tmp"
		local entries inner
		# shellcheck disable=SC2207
		entries=( $(find "$tmp" -mindepth 1 -maxdepth 1) )
		if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
			inner="${entries[0]}"
			find "$inner" -mindepth 1 -maxdepth 1 -exec mv {} "$tmp"/ \;
			rmdir "$inner"
		fi
	else
		run "Extracting tarball" tar -xzf "$archive" -C "$tmp" --strip-components=1
	fi

	rm -rf "$_SOURCE_CACHE_DIR"
	mv "$tmp" "$_SOURCE_CACHE_DIR"
	rm -f "$archive"

	[ -f "$_SOURCE_CACHE_DIR/index.php" ] && [ -d "$_SOURCE_CACHE_DIR/install" ] \
		|| die "Extracted archive doesn't look like an esoBB source (missing index.php or install/)."

	log_ok "Source extracted to $_SOURCE_CACHE_DIR"
	FETCHED_SOURCE="$_SOURCE_CACHE_DIR"
}

deploy_forum() {
	log_step "Deploy esoBB files"

	local src
	if [[ "${CFG_SOURCE:-}" =~ ^https?:// ]]; then
		_fetch_source "$CFG_SOURCE"
		src="$FETCHED_SOURCE"
	elif [ -n "${CFG_SOURCE:-}" ]; then
		src="$(cd "$CFG_SOURCE" 2>/dev/null && pwd)" \
			|| die "Source path does not exist: $CFG_SOURCE"
	else
		die "--source is required (a local path or an http(s):// archive URL)."
	fi

	# under --dry-run the cache may not exist yet, so skip.
	if [ "${DRY_RUN:-0}" = "0" ]; then
		[ -f "$src/index.php" ] && [ -d "$src/install" ] \
			|| die "esoBB source not found at $src (expected index.php + install/)."
	fi

	FORUM_ROOT="$CFG_FORUM_ROOT"

	if [ -f "$FORUM_ROOT/config/config.php" ]; then
		die "$FORUM_ROOT/config/config.php already exists — refusing to clobber an installed forum."
	fi
	if [ -f "$FORUM_ROOT/install/lock" ]; then
		die "$FORUM_ROOT/install/lock exists — this forum appears already installed."
	fi

	if [ "$src" = "$FORUM_ROOT" ]; then
		log_info "Source and target are the same path; skipping copy."
	else
		run "Creating document root $FORUM_ROOT" mkdir -p "$FORUM_ROOT"
		# Copy everything except VCS metadata and this tooling folder.
		run "Copying forum files to $FORUM_ROOT" \
			rsync -a --delete \
				--exclude '.git' --exclude '.git/' \
				--exclude 'Bootstrap' --exclude 'eso_script' \
				"$src"/ "$FORUM_ROOT"/
	fi

	local d
	for d in "${_WRITABLE_DIRS[@]}"; do
		run "Ensuring directory exists: $FORUM_ROOT/$d" mkdir -p "$FORUM_ROOT/$d"
	done

	run "Setting ownership to ${WEB_USER}:${WEB_USER}" \
		chown -R "${WEB_USER}:${WEB_USER}" "$FORUM_ROOT"

	# Baseline: files 644, dirs 755.
	run "Normalizing file permissions" \
		find "$FORUM_ROOT" -type f -exec chmod 644 {} +
	run "Normalizing directory permissions" \
		find "$FORUM_ROOT" -type d -exec chmod 755 {} +

	for d in "${_WRITABLE_DIRS[@]}"; do
		run "Making writable: $FORUM_ROOT/$d" chmod 775 "$FORUM_ROOT/$d"
	done

	log_ok "Forum deployed at $FORUM_ROOT"
}
