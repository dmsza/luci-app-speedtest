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

Build the package from an OpenWrt 25.12 source tree. The commands below assume that the OpenWrt tree is in `~/openwrt` and that this repository is cloned alongside it:

```sh
git clone https://github.com/openwrt/openwrt.git ~/openwrt
cd ~/openwrt
git checkout openwrt-25.12
git clone https://github.com/dmsza/luci-app-speedtest.git ../luci-app-speedtest
./scripts/feeds update -a
./scripts/feeds install -a
cp -r ../luci-app-speedtest package/luci-app-speedtest
make menuconfig
```

In `menuconfig`, select **LuCI → Applications → luci-app-speedtest** as a module (`M`), save, and exit. Then build the package:

```sh
make defconfig
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

## Usage

1. Open the SpeedTest page.
2. Select a server from the server list.
3. Press **Go!**.
4. Wait for the test to finish. The result is added to the history table.

The server list is fetched with `speedtest -L`. Each test runs with the selected server ID and the Ookla license/GDPR acceptance flags.

## Storage and safety

- History is stored in `/var/lib/luci-app-speedtest/history.json`.
- The state directory is created with mode `0700` and owned by `root`.
- History writes use a temporary file followed by an atomic rename.
- History is limited to 200 validated entries and reads are capped at 64 KiB.
- A lock prevents concurrent speed tests on the router.
- Tests are bounded by a 180-second timeout when the BusyBox `timeout` applet is available.
- Result links are rendered only for `http://` and `https://` URLs and use `noopener noreferrer`.

The RPC backend requires authenticated LuCI/rpcd access. Do not expose the LuCI administration interface to untrusted networks.

## License

This project contains LuCI integration code for the [Ookla Speedtest CLI](https://www.speedtest.net/apps/cli). The [Ookla Speedtest CLI](https://www.speedtest.net/apps/cli) is proprietary software and is not included in this repository; refer to Ookla's terms and license for the CLI.
