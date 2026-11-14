#!/usr/bin/bash
#
# database_install.bash - silent, software-only install of Oracle Database
# binaries into an already extracted ORACLE_HOME.
#
# Runs as the Oracle software owner (db_owner). It sources the per-database
# environment file (which must set ORACLE_HOME and ORACLE_BASE), writes a fresh
# response file and runs runInstaller in silent mode.
#
# Usage:
#   database_install.bash <SID> <db_owner> <remote_script_directory> \
#                         <remote_output_directory> <database_version> <env_file>
#
# Positional arguments (all required):
#   1  SID                      Database name; exported as ORACLE_SID.
#   2  db_owner                 Oracle software owner OS user. Its primary group
#                               is used for UNIX_GROUP_NAME and every OS*_GROUP.
#   3  remote_script_directory  Staging directory holding this role's files
#                               (<dir>/oracle_database_install_role).
#   4  remote_output_directory  Directory for logs; install_status.txt is
#                               written here.
#   5  database_version         19.0.0.0, 12.2.0.1 or 12.1.0.2. Any other value
#                               is treated as 12.1.0.2 (with a warning), as in
#                               earlier releases of this script.
#   6  env_file                 Environment file to source (sets ORACLE_HOME,
#                               ORACLE_BASE), e.g. <site_prefix>/<SID>.env.
#
# Optional environment variables:
#   ORACLE_INVENTORY_LOCATION   Value of INVENTORY_LOCATION in the response
#                               file. Default: /etc/oraInst.loc (the value
#                               written by earlier releases). Pass the effective
#                               central inventory for side-by-side installs.
#   ORACLE_IGNORE_PREREQS       true|false (also yes/no, 1/0). When true,
#                               -ignorePrereq is passed to runInstaller.
#                               Default: false (prerequisite checks enforced).
#   ORACLE_INSTALL_EDITION      oracle.install.db.InstallEdition. Default: EE.
#   ORACLE_INSTALL_OPTION       oracle.install.option. Default: INSTALL_DB_SWONLY.
#   ORACLE_OS_GROUP             Group for UNIX_GROUP_NAME and all OS*_GROUP keys.
#                               Default: primary group of db_owner.
#   ORACLE_RESPONSE_FILE        Response file path.
#                               Default: $ORACLE_HOME/responseFile.rsp.
#   ORACLE_RESPONSE_EXTRA_FILE  Optional file of extra key=value lines appended
#                               to the generated response file (site-specific
#                               keys). Default: none.
#
# Exit status: 0 when the last non-empty line of install_status.txt contains
# "Successfully Setup Software" (this also matches "... with warning");
# 1 otherwise, or on invalid input.
#
# The response file is rewritten from scratch on every run, so a rerun never
# duplicates keys.

usage_error () {
  # stdout, so the message shows in the Ansible task output (stdout_lines).
  echo "ERROR: $1"
  exit 1
}

if [[ -z "$1" ]]; then
  usage_error "first argument must be Database SID"
elif [[ -z "$2" ]]; then
  usage_error "second argument must be Database Owner ID"
elif [[ -z "$3" ]]; then
  usage_error "remote_script_directory parameter required, i.e. /tmp/ora_ansible_scripts_<DATABASE_NAME>"
elif [[ -z "$4" ]]; then
  usage_error "remote_output_directory parameter required, i.e. /tmp/oracle_database_install_<DATABASE_NAME>"
elif [[ -z "$5" ]]; then
  usage_error "fifth argument must be the database version"
elif [[ -z "$6" ]]; then
  usage_error "sixth argument must be the environment file, i.e. <oracle_common_env_dir>/<DATABASE_NAME>.env"
fi

ORACLE_SID=$1
export ORACLE_SID
db_owner=$2
remote_script_directory=$3/oracle_database_install_role
remote_output_directory=$4
database_version=$5
# Environment file written by the role (oracle_common_env_file).
oracle_env_file=$6

if [[ ! -r "$oracle_env_file" ]]; then
  usage_error "environment file $oracle_env_file not found or not readable"
fi
# shellcheck source=/dev/null
. "$oracle_env_file"

if [[ -z "$ORACLE_HOME" || -z "$ORACLE_BASE" ]]; then
  usage_error "ORACLE_HOME and ORACLE_BASE must be set by $oracle_env_file"
fi
if [[ ! -d "$remote_output_directory" ]]; then
  usage_error "remote_output_directory $remote_output_directory does not exist"
fi

# Reject values that would inject extra lines into the response file.
no_newline () {
  case "$2" in
    *$'\n'* | *$'\r'*) usage_error "$1 must not contain line breaks" ;;
  esac
}

if [[ -n "$ORACLE_OS_GROUP" ]]; then
  db_owner_grp=$ORACLE_OS_GROUP
else
  db_owner_grp=$(id -g -n "$db_owner") || usage_error "cannot resolve primary group of $db_owner"
fi
inventory_location=${ORACLE_INVENTORY_LOCATION:-/etc/oraInst.loc}
install_edition=${ORACLE_INSTALL_EDITION:-EE}
install_option=${ORACLE_INSTALL_OPTION:-INSTALL_DB_SWONLY}
resp=${ORACLE_RESPONSE_FILE:-$ORACLE_HOME/responseFile.rsp}
install_status_file=$remote_output_directory/install_status.txt

