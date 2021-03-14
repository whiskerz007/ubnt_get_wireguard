#!/usr/bin/env bash
###############################################################################
#         File:  uninstall_wireguard.sh                                       #
#                                                                             #
#        Usage:  uninstall_wireguard.sh                                       #
#                                                                             #
#  Description:  Uninstall WireGuard from Ubiquiti routers and remove         #
#                persistent package.                                          #
#                                                                             #
#       Author:  whiskerz007                                                  #
#      Website:  https://github.com/whiskerz007/ubnt_get_wireguard            #
#      License:  MIT                                                          #
###############################################################################

set -o errexit  #Exit immediately if a pipeline returns a non-zero status
set -o errtrace #Trap ERR from shell functions, command substitutions, and commands from subshell
set -o nounset  #Treat unset variables as an error
set -o pipefail #Pipe will exit with last non-zero status if applicable
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
function msg() {
  local TEXT="$1"
  echo -e "$TEXT"
}
function cleanup() {
  if [ ! -z ${VYATTA_API+x} ] && $($VYATTA_API inSession); then
    vyatta_cfg_teardown
  fi
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
function add_to_path() {
  for DIR in "$@"; do
    if [ -d "$DIR" ] && [[ ":$PATH:" != *":$DIR:"* ]]; then
      PATH="${PATH:+"$PATH:"}$DIR"
    fi
  done
}

if [ "$(id -g -n)" != 'vyattacfg' ] ; then
    echo switching group to vyattacfg...
    exec sg vyattacfg -c "$(which bash) -$- $(readlink -f $0) $*"
fi

[[ $EUID -ne 0 ]] && SUDO='sudo'
add_to_path /sbin /usr/sbin

# Setup vyatta environment
VYATTA_SBIN=/opt/vyatta/sbin
VYATTA_API=${VYATTA_SBIN}/my_cli_shell_api
VYATTA_SET=${VYATTA_SBIN}/my_set
VYATTA_DELETE=${VYATTA_SBIN}/my_delete
VYATTA_COMMIT=${VYATTA_SBIN}/my_commit
VYATTA_SESSION=$(cli-shell-api getSessionEnv $$)
eval $VYATTA_SESSION
export vyatta_sbindir=$VYATTA_SBIN

# If WireGuard configuration exists
if $($VYATTA_API existsActive interfaces wireguard); then
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
  ${SUDO-} modprobe --remove wireguard || \
    die "A problem occured while removing WireGuard mdoule."
fi

# Uninstall WireGuard package
msg 'Uninstalling WireGuard...'
${SUDO-} dpkg --purge wireguard &> /dev/null || \
  die "A problem occured while uninstalling the package."

# Remove firstboot package
FIRSTBOOT_DEB='/config/data/firstboot/install-packages/wireguard.deb'
if [ -f $FIRSTBOOT_DEB ]; then
  msg 'Removing WireGuard package from firstboot path...'
  ${SUDO-} rm $FIRSTBOOT_DEB || \
    warn "Failure removing debian package from firstboot path."
fi

msg 'WireGuard has been successfully uninstalled.'
