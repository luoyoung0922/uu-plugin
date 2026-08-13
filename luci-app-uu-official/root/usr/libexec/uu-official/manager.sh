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

write_boot_hook() {
	local hook="$INSTALL_DIR/S99uuplugin" tmp="${INSTALL_DIR}/S99uuplugin.tmp.$$"
	{
		echo '#!/bin/sh /etc/rc.common'
		echo 'START=99'
		echo 'start() { /bin/sh /usr/sbin/uu/uuplugin_monitor.sh >/dev/null 2>&1 & }'
	} > "$tmp" || die "cannot write boot hook"
	chmod 0755 "$tmp"
	mv "$tmp" "$hook"
	ln -sf "$hook" /etc/rc.d/S99uuplugin
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
	write_boot_hook
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
	[ -L /etc/rc.d/S99uuplugin ] && enabled='1'
	pid="$(runtime_pid 2>/dev/null || true)"
	if [ -n "$pid" ]; then
		printf 'running\nenabled=%s\npid=%s\nmodel=%s\nmonitor=%s\n' "$enabled" "$pid" "$model" "$monitor"
	else
		printf 'stopped\nenabled=%s\npid=\nmodel=%s\nmonitor=%s\n' "$enabled" "$model" "$monitor"
	fi
}

device_status() {
	local status_file="${RUNTIME_DIR}/activate_status" ip line latency name mac uuid router_mac reason='' nft_ips nft_ip packets kind hints
	nft_ips="$(nft list ruleset 2>/dev/null | sed -n 's/.*table ip XU_ACC_DEVICE_\([0-9.]*\)_mangle.*/\1/p' | sort -u)"
	if [ -n "$nft_ips" ]; then
		printf 'source=nftables/XU_ACC_DEVICE_*\n---\n'
		for nft_ip in $nft_ips; do
			mac="$(ip neigh show "$nft_ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="lladdr") print $(i+1); exit}')"
			name="$(awk -v ip="$nft_ip" '$3 == ip { print $4; exit }' /tmp/dhcp.leases 2>/dev/null)"
			[ "$name" = '*' ] && name=''
			if [ -z "$name" ] && [ -n "$mac" ]; then
				name="$(uci -q show dhcp 2>/dev/null | awk -F= -v mac="$mac" '
					tolower($2) ~ tolower(mac) { section=$1; sub(/\.mac$/, "", section) }
					section != "" && $1 == section ".name" { gsub(/^.|.$/, "", $2); print $2; exit }')"
			fi
			hints="$(printf '%s\n' "$name" | tr 'A-Z' 'a-z') $(nft list ruleset 2>/dev/null | grep "$nft_ip" | tr 'A-Z' 'a-z')"
			case "$hints" in
				*playstation*|*ps4*|*ps5*|*'sport 9308'*|*'dport 9308'*|*'sport 9295'*|*'dport 9295'*) kind='playstation' ;;
				*nintendo*|*switch*) kind='switch' ;;
				*xbox*|*xboxone*|*xbox-series*) kind='xbox' ;;
				*iphone*|*ipad*|*android*|*phone*) kind='mobile' ;;
				*windows*|*desktop*|*laptop*|*macbook*) kind='computer' ;;
				*) kind='console' ;;
			esac
			latency='unknown'
			if command -v ping >/dev/null 2>&1 && ping -c 1 -W 1 "$nft_ip" >/tmp/uu-ping.$$ 2>/dev/null; then
				latency="$(sed -n 's/.*time[=<]\([0-9.]*\).*/\1/p' /tmp/uu-ping.$$ | head -n1)"; [ -n "$latency" ] || latency='reachable'
			fi
			rm -f /tmp/uu-ping.$$
			packets="$(nft list table ip XU_ACC_DEVICE_${nft_ip}_mangle 2>/dev/null | sed -n 's/.*counter packets \([0-9][0-9]*\).*/\1/p' | awk '{s+=$1} END{print s+0}')"
			printf 'device=%s|name=%s|mac=%s|uuid=|latency=%s|packets=%s|kind=%s\n' "$nft_ip" "$name" "${mac:-unknown}" "$latency" "$packets" "$kind"
		done
		return 0
	fi
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

log_tail() {
	[ -r /tmp/monitor.log ] || return 0
	tail -n 600 /tmp/monitor.log
}

official_start() {
	local requested model
	requested="${1:-$(uci -q get uu-official.main.model 2>/dev/null || echo auto)}"
	model="$(normalize_model "$requested")" || die "unsupported architecture: $(uname -m 2>/dev/null)"
	lock
	mkdir -p "$INSTALL_DIR" "$RUNTIME_DIR"
	[ -x "$MONITOR" ] || update_monitor
	write_config "$model"
	write_boot_hook
	other_monitor_running >/dev/null 2>&1 && return 0
	/bin/sh "$MONITOR" >/dev/null 2>&1 &
	log "official monitor started"
}

official_stop() {
	local pid
	stop_runtime
	for pid in $(ps w 2>/dev/null | awk '/[u]uplugin_monitor\.sh/ {print $1}'); do kill "$pid" 2>/dev/null || true; done
	log "official monitor stopped"
}

case "${1:-}" in
	prepare) prepare "${2:-auto}" ;;
	update-monitor) lock; update_monitor ;;
	stop-runtime) stop_runtime ;;
	clean-runtime) clean_runtime ;;
	status) status_text ;;
	devices) device_status ;;
	log) log_tail ;;
	start) official_start "${2:-}" ;;
	stop) official_stop ;;
	restart) official_stop; sleep 1; official_start ;;
	detect-model) detect_model ;;
	*)
		echo "Usage: $0 {prepare [model]|update-monitor|stop-runtime|clean-runtime|status|devices|log|start|stop|restart|detect-model}" >&2
		exit 2
		;;
esac