for pair in "db_owner_grp=$db_owner_grp" "ORACLE_INVENTORY_LOCATION=$inventory_location" \
            "ORACLE_INSTALL_EDITION=$install_edition" "ORACLE_INSTALL_OPTION=$install_option" \
            "ORACLE_HOME=$ORACLE_HOME" "ORACLE_BASE=$ORACLE_BASE"; do
  no_newline "${pair%%=*}" "${pair#*=}"
done
if [[ -z "$db_owner_grp" ]]; then
  usage_error "OS group for $db_owner is empty"
fi

case "$(printf '%s' "${ORACLE_IGNORE_PREREQS:-false}" | tr '[:upper:]' '[:lower:]')" in
  true | yes | 1) ignore_prereqs=true ;;
  false | no | 0 | "") ignore_prereqs=false ;;
  *) usage_error "ORACLE_IGNORE_PREREQS must be true or false, got '$ORACLE_IGNORE_PREREQS'" ;;
esac

if [[ -n "$ORACLE_RESPONSE_EXTRA_FILE" && ! -r "$ORACLE_RESPONSE_EXTRA_FILE" ]]; then
  usage_error "ORACLE_RESPONSE_EXTRA_FILE $ORACLE_RESPONSE_EXTRA_FILE not found or not readable"
fi
if [[ ! -x "$ORACLE_HOME/runInstaller" ]]; then
  usage_error "$ORACLE_HOME/runInstaller not found or not executable"
fi

echo "ORACLE_HOME=$ORACLE_HOME"
echo "db_owner=$db_owner"
echo "remote_script_directory=$remote_script_directory"
echo "remote_output_directory=$remote_output_directory"
echo "database_version=$database_version"
echo "inventory_location=$inventory_location"
echo "ignore_prereqs=$ignore_prereqs"

check_install_status_from_file () {
  local install_success_expression="Successfully Setup Software"
  local install_ignore_success="Successfully Setup Software with warning"
  local install_status

  # Last non-empty line of the installer output.
  install_status=$(awk 'NF { last = $0 } END { print last }' "$install_status_file" 2>/dev/null)
  if [[ -n "$install_status" ]]; then
    if [[ $install_status == *"$install_success_expression"* ]]; then
      echo "install_status=$install_status, install succeeded"
    elif [[ $install_status == *"$install_ignore_success"* ]]; then
      echo "install_status=$install_status, install succeeded"
    else
      echo "install_status=$install_status, install did not succeed"
      exit 1
    fi
  else
    echo "install did not succeed"
    exit 1
  fi
}

# Version-specific response file keys.
version_keys () {
  case "$1" in
    19.0.0.0)
      echo "oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v19.0.0"
      echo "oracle.install.db.rootconfig.executeRootScript=false"
      ;;
    12.2.0.1)
      echo "oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v12.2.0"
      ;;
    *)
      # 12.1.0.2: schema key and the silent-mode security-update answers from
      # Oracle's 12.1.0.2 db_install.rsp template.
      echo "oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v12.1.0"
      echo "DECLINE_SECURITY_UPDATES=true"
      echo "SECURITY_UPDATES_VIA_MYORACLESUPPORT=false"
      ;;
  esac
}

case "$database_version" in
  19.0.0.0 | 12.2.0.1 | 12.1.0.2) ;;
  *) echo "WARNING: database_version '$database_version' is not recognised; using the 12.1.0.2 response file layout" ;;
esac

# Create the response file: always truncated and rewritten (never appended).
echo "response_file=$resp"
rm -f "$resp" || usage_error "cannot remove old response file $resp"
if ! (
  umask 022
  {
    echo "# Generated by database_install.bash on $(date '+%Y-%m-%d %H:%M:%S'). Do not edit; rewritten on every run."
    version_keys "$database_version"
    echo "oracle.install.db.InstallEdition=$install_edition"
    echo "oracle.install.option=$install_option"
    echo "INVENTORY_LOCATION=$inventory_location"
    echo "UNIX_GROUP_NAME=$db_owner_grp"
    echo "ORACLE_HOME=$ORACLE_HOME"
    echo "ORACLE_BASE=$ORACLE_BASE"
    echo "oracle.install.db.OSDBA_GROUP=$db_owner_grp"
    echo "oracle.install.db.OSOPER_GROUP=$db_owner_grp"
    echo "oracle.install.db.OSBACKUPDBA_GROUP=$db_owner_grp"
    echo "oracle.install.db.OSDGDBA_GROUP=$db_owner_grp"
    echo "oracle.install.db.OSKMDBA_GROUP=$db_owner_grp"
    echo "oracle.install.db.OSRACDBA_GROUP=$db_owner_grp"
    if [[ -n "$ORACLE_RESPONSE_EXTRA_FILE" ]]; then
      echo "# Extra keys from $ORACLE_RESPONSE_EXTRA_FILE"
      cat "$ORACLE_RESPONSE_EXTRA_FILE"
    fi
  } > "$resp"
); then
  usage_error "cannot write response file $resp"
fi

export SKIP_ROOTPRE=TRUE

installer_args=()
if [[ "$ignore_prereqs" == true ]]; then
  echo "WARNING: ORACLE_IGNORE_PREREQS=true, passing -ignorePrereq to runInstaller"
  installer_args+=(-ignorePrereq)
fi
installer_args+=(-waitforcompletion -silent -responseFile "$resp")

"$ORACLE_HOME/runInstaller" "${installer_args[@]}" 2>&1 | tee "$install_status_file"
check_install_status_from_file
