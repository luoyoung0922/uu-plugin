include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for the NetEase UU router plugin
LUCI_DESCRIPTION:=Manage the official NetEase UU runtime distributed for OpenWrt
LUCI_DEPENDS:=+curl +ca-bundle +kmod-tun
LUCI_PKGARCH:=all
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
