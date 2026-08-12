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
	local pid model='unknown' monitor='missing' enabled='0'
	[ -r "$MONITOR_CONFIG" ] && model="$(sed -n 's/^model=//p' "$MONITOR_CONFIG" | head -n1)"
	[ -x "$MONITOR" ] && monitor='installed'
	enabled="$(uci -q get uu-official.main.enabled 2>/dev/null || echo 0)"
	pid="$(runtime_pid 2>/dev/null || true)"
	if [ -n "$pid" ]; then
		printf 'running\nenabled=%s\npid=%s\nmodel=%s\nmonitor=%s\n' "$enabled" "$pid" "$model" "$monitor"
	else
		printf 'stopped\nenabled=%s\npid=\nmodel=%s\nmonitor=%s\n' "$enabled" "$model" "$monitor"
	fi
}

device_status() {
	local status_file="${RUNTIME_DIR}/activate_status" ip line latency name mac uuid router_mac reason=''
	printf 'source=%s\n' "$status_file"
	[ -r "$status_file" ] || { printf 'count=0\nreason=activation_state_missing\n'; return 0; }
	# The official file is commonly: MAC.UUID. Resolve the MAC through the neighbour table.
	printf '%s\n' '---'
	router_mac="$(ip link show br-lan 2>/dev/null | sed -n 's/.*link\/ether \([^ ]*\).*/\1/p' | tr 'A-F' 'a-f')"
	while IFS= read -r line; do
		mac="$(printf '%s\n' "$line" | sed -n 's/^\([0-9A-Fa-f:][0-9A-Fa-f:]*\)\..*/\1/p' | tr 'A-F' 'a-f')"
		[ -n "$mac" ] || continue
		mac="$(printf '%s' "$mac" | sed 's/[^0-9a-f:]//g')"
		case "$mac" in *:*:*:*:*:*) ;; *) continue ;; esac
		uuid="$(printf '%s\n' "$line" | sed -n 's/^[^.]*\.//p')"
		ip="$(ip neigh show 2>/dev/null | awk -v m="$mac" 'tolower($0) ~ ("lladdr " m " ") {print $1; exit}')"
		[ -n "$ip" ] || ip='unresolved'
		latency='unknown'
		if [ "$ip" != unresolved ] && command -v ping >/dev/null 2>&1 && ping -c 1 -W 1 "$ip" >/tmp/uu-ping.$$ 2>/dev/null; then
			latency="$(sed -n 's/.*time[=<]\([0-9.]*\).*/\1/p' /tmp/uu-ping.$$ | head -n1)"
			[ -n "$latency" ] || latency='reachable'
		fi
		rm -f /tmp/uu-ping.$$
		[ "$mac" = "$router_mac" ] && reason='router_mac_only'
		printf 'device=%s|name=%s|mac=%s|uuid=%s|latency=%s\n' "$ip" '' "$mac" "$uuid" "$latency"
	# Some official releases write this file without a trailing newline.
	done <<EOF
$(cat "$status_file")
	EOF
	printf 'count=%s\n' "$(grep -c '^[0-9A-Fa-f].*\.' "$status_file" 2>/dev/null || echo 0)"
	[ -n "$reason" ] && printf 'reason=%s\n' "$reason"
}

dns_status() {
	local installed='0' running='0' mode='unknown' hijack='unknown' listeners='' resolved='' fakeip='0'
	if [ -x /etc/init.d/openclash ] || [ -f /etc/config/openclash ]; then installed='1'; fi
	if [ -x /etc/init.d/openclash ] && /etc/init.d/openclash status 2>/dev/null | grep -qi 'running'; then
		running='1'
	elif pidof clash >/dev/null 2>&1 || pidof mihomo >/dev/null 2>&1; then
		running='1'
	fi
	if [ -f /etc/config/openclash ]; then
		mode="$(uci -q get openclash.config.enhanced_mode 2>/dev/null || uci -q get openclash.config.dns_mode 2>/dev/null || echo unknown)"
		hijack="$(uci -q get openclash.config.enable_redirect_dns 2>/dev/null || uci -q get openclash.config.dns_redirect 2>/dev/null || echo unknown)"
	fi
	if command -v ss >/dev/null 2>&1; then
		listeners="$(ss -lnup 2>/dev/null | awk '$5 ~ /:53$/ {print $0}' | grep -Eo 'dnsmasq|smartdns|mosdns|clash|mihomo' | sort -u | tr '\n' ',' | sed 's/,$//')"
	elif command -v netstat >/dev/null 2>&1; then
		listeners="$(netstat -lnup 2>/dev/null | awk '$4 ~ /:53$/ {print $0}' | grep -Eo 'dnsmasq|smartdns|mosdns|clash|mihomo' | sort -u | tr '\n' ',' | sed 's/,$//')"
	fi
	resolved="$(nslookup router.uu.163.com 127.0.0.1 2>/dev/null | awk '/^Address [0-9]*: / {print $3} /^Address: / {print $2}' | tail -n1)"
	case "$resolved" in 198.18.*|198.19.*) fakeip='1' ;; esac
	printf 'openclash_installed=%s\nopenclash_running=%s\ndns_mode=%s\ndns_hijack=%s\ndns_listeners=%s\nuu_resolved=%s\nuu_fake_ip=%s\n' \
		"$installed" "$running" "$mode" "$hijack" "${listeners:-unknown}" "${resolved:-unknown}" "$fakeip"
}

case "${1:-}" in
	prepare) prepare "${2:-auto}" ;;
	update-monitor) lock; update_monitor ;;
	stop-runtime) stop_runtime ;;
	clean-runtime) clean_runtime ;;
	status) status_text ;;
	devices) device_status ;;
	dns-status) dns_status ;;
	detect-model) detect_model ;;
	*)
		echo "Usage: $0 {prepare [model]|update-monitor|stop-runtime|clean-runtime|status|devices|dns-status|detect-model}" >&2
		exit 2
		;;
esac
