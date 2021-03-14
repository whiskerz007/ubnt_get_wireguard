#!/usr/bin/env bash
###############################################################################
#         File:  get_wireguard.sh                                             #
#                                                                             #
#        Usage:  get_wireguard.sh [VERSION]                                   #
#                                                                             #
#  Description:  Download and install WireGuard on Ubiquiti routers that will #
#                persist through firmware upgrades. If WireGuard is already   #
#                installed, the WireGuard configuration will be backed up and #
#                removed, WireGuard will be updated to the selected version,  #
#                the backed up WireGuard configuration will be restored, and  #
#                the WireGuard installation package will be stored so that it #
#                will be reinstall after firmware upgrades.                   #
#                                                                             #
#   Parameters:  VERSION                                                      #
#                    Install version that has been published to GitHub        #
#                    WireGuard/wireguard-vyatta-ubnt releases. When version   #
#                    is omitted, the latest release is selected.              #
#                                                                             #
#        Notes:  Ensure you have a recent backup of the WireGuard             #
#                configuration before running this script.                    #
#       Author:  whiskerz007                                                  #
#      Website:  https://github.com/whiskerz007/ubnt_get_wireguard            #
#      License:  MIT                                                          #
###############################################################################

set -eEu -o pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR
trap cleanup EXIT

function error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON"
  exit $EXIT
}
function warn() {
  local REASON="\e[97m$1\e[39m"
  local FLAG="\e[93m[WARNING]\e[39m"
  msg "$FLAG $REASON"
}
function info() {
  local REASON="$1"
  local FLAG="\e[36m[INFO]\e[39m"
  msg "$FLAG $REASON"
}
function msg() {
  local TEXT="$1"
  echo -e "$TEXT" | log
}
function log() {
  while read TEXT; do
    if [ -f $LOG_PATH ] && [ $(wc -l $LOG_PATH | cut -f1 -d' ') -ge $LOG_MAX_LINES ]; then
      local LOG=$(cat $LOG_PATH)
      tail -n $(($LOG_MAX_LINES-1)) > $LOG_PATH <<<$LOG
    fi
    local TIMESTAMP=$(date '+%FT%T%z')
    local ANSI_ESCAPE_SEQUENCES='\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]'
    echo -e "$TEXT" | tee -a >(
      sed -r "s/^/$TIMESTAMP: /; s/$ANSI_ESCAPE_SEQUENCES//g" >> $LOG_PATH
    )
  done
}
function cleanup() {
  if [ ! -z ${VYATTA_API+x} ] && $($VYATTA_API inSession); then
    vyatta_cfg_teardown
  fi
  rm -rf $TEMP_DIR
}
function vyatta_cfg_setup() {
  $VYATTA_API setupSession
  if ! $($VYATTA_API inSession); then
    die "Failure occured while setting up vyatta configuration session."
  fi
}
function vyatta_cfg_teardown() {
  if ! $($VYATTA_API teardownSession); then
    die "Failure occured while tearing down vyatta configuration session."
  fi
}

# Script must run as group 'vyattacfg' to prevent errors and system instability
if [ "$(id -g -n)" != 'vyattacfg' ] ; then
  # Replace current shell with this script running as group 'vyattacfg' with
  # identical bash options and parameters
  echo switching group to vyattacfg...
  exec sg vyattacfg -c "$(which bash) -$- $(readlink -f $0) $*"
fi

# Default variables
LOG_MAX_LINES=10000
LOG_PATH=/tmp/`basename "${0%.*}"`.log
[ ! -f $LOG_PATH ] && touch $LOG_PATH && chmod 664 $LOG_PATH
OVERRIDE_VERSION=${1:-}
[[ $EUID -ne 0 ]] && SUDO='sudo'
SUDO=${SUDO:-}
TEMP_DIR=$(mktemp -d)
RUNNING_CONFIG_BACKUP_PATH=${TEMP_DIR}/config.run

# Required when script is executed from vyatta task-scheduler
for DIR in {,/usr}/sbin; do
  # If DIR does not exist in PATH variable
  if [ -d "$DIR" ] && [[ ":$PATH:" != *":$DIR:"* ]]; then
    # Append DIR to PATH variable
    PATH="${PATH:+"$PATH:"}$DIR"
  fi
done

# Get board model
BOARD_MODEL=$(
  /usr/sbin/ubnt-hal show-version | \
  grep 'HW model' | \
  sed 's/^.*:\s*//'
)
[ -z "$BOARD_MODEL" ] && die "Unable to get board model."
info "Board model: $BOARD_MODEL"

# Get board type
BOARD_TYPE=$(
  cut -d'.' -f2 <<< cat /etc/version | \
  sed 's/ER-//I'
)
[ -z "$BOARD_TYPE" ] && die "Unable to get board type."
info "Board type: $BOARD_TYPE"

# Set board mapping to match repo
case $BOARD_TYPE in
  e120)  BOARD_MAP='ugw3';;
  e220)  BOARD_MAP='ugw4';;
  e1020) BOARD_MAP='ugwxg';;
  *)     BOARD_MAP=$BOARD_TYPE;;
esac
info "Board repo mapping: $BOARD_MAP"

# Get firmware version
FIRMWARE=$(
  cat /opt/vyatta/etc/version | \
  awk '{print $2}'
)
info "Firmware version: $FIRMWARE"

# Get installed WireGuard version
INSTALLED_VERSION=$(dpkg-query --show --showformat='${Version}' wireguard 2> /dev/null || true)
info "Installed WireGuard version: $INSTALLED_VERSION"

