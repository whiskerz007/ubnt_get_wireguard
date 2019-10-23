# Download and install WireGaurd on Ubiquiti edge devices

***Warning:*** _This script attempts to preserve your running configuration, however you should have a backup your configuration before running this script._
 
This script will reference [Lochnair/vyatta-wireguard](https://github.com/Lochnair/vyatta-wireguard) repo for WireGuard releases. It will download, install, and setup the package to install post firmware upgrade. Rebooting the device is **not** required after running this script as long as the script did not generate any errors. Grab the script by running the following commands from the web CLI or SSH.

```
cd /config/scripts
curl -O --silent https://raw.githubusercontent.com/whiskerz007/ubnt_get_wireguard/master/get_wireguard.sh
chmod +x get_wireguard.sh
```

***Note:*** _Best practice is to save scripts into `/config/scripts` directory._

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
