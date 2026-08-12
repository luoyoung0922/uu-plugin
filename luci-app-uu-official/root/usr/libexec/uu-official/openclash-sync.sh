#!/bin/sh

set -u

TAG="uu_official_dynamic_bypass"
STATE="/tmp/uu-official-openclash-ips"

active_ips() {
	nft list tables 2>/dev/null |
		sed -n 's/^table ip XU_ACC_DEVICE_\([0-9.]*\)_mangle$/\1/p' |
		sort -u
}

delete_tagged_rules() {
	local chain handles handle
	for chain in openclash openclash_mangle openclash_dns_redirect; do
		handles="$(nft -a list chain inet fw4 "$chain" 2>/dev/null |
			awk -v tag="$TAG" 'index($0, tag) {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}' |
			sort -rn)"
		for handle in $handles; do
			nft delete rule inet fw4 "$chain" handle "$handle" 2>/dev/null || true
		done
	done
}

apply_rules() {
	local ips="$1" ip
	delete_tagged_rules
	[ -n "$ips" ] || { rm -f "$STATE"; return 0; }
	nft list chain inet fw4 openclash >/dev/null 2>&1 || return 0
	for ip in $ips; do
		case "$ip" in *[!0-9.]*|'') continue ;; esac
		nft insert rule inet fw4 openclash ip saddr "$ip" counter return comment "$TAG" 2>/dev/null || true
		nft insert rule inet fw4 openclash_mangle ip saddr "$ip" counter return comment "$TAG" 2>/dev/null || true
		nft insert rule inet fw4 openclash_dns_redirect ip saddr "$ip" counter return comment "$TAG" 2>/dev/null || true
	done
	printf '%s\n' "$ips" > "$STATE"
}

case "${1:-run}" in
	once)
		apply_rules "$(active_ips)"
		;;
	cleanup)
		delete_tagged_rules
		rm -f "$STATE"
		;;
	run)
		last=''
		while true; do
			current="$(active_ips)"
			# Reapply when the active list changes or OpenClash rebuilt its chains.
			if [ "$current" != "$last" ] || { [ -n "$current" ] && ! nft -a list chain inet fw4 openclash 2>/dev/null | grep -q "$TAG"; }; then
				apply_rules "$current"
				last="$current"
			fi
			sleep 2
		done
		;;
	*)
		echo "Usage: $0 {run|once|cleanup}" >&2
		exit 2
		;;
esac
