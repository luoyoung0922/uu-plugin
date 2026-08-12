param(
    [string]$SourceRoot = (Join-Path $PSScriptRoot '..\luci-app-uu-official'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\uu-official-installer.run')
)

$ErrorActionPreference = 'Stop'
$source = (Resolve-Path $SourceRoot).Path
$files = @(
    @{ Src = 'root/etc/config/uu-official'; Dst = '/etc/config/uu-official'; Mode = '0644' },
    @{ Src = 'root/etc/init.d/uu-official'; Dst = '/etc/init.d/uu-official'; Mode = '0755' },
    @{ Src = 'root/etc/uci-defaults/99-uu-official'; Dst = '/etc/uci-defaults/99-uu-official'; Mode = '0755' },
    @{ Src = 'root/usr/libexec/uu-official/manager.sh'; Dst = '/usr/libexec/uu-official/manager.sh'; Mode = '0755' },
    @{ Src = 'root/usr/share/luci/menu.d/luci-app-uu-official.json'; Dst = '/usr/share/luci/menu.d/luci-app-uu-official.json'; Mode = '0644' },
    @{ Src = 'root/usr/share/rpcd/acl.d/luci-app-uu-official.json'; Dst = '/usr/share/rpcd/acl.d/luci-app-uu-official.json'; Mode = '0644' },
    @{ Src = 'htdocs/luci-static/resources/view/uu-official/settings.js'; Dst = '/www/luci-static/resources/view/uu-official/settings.js'; Mode = '0644' },
    @{ Src = 'htdocs/luci-static/resources/view/uu-official/status.js'; Dst = '/www/luci-static/resources/view/uu-official/status.js'; Mode = '0644' }
)

$header = @'
#!/bin/sh
# One-click installer for luci-app-uu-official.
# shellcheck disable=SC2015,SC2086,SC2317
set -u
NAME="uu-official-installer"
PAYLOAD_DIR="$(mktemp -d /tmp/uu-official-installer.XXXXXX 2>/dev/null || true)"
[ -n "$PAYLOAD_DIR" ] && [ -d "$PAYLOAD_DIR" ] || { echo "Cannot create temporary directory" >&2; exit 1; }
cleanup() { rm -rf "$PAYLOAD_DIR"; }
trap cleanup EXIT INT TERM
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$NAME] $*"; logger -t "$NAME" -- "$*" 2>/dev/null || true; }
usage() { echo "Usage: $0 [--uninstall] [--no-start]"; }
[ "$(id -u 2>/dev/null)" = 0 ] || die "run as root"
[ -r /etc/openwrt_release ] || die "OpenWrt/iStoreOS is required"
UNINSTALL=0; NO_START=0
for arg in "$@"; do case "$arg" in
  --uninstall) UNINSTALL=1;;
  --no-start) NO_START=1;;
  -h|--help) usage; exit 0;;
  *) usage >&2; exit 2;;
esac; done
install_payload() {
  dst="$1"; mode="$2"; src="$PAYLOAD_DIR/$(printf '%s' "$dst" | sed 's#^/##; s#/#_#g')"
  mkdir -p "$(dirname "$dst")" || die "cannot create $(dirname "$dst")"
  cp "$src" "$dst" || die "cannot install $dst"
  chmod "$mode" "$dst" || die "cannot chmod $dst"
}
stop_legacy() {
  if [ -x /etc/init.d/uugamebooster ]; then /etc/init.d/uugamebooster disable >/dev/null 2>&1 || true; /etc/init.d/uugamebooster stop >/dev/null 2>&1 || true; fi
  for pid in $(ps w 2>/dev/null | awk '/[u]uplugin_monitor\.sh/ { print $1 }'); do
    [ -r "/proc/$pid/cmdline" ] && kill "$pid" 2>/dev/null || true
  done
  rm -f /etc/rc.d/S99uuplugin
}
install_deps() {
  command -v opkg >/dev/null 2>&1 || die "opkg is required"
  missing=""
  for pkg in kmod-tun curl ca-bundle; do opkg status "$pkg" 2>/dev/null | grep -q 'Status: install' || missing="$missing $pkg"; done
  [ -z "$missing" ] && return 0
  opkg update >/dev/null 2>&1 || true
  opkg install $missing || die "cannot install dependencies:$missing"
}
uninstall() {
  [ -x /etc/init.d/uu-official ] && { /etc/init.d/uu-official disable >/dev/null 2>&1 || true; /etc/init.d/uu-official stop >/dev/null 2>&1 || true; }
  rm -f /etc/rc.d/S99uu-official /etc/init.d/uu-official /etc/config/uu-official /etc/uci-defaults/99-uu-official
  rm -f /usr/share/luci/menu.d/luci-app-uu-official.json /usr/share/rpcd/acl.d/luci-app-uu-official.json
  rm -rf /usr/libexec/uu-official /www/luci-static/resources/view/uu-official /usr/share/luci-static/resources/view/uu-official
  log "manager removed; /usr/sbin/uu and /tmp/uu were preserved"
}
[ "$UNINSTALL" -eq 1 ] && { uninstall; exit 0; }
install_deps
stop_legacy
stamp="$(date +%Y%m%d-%H%M%S)"; backup="/root/uu-official-backup-$stamp"; mkdir -p "$backup"
for old in /etc/config/uu-official /etc/init.d/uu-official /usr/libexec/uu-official; do [ -e "$old" ] && cp -a "$old" "$backup/" 2>/dev/null || true; done
log "backup: $backup"
'@

$body = ''
foreach ($item in $files) {
    $sourcePath = Join-Path $source ($item.Src -replace '/', '\')
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Missing $($item.Src)" }
    $key = ($item.Dst.TrimStart('/') -replace '/', '_')
    $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($sourcePath))
    $body += "mkdir -p `"`$PAYLOAD_DIR`"`nbase64 -d > `"`$PAYLOAD_DIR/$key`" <<'UU_EOF_$key'`n$encoded`nUU_EOF_$key`ninstall_payload '$($item.Dst)' '$($item.Mode)'`n"
}

$footer = @'
uci -q set uu-official.main.enabled='1' || die "cannot write UCI config"
uci -q set uu-official.main.model='auto' || die "cannot write UCI config"
uci -q commit uu-official || die "cannot commit UCI config"
/etc/init.d/uu-official enable || die "cannot enable service"
if [ "$NO_START" -eq 0 ]; then
  /etc/init.d/uu-official restart || die "cannot start service"
  log "service started; use LuCI Services -> NetEase UU"
else
  log "installed without starting; run /etc/init.d/uu-official start"
fi
log "installation complete"
exit 0
'@

[IO.File]::WriteAllText($OutputPath, $header + $body + $footer, (New-Object Text.UTF8Encoding($false)))
Write-Output "Wrote $OutputPath"
