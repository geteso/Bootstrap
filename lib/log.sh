# shellcheck shell=bash
# Sourced by setup.sh; relies on globals DRY_RUN and ASSUME_YES.

if [ -t 1 ]; then
	_C_RESET=$'\033[0m'; _C_RED=$'\033[31m'; _C_GREEN=$'\033[32m'
	_C_YELLOW=$'\033[33m'; _C_BLUE=$'\033[34m'; _C_BOLD=$'\033[1m'
else
	_C_RESET=''; _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_BLUE=''; _C_BOLD=''
fi

log_info()  { printf '%s[*]%s %s\n'  "$_C_BLUE"   "$_C_RESET" "$*"; }
log_ok()    { printf '%s[+]%s %s\n'  "$_C_GREEN"  "$_C_RESET" "$*"; }
log_warn()  { printf '%s[!]%s %s\n'  "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
log_error() { printf '%s[x]%s %s\n'  "$_C_RED"    "$_C_RESET" "$*" >&2; }
log_step()  { printf '\n%s== %s ==%s\n' "$_C_BOLD" "$*" "$_C_RESET"; }

die() { log_error "$*"; exit 1; }

# run "<human description>" cmd args...
run() {
	local desc="$1"; shift
	if [ "${DRY_RUN:-0}" = "1" ]; then
		printf '%s[dry-run]%s %s\n' "$_C_YELLOW" "$_C_RESET" "$desc"
		printf '          $ %s\n' "$*"
		return 0
	fi
	log_info "$desc"
	"$@"
}

# run_sh "<desc>" "<shell snippet>" — for pipelines/redirection.
run_sh() {
	local desc="$1" snippet="$2"
	if [ "${DRY_RUN:-0}" = "1" ]; then
		printf '%s[dry-run]%s %s\n' "$_C_YELLOW" "$_C_RESET" "$desc"
		printf '          $ %s\n' "$snippet"
		return 0
	fi
	log_info "$desc"
	bash -c "$snippet"
}

# confirm "<question>" — returns 0 to proceed. Auto-yes under --yes/--dry-run.
confirm() {
	local q="$1" ans
	if [ "${ASSUME_YES:-0}" = "1" ] || [ "${DRY_RUN:-0}" = "1" ]; then
		return 0
	fi
	printf '%s[?]%s %s [y/N] ' "$_C_YELLOW" "$_C_RESET" "$q"
	read -r ans
	case "$ans" in
		[yY] | [yY][eE][sS]) return 0 ;;
		*) return 1 ;;
	esac
}
