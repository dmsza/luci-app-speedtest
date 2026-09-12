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

Copy the package directory into the OpenWrt build tree, for example:

```sh
cp -r luci-app-speedtest package/
echo "CONFIG_PACKAGE_luci-app-speedtest=m" >> .config
rm -rf tmp/
make defconfig
make package/luci-app-speedtest/compile V=s
find bin/ -name 'luci-app-speedtest*.apk'
```

## Installation

Install the generated APK on the router using:

```sh
apk add --allow-untrusted luci-app-speedtest*.apk
```

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
