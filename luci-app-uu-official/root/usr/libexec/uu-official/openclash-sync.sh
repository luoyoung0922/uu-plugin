#!/bin/sh

set -u

TAG="uu_official_dynamic_bypass"
STATE="/tmp/uu-official-proxy-bypass-state"
SIGNATURE="${STATE}.signature"

active_ips() {
	nft list tables 2>/dev/null |
		sed -n 's/^table ip XU_ACC_DEVICE_\([0-9.]*\)_mangle$/\1/p' |
		sort -u
}

proxy_chains() {
	# Detect transparent proxy nftables chains by implementation name, without
	# depending on any specific package's UCI configuration.
	nft list ruleset 2>/dev/null | awk '
		/^table (ip|inet) [A-Za-z0-9_.-]+ \{/ { family=$2; table=$3; next }
		/^[[:space:]]*chain [A-Za-z0-9_.-]+ \{/ {
			chain=$2
			name=tolower(table " " chain)
			if (name ~ /(openclash|passwall|psw|ssr|shadowsocks|homeproxy|mihomo|nikki|singbox|sing-box|v2ray|xray)/)
				print family "|" table "|" chain
			next
		}
	' | sort -u
}

known_chains() {
	local target family table chain
	for target in \
		'inet|fw4|openclash' 'inet|fw4|openclash_mangle' 'inet|fw4|openclash_dns_redirect' \
		'inet|fw4|PSW' 'inet|fw4|PSW_MANGLE' 'inet|fw4|PSW_REDIRECT' 'inet|fw4|PSW_DNS' \
		'inet|fw4|SSRPLUS' 'inet|fw4|SSRPLUS_MANGLE' 'inet|fw4|SSRPLUS_DNS'; do
		IFS='|' read -r family table chain <<EOF
$target
EOF
		nft list chain "$family" "$table" "$chain" >/dev/null 2>&1 && printf '%s\n' "$target"
	done
}

targets() {
	{ proxy_chains; known_chains; } | sort -u
}

delete_tagged_rules() {
	local target family table chain handles handle
	{ targets; [ -r "$STATE" ] && sed -n 's/^target=//p' "$STATE"; } | sort -u |
	while IFS= read -r target; do
		[ -n "$target" ] || continue
		IFS='|' read -r family table chain <<EOF
$target
EOF
		handles="$(nft -a list chain "$family" "$table" "$chain" 2>/dev/null |
			awk -v tag="$TAG" 'index($0, tag) {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}' |
			sort -rn)"
		for handle in $handles; do
			nft delete rule "$family" "$table" "$chain" handle "$handle" 2>/dev/null || true
		done
	done
}

apply_rules() {
	local ips="$1" current_targets target family table chain ip
	delete_tagged_rules
	[ -n "$ips" ] || { rm -f "$STATE"; return 0; }
	current_targets="$(targets)"
	[ -n "$current_targets" ] || { rm -f "$STATE"; return 0; }
	: > "$STATE"
	printf '%s\n' "$current_targets" | while IFS= read -r target; do
		IFS='|' read -r family table chain <<EOF
$target
EOF
		for ip in $ips; do
			case "$ip" in *[!0-9.]*|'') continue ;; esac
			nft insert rule "$family" "$table" "$chain" ip saddr "$ip" counter return comment "$TAG" 2>/dev/null || true
		done
		printf 'target=%s\n' "$target" >> "$STATE"
	done
	printf '%s\n' "$ips" | sed 's/^/ip=/' >> "$STATE"
}

case "${1:-run}" in
	once)
		apply_rules "$(active_ips)"
		;;
	cleanup)
		delete_tagged_rules
		rm -f "$STATE" "$SIGNATURE"
		;;
	run)
		while true; do
			current="$(active_ips)"
			current_targets="$(targets)"
			signature="$(printf '%s\n--\n%s\n' "$current" "$current_targets")"
			previous="$(cat "$SIGNATURE" 2>/dev/null || true)"
			if [ "$signature" != "$previous" ] || { [ -n "$current" ] && [ -n "$current_targets" ] && ! nft list ruleset 2>/dev/null | grep -q "$TAG"; }; then
				apply_rules "$current"
				printf '%s' "$signature" > "$SIGNATURE"
			fi
			sleep 2
		done
		;;
	*)
		echo "Usage: $0 {run|once|cleanup}" >&2
		exit 2
		;;
esac
