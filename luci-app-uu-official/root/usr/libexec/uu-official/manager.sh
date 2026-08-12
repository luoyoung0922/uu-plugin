#!/bin/sh

set -u

NAME="uu-official"
INSTALL_DIR="/usr/sbin/uu"
RUNTIME_DIR="/tmp/uu"
MONITOR="$INSTALL_DIR/uuplugin_monitor.sh"
MONITOR_CONFIG="$INSTALL_DIR/uuplugin_monitor.config"
PID_FILE="/var/run/uuplugin.pid"
MONITOR_API="http://router.uu.163.com/api/script/monitor?type=openwrt"
LOCK_DIR="/tmp/lock/uu-official.lock"

log() {
	logger -t "$NAME" -- "$*"
	printf '%s\n' "$*"
}

die() {
	log "ERROR: $*"
	exit 1
}

lock() {
	mkdir -p /tmp/lock
	mkdir "$LOCK_DIR" 2>/dev/null || die "another UU management operation is running"
	trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
}

fetch_stdout() {
	local url="$1"
	if command -v curl >/dev/null 2>&1; then
		curl -fL --connect-timeout 15 --max-time 60 -sS -k -H 'Accept:text/plain' "$url"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch --timeout=60 --no-check-certificate -O - "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -T 60 --no-check-certificate -qO- "$url"
	else
		return 127
	fi
}

fetch_file() {
	local url="$1" output="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fL --connect-timeout 15 --max-time 180 -sS -k "$url" -o "$output"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch --timeout=180 --no-check-certificate -O "$output" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -T 180 --no-check-certificate -qO "$output" "$url"
	else
		return 127
	fi
}

md5_file() {
	md5sum "$1" | awk '{print $1}'
}

valid_md5() {
	[ "${#1}" -eq 32 ] && ! printf '%s' "$1" | grep -q '[^0-9a-fA-F]'
}

resolve_download() {
	local api="$1" response url sum
	response="$(fetch_stdout "$api" | tr -d '\r')" || return 1
	url="${response%%,*}"
	response="${response#*,}"
	sum="${response%%,*}"
	case "$url" in
		http://*.netease.com/*|https://*.netease.com/*|http://*.163.com/*|https://*.163.com/*) ;;
		*) return 1 ;;
	esac
	valid_md5 "$sum" || return 1
	printf '%s\n%s\n' "$url" "$sum"
}

download_verified() {
	local api="$1" output="$2" info url expected actual tmp
	info="$(resolve_download "$api")" || die "official API returned an invalid download response"
	url="$(printf '%s\n' "$info" | sed -n '1p')"
	expected="$(printf '%s\n' "$info" | sed -n '2p')"
	tmp="${output}.download.$$"
	rm -f "$tmp"
	fetch_file "$url" "$tmp" || {
		rm -f "$tmp"
		die "download failed: $url"
	}
	actual="$(md5_file "$tmp")" || {
		rm -f "$tmp"
		die "cannot calculate MD5"
	}
	[ "$actual" = "$expected" ] || {
		rm -f "$tmp"
		die "MD5 mismatch; expected $expected, got $actual"
	}
	mv "$tmp" "$output"
}

detect_model() {
	case "$(uname -m 2>/dev/null)" in
		x86_64|amd64) echo x86_64 ;;
		aarch64|arm64) echo aarch64 ;;
		arm* ) echo arm ;;
		mips64el|mipsel*) echo mipsel ;;
		mips64|mips*) echo mipseb ;;
		*) return 1 ;;
	esac
}

normalize_model() {
	local requested="${1:-auto}"
	case "$requested" in
		auto|'') detect_model ;;
		x86_64|aarch64|arm|mipsel|mipseb) printf '%s\n' "$requested" ;;
		*) return 1 ;;
	esac
}

pid_cmdline() {
	[ -r "/proc/$1/cmdline" ] || return 1
	tr '\000' ' ' < "/proc/$1/cmdline"
}

