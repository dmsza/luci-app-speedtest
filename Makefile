include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-speedtest
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-speedtest
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for SpeedTest CLI
  PKGARCH:=all
  # rpcd-mod-ucode lets rpcd load the ucode backend in
  # root/usr/share/rpcd/ucode/speedtest.uc directly (no executable rpcd
  # script, no jsonfilter dependency - see that file's comments).
  # ucode-mod-fs provides the 'fs' module (popen/readfile/writefile) that
  # backend imports.
  DEPENDS:=+rpcd-mod-ucode +ucode-mod-fs
endef

define Build/Compile
endef

define Package/luci-app-speedtest/install
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view

	$(INSTALL_DATA) ./root/usr/share/rpcd/ucode/speedtest.uc $(1)/usr/share/rpcd/ucode/
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-speedtest.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-speedtest.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/speedtest.js $(1)/www/luci-static/resources/view/
endef

define Package/luci-app-speedtest/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	mkdir -p /var/lib/luci-app-speedtest
	chown root:root /var/lib/luci-app-speedtest
	chmod 700 /var/lib/luci-app-speedtest
	/etc/init.d/rpcd restart
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-speedtest))
