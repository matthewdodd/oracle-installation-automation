#!/bin/bash
#
# TEST STUB - NOT ORACLE SOFTWARE. Molecule stand-in for <ORACLE_HOME>/root.sh, shipped inside the fake
# LINUX_binaries.tar.gz. It must run as root (through the become method or the stub root wrapper), asks
# root.sh's first question (answered with ENTER = the default by the expect dialogue or by the become
# method's stdin), records that it ran in <ORACLE_HOME>/install/molecule_root_sh.done (owned by root, read
# by verify.yml) and prints the line the role's success check looks for.
set -u

if [[ "$(id -u)" -ne 0 ]]; then
  echo "root.sh must be run as the root user"
  exit 1
fi

oracle_home=$(cd "$(dirname "$0")" && pwd -P) || exit 1

echo "Performing root user operation."
echo ""
echo "The following environment variables are set as:"
echo "    ORACLE_OWNER= $(stat -c %U "$oracle_home")"
echo "    ORACLE_HOME=  $oracle_home"
echo ""
printf 'Enter the full pathname of the local bin directory: [/usr/local/bin]: '
answer=""
read -r -t 60 answer || answer=""
echo ""
local_bin=${answer:-/usr/local/bin}
echo "Local bin directory: $local_bin (test stub, nothing copied)"

mkdir -p "$oracle_home/install" || exit 1
printf 'ran_as=%s\nlocal_bin=%s\n' "$(id -u -n)" "$local_bin" > "$oracle_home/install/molecule_root_sh.done" || exit 1

echo "Finished running generic part of root script."
echo "Now product-specific root actions will be performed."