runtime_pid() {
	local pid
	[ -s "$PID_FILE" ] || return 1
	pid="$(cat "$PID_FILE" 2>/dev/null)"
	case "$pid" in *[!0-9]*|'') return 1 ;; esac
	pid_cmdline "$pid" | grep -q '/tmp/uu/uuplugin' || return 1
	printf '%s\n' "$pid"
}

other_monitor_running() {
	local self="$$" pid cmd
	for proc in /proc/[0-9]*; do
		pid="${proc##*/}"
		[ "$pid" = "$self" ] && continue
		cmd="$(pid_cmdline "$pid" 2>/dev/null)" || continue
		case "$cmd" in
			*uuplugin_monitor.sh*) printf '%s\n' "$pid"; return 0 ;;
		esac
	done
	return 1
}

write_config() {
	local model="$1" tmp="${MONITOR_CONFIG}.tmp.$$"
	{
		echo 'router=openwrt'
		printf 'model=%s\n' "$model"
	} > "$tmp" || die "cannot write monitor configuration"
	chmod 0644 "$tmp"
	mv "$tmp" "$MONITOR_CONFIG"
}

update_monitor() {
	mkdir -p "$INSTALL_DIR" "$RUNTIME_DIR"
	download_verified "$MONITOR_API" "$MONITOR"
	chmod 0755 "$MONITOR"
	log "official monitor script updated"
}

prepare() {
	local model other
	lock
	model="$(normalize_model "${1:-auto}")" || die "unsupported architecture: $(uname -m 2>/dev/null)"
	other="$(other_monitor_running 2>/dev/null || true)"
	[ -z "$other" ] || die "another uuplugin monitor is already running (PID $other)"
	mkdir -p "$INSTALL_DIR" "$RUNTIME_DIR"
	[ -x "$MONITOR" ] || update_monitor
	write_config "$model"
	log "runtime prepared for $model"
}

stop_runtime() {
	local pid i
	pid="$(runtime_pid 2>/dev/null || true)"
	[ -n "$pid" ] || {
		rm -f "$PID_FILE"
		return 0
	}
	kill -TERM "$pid" 2>/dev/null || true
	i=0
	while [ "$i" -lt 15 ] && [ -d "/proc/$pid" ]; do
		sleep 1
		i=$((i + 1))
	done
	if [ -d "/proc/$pid" ]; then
		log "runtime did not stop after 15 seconds; sending KILL"
		kill -KILL "$pid" 2>/dev/null || true
	fi
	rm -f "$PID_FILE"
}

clean_runtime() {
	lock
	stop_runtime
	rm -rf "$RUNTIME_DIR"
	rm -f "$INSTALL_DIR/uu.tar.gz" "$INSTALL_DIR/uu.tar.gz.md5"
	mkdir -p "$RUNTIME_DIR"
	log "runtime cache removed"
}

status_text() {
	local pid model='unknown' monitor='missing'
	[ -r "$MONITOR_CONFIG" ] && model="$(sed -n 's/^model=//p' "$MONITOR_CONFIG" | head -n1)"
	[ -x "$MONITOR" ] && monitor='installed'
	pid="$(runtime_pid 2>/dev/null || true)"
	if [ -n "$pid" ]; then
		printf 'running\npid=%s\nmodel=%s\nmonitor=%s\n' "$pid" "$model" "$monitor"
	else
		printf 'stopped\npid=\nmodel=%s\nmonitor=%s\n' "$model" "$monitor"
	fi
}

case "${1:-}" in
	prepare) prepare "${2:-auto}" ;;
	update-monitor) lock; update_monitor ;;
	stop-runtime) stop_runtime ;;
	clean-runtime) clean_runtime ;;
	status) status_text ;;
	detect-model) detect_model ;;
	*)
		echo "Usage: $0 {prepare [model]|update-monitor|stop-runtime|clean-runtime|status|detect-model}" >&2
		exit 2
		;;
esac