# Get list of releases
GITHUB_API='https://api.github.com'
GITHUB_REPO='WireGuard/wireguard-vyatta-ubnt'
GITHUB_RELEASES_URL="${GITHUB_API}/repos/${GITHUB_REPO}/releases"
GITHUB_RELEASES=$(curl --silent $GITHUB_RELEASES_URL)

# Set jq query strings
if [ ! -z $OVERRIDE_VERSION ]; then
  # Get the release for the override version
  QUERY="[.[]][] | select(.tag_name == \"$OVERRIDE_VERSION\") |"
else
  # Get the latest release
  QUERY="[[.[]][] | select(.prerelease == false)][0]"
fi

# Get release version
RELEASE_VERSION=$(jq -r "$QUERY .tag_name" <<< $GITHUB_RELEASES)
[ -z $RELEASE_VERSION ] && die "Invalid release version supplied."
info "Release version: $RELEASE_VERSION"

# Check if override is not present and release version is newer than installed
if [ -z $OVERRIDE_VERSION ] && $(dpkg --compare-versions "$RELEASE_VERSION" 'le' "$INSTALLED_VERSION"); then
  msg "Your installation is up to date."
  exit 0
fi

# Get debian package URL
[[ ! $BOARD_MAP = ugw* ]] && FIRMWARE_FILTER="| select(.name | contains(\"$(cut -d'.' -f1 <<< $FIRMWARE)-\"))"
DEB_URL=$(jq -r "[$QUERY .assets[] | select(.name | contains(\"$BOARD_MAP-\")) ${FIRMWARE_FILTER:-}][0].browser_download_url" <<< $GITHUB_RELEASES)
[ -z $DEB_URL ] && die "Failed to locate debian package for your board and firmware."
info "Debian package URL: $DEB_URL"

# Download the package
msg 'Downloading WireGuard package...'
DEB_PATH=${TEMP_DIR}/$(basename $DEB_URL)
curl --silent --location $DEB_URL -o $DEB_PATH || \
  die "Failure downloading debian package."

# Check package integrity
msg 'Checking WireGuard package integrity...'
dpkg-deb --info $DEB_PATH &> /dev/null || \
  die "Debian package integrity check failed for package."

# Setup vyatta environment
VYATTA_SBIN=/opt/vyatta/sbin
VYATTA_API=${VYATTA_SBIN}/my_cli_shell_api
VYATTA_SET=${VYATTA_SBIN}/my_set
VYATTA_DELETE=${VYATTA_SBIN}/my_delete
VYATTA_COMMIT=${VYATTA_SBIN}/my_commit
VYATTA_SESSION=$(cli-shell-api getSessionEnv $$)
eval $VYATTA_SESSION
export vyatta_sbindir=$VYATTA_SBIN #Required for some vyatta-wireguard templates to work

# If WireGuard configuration exists
if $($VYATTA_API existsActive interfaces wireguard); then
  # Backup running configuration
  msg 'Backing up running configuration...'
  $VYATTA_API showConfig --show-active-only > $RUNNING_CONFIG_BACKUP_PATH

  # Remove running WireGuard configuration
  vyatta_cfg_setup
  if dpkg --compare-versions "$INSTALLED_VERSION" 'le' '1.0.20210219-1'; then
    msg 'Executing configuration remediation...'
    INTERFACES=( $($VYATTA_API listNodes interfaces wireguard | sed "s/'//g") )
    for INTERFACE in ${INTERFACES[@]}; do
      if [ "$($VYATTA_API returnValue interfaces wireguard $INTERFACE route-allowed-ips)" == "true" ]; then
        $VYATTA_SET interfaces wireguard $INTERFACE route-allowed-ips false
        $VYATTA_COMMIT
      fi
      INTERFACE_ADDRESSES=( $(ip -oneline address show dev $INTERFACE | awk '{print $4}') )
      for IP in $($VYATTA_API returnValues interfaces wireguard $INTERFACE address | sed "s/'//g"); do
        [[ ! " ${INTERFACE_ADDRESSES[@]} " =~ " $IP " ]] && ip address add $IP dev $INTERFACE
      done
    done
  fi
  msg 'Removing running WireGuard configuration...'
  $VYATTA_DELETE interfaces wireguard
  $VYATTA_COMMIT
  vyatta_cfg_teardown
fi

# If WireGuard module is loaded
if $(lsmod | grep wireguard > /dev/null); then
  # Remove WireGuard module
  msg 'Removing WireGuard module...'
  $SUDO modprobe --remove wireguard || \
    die "A problem occured while removing WireGuard mdoule."
fi

# Install WireGuard package
msg 'Installing WireGuard...'
$SUDO dpkg -i $DEB_PATH &> /dev/null || \
  die "A problem occured while installing the package."

# If WireGuard was previously configured
if [ -f $RUNNING_CONFIG_BACKUP_PATH ]; then
  # Load backup configuration
  msg 'Restoring previous running configuration...'
  vyatta_cfg_setup
  $VYATTA_API loadFile $RUNNING_CONFIG_BACKUP_PATH
  $VYATTA_COMMIT
  vyatta_cfg_teardown
fi

# Move package to firstboot path to automatically install package after firmware update
msg 'Enabling WireGuard installation after firmware update...'
FIRSTBOOT_DIR='/config/data/firstboot/install-packages'
if [ ! -d $FIRSTBOOT_DIR ]; then
  $SUDO mkdir -p $FIRSTBOOT_DIR &> /dev/null || \
    die "Failure creating '$FIRSTBOOT_DIR' directory."
fi
$SUDO mv $DEB_PATH ${FIRSTBOOT_DIR}/wireguard.deb || \
  warn "Failure moving debian package to firstboot path."

msg 'WireGuard has been successfully installed.'
