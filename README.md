# Introduction

***Warning:*** _This script attempts to preserve your running configuration, however you should have a backup of your configuration before running this script._

This script installs and maintaince the wireguard vpn solution on a ubiquiti router.

*Features*

* Simple installation
* Automatically detect used hardware
* Proper upgrade process preserving configuration
* Scheduled auto update
* Preserve wireguard on firmware upgrade
* Preserve wireguard configuration on firmeware upgrade

# Download and install WireGuard on Ubiquiti edge devices
 
This script will reference [WireGuard/wireguard-vyatta-ubnt](https://github.com/WireGuard/wireguard-vyatta-ubnt) repo for WireGuard releases. It will download, install, and setup the package to install post firmware upgrade. Rebooting the device is **not** required after running this script as long as the script did not generate any errors. Grab the script by running the following commands from the web CLI or SSH as root.

```
cd /config/scripts
curl -LO --silent https://github.com/whiskerz007/ubnt_get_wireguard/raw/master/get_wireguard.sh	
chmod +x get_wireguard.sh
```

***Note:*** _Best practice is to save scripts into `/config/scripts` directory._

## Usage

To download and install the latest release of WireGuard, run the following command.

```
./get_wireguard.sh
```

To download and install a specific release of WireGuard, run the following command with the desired release as a parameter.

```
./get_wireguard.sh 0.0.20190913-1
```

## Log

The script writes a log to `/tmp/get_wireguard.log`. This log file will be removed after reboot of the device.

## Automation

To automatically run this script once per week, you can run the following commands from an EdgeMAX device.

```
configure
set system task-scheduler task get_wireguard executable path /config/scripts/get_wireguard.sh
set system task-scheduler task get_wireguard interval 7d
commit
save
exit
```

## Uninstall

To uninstall WireGuard, run the following command.

```
sg vyattacfg "$(curl -sL https://github.com/whiskerz007/ubnt_get_wireguard/raw/master/uninstall_wireguard.sh)"
```
