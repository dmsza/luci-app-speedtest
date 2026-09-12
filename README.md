> **NOTICE:** This project contains AI-generated code and is provided “as is,” without warranty of any kind. Review and test it before use.

# luci-app-speedtest

LuCI frontend for the [Ookla Speedtest CLI](https://www.speedtest.net/apps/cli) on OpenWrt 25.12.

The application lists Ookla test servers, runs a selected test, and displays a bounded history of completed tests in LuCI.

## Requirements

- OpenWrt 25.12 or a compatible OpenWrt release
- LuCI
- `speedtest` installed at `/usr/bin/speedtest`
- `rpcd-mod-ucode`
- `ucode-mod-fs`

The package declares the rpcd/ucode dependencies automatically. The [Ookla Speedtest CLI](https://www.speedtest.net/apps/cli) is not bundled and must be installed separately according to Ookla's distribution instructions. For additional discussion of the CLI's licensing considerations on OpenWrt, see [this OpenWrt forum discussion](https://forum.openwrt.org/t/ookla-speedtest-cli/66345/30).

## Building

It is assumed that you already have a correctly configured OpenWrt build system for OpenWrt 25.12. For setup instructions and build prerequisites, see the [official OpenWrt build system installation guide](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem).

The commands below assume that the OpenWrt tree is in `~/openwrt` and that this repository is cloned alongside it:

```sh
git clone https://github.com/openwrt/openwrt.git ~/openwrt
cd ~/openwrt
git checkout openwrt-25.12
git clone https://github.com/dmsza/luci-app-speedtest.git ../luci-app-speedtest
./scripts/feeds update -a
./scripts/feeds install -a
cp -r ../luci-app-speedtest package/luci-app-speedtest
```

Configure and build the package. Run `make menuconfig` as needed to select the desired build target:

```sh
echo "CONFIG_PACKAGE_luci-app-speedtest=m" > .config
make defconfig
make menuconfig  # Select the target device and desired build options
make tools/compile V=s
make package/luci-app-speedtest/compile V=s
find bin/packages -type f -name 'luci-app-speedtest*.apk'
```

The generated APK is placed below `bin/packages/`, in the package directory for the selected target architecture. Record the path printed by `find` for the installation step.

## Installation

Copy the generated APK to the router, then install it with `apk`. Replace the local path and router address as needed:

```sh
scp /path/to/luci-app-speedtest*.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1
apk add --allow-untrusted /tmp/luci-app-speedtest*.apk
```

The router must have access to its configured OpenWrt package repositories so `apk` can resolve the package's dependencies. The [Ookla Speedtest CLI](https://www.speedtest.net/apps/cli) is not included in this package; install it separately at `/usr/bin/speedtest` before using the LuCI application.

After installation, open **LuCI → Network → SpeedTest**.

## License

This project contains LuCI integration code for the [Ookla Speedtest CLI](https://www.speedtest.net/apps/cli). The [Ookla Speedtest CLI](https://www.speedtest.net/apps/cli) is proprietary software and is not included in this repository; refer to Ookla's terms and license for the CLI.
