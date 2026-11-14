#!/usr/bin/bash
#
# database_patch.bash - apply the Database Release Update (mandatory) and the
# OJVM patch (optional) to an installed ORACLE_HOME, upgrading OPatch first
# when the staged OPatch is newer.
#
# Runs as the Oracle software owner (db_owner). It sources the per-database
# environment file (which must set ORACLE_HOME).
#
# Usage:
#   database_patch.bash <SID> <db_owner> <remote_script_directory> \
#                       <remote_output_directory> <install_folder_name> <env_file>
#
# Positional arguments (all required):
#   1  SID                      Database name; exported as ORACLE_SID.
#   2  db_owner                 Oracle software owner OS user (informational).
#   3  remote_script_directory  Staging directory holding this role's files
#                               (<dir>/oracle_database_install_role).
#   4  remote_output_directory  Directory for logs (status files below).
#   5  install_folder_name      Directory with the extracted patches, searched
#                               recursively for numeric patch folders holding a
#                               README.html, plus an optional OPatch/ folder.
#   6  env_file                 Environment file to source (sets ORACLE_HOME),
#                               e.g. <site_prefix>/<SID>.env.
#
# Patch detection (unchanged from earlier releases):
#   - DB RU: README.html matches the BRE "Database * Release Update" at least
#     once. Mandatory; the script exits 1 when none is found.
#   - OJVM:  README.html matches "- Oracle JavaVM Component" more than once.
#     Optional; when none is found the OJVM apply is skipped.
#   When several folders match, the last one found wins.
#
# OPatch upgrade: when <install_folder_name>/OPatch exists and its
# OPATCH_VERSION is greater than $ORACLE_HOME/OPatch's, $ORACLE_HOME/OPatch is
# moved to OPatch.old and replaced (restored again if the copy fails).
#
# Status files (one per patch, so the OJVM run never overwrites the DB RU log):
#   <remote_output_directory>/opatch_status.txt      DB RU apply output
#                                                    (same name as before)
#   <remote_output_directory>/opatch_jvm_status.txt  OJVM apply output
#
# Exit status: 0 when each applied patch's last non-empty output line contains
# "OPatch succeeded" or "OPatch completed with warnings"; 1 otherwise, or on
# invalid input.

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
  usage_error "remote_script_directory parameter required, i.e. <oracle_common_staging_base>/ora_ansible_scripts_<DATABASE_NAME>"
elif [[ -z "$4" ]]; then
  usage_error "remote_output_directory parameter required, i.e. <oracle_common_staging_base>/oracle_database_install_<DATABASE_NAME>"
elif [[ -z "$5" ]]; then
  usage_error "install_folder_name parameter required, i.e. <site prefix>/software/<database_version>"
elif [[ -z "$6" ]]; then
  usage_error "sixth argument must be the environment file, i.e. <oracle_common_env_dir>/<DATABASE_NAME>.env"
fi

ORACLE_SID=$1
export ORACLE_SID
db_owner=$2
remote_script_directory=$3/oracle_database_install_role
remote_output_directory=$4
install_folder_name=$5
# Environment file written by the role (oracle_common_env_file).
oracle_env_file=$6

if [[ ! -r "$oracle_env_file" ]]; then
  usage_error "environment file $oracle_env_file not found or not readable"
fi
# shellcheck source=/dev/null
. "$oracle_env_file"

if [[ -z "$ORACLE_HOME" ]]; then
  usage_error "ORACLE_HOME must be set by $oracle_env_file"
fi
if [[ ! -d "$install_folder_name" ]]; then
  usage_error "install_folder_name $install_folder_name does not exist"
fi
if [[ ! -d "$remote_output_directory" ]]; then
  usage_error "remote_output_directory $remote_output_directory does not exist"
fi

echo "ORACLE_HOME=$ORACLE_HOME"
echo "db_owner=$db_owner"
echo "remote_script_directory=$remote_script_directory"
echo "remote_output_directory=$remote_output_directory"
echo "install_folder_name=$install_folder_name"

db_status_file=$remote_output_directory/opatch_status.txt
jvm_status_file=$remote_output_directory/opatch_jvm_status.txt

# check_opatch_status_from_file <status_file>
check_opatch_status_from_file () {
  local status_file=$1
  local opatch_success_expression="OPatch succeeded"
  local opatch_ignore_success="OPatch completed with warnings"
  local opatch_status
  # if AIX, OPatch completed with warnings, is considered successful
  if [[ $OSTYPE == "aix"* ]]; then
    opatch_success_expression="OPatch completed with warnings"
  fi

  # Last non-empty line of the OPatch output.
  opatch_status=$(awk 'NF { last = $0 } END { print last }' "$status_file" 2>/dev/null)
  if [[ -n "$opatch_status" ]]; then
    if [[ $opatch_status == *"$opatch_success_expression"* ]]; then
      echo "opatch_status=$opatch_status, opatch succeeded"
    elif [[ $opatch_status == *"$opatch_ignore_success"* ]]; then
      echo "opatch_status=$opatch_status, opatch succeeded"
    else
      echo "opatch_status=$opatch_status, opatch did not succeed"
      exit 1
    fi
  else
    echo "opatch did not succeed"
    exit 1
  fi
}

# vercomp <v1> <v2>: dot-separated numeric compare.
# Returns 0 if equal, 1 if v1 > v2, 2 if v1 < v2.
vercomp () {
  if [[ "$1" == "$2" ]]; then
    return 0
  fi
  local IFS=.
  local i
  local -a ver1 ver2
  read -r -a ver1 <<< "$1"
  read -r -a ver2 <<< "$2"
  # fill empty fields in ver1 with zeros
  for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
    ver1[i]=0
  done
  for ((i=0; i<${#ver1[@]}; i++)); do
    if [[ -z ${ver2[i]} ]]; then
      # fill empty fields in ver2 with zeros
      ver2[i]=0
    fi
    if ((10#${ver1[i]} > 10#${ver2[i]})); then
      return 1
    fi
    if ((10#${ver1[i]} < 10#${ver2[i]})); then
      return 2
    fi
  done
  return 0
}

# opatch_version_of <OPatch dir>: OPATCH_VERSION from its version.txt.
opatch_version_of () {
  grep "OPATCH_VERSION" "$1/version.txt" 2>/dev/null | sed -e "s/OPATCH_VERSION://g" | tr -d '[:space:]'
}

################################################################################
# find the patches
################################################################################

db_patch_update_string="Database * Release Update"
jvm_patch_update_string="- Oracle JavaVM Component"

db_patch_folder=""
jvm_patch_folder=""
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  if [[ -e "$line/README.html" ]]; then
    grep_count=$(grep -c -e "$db_patch_update_string" -- "$line/README.html")
    if [[ $grep_count -gt 0 ]]; then
      db_patch_folder=$line
    fi
    grep_count=$(grep -c -e "$jvm_patch_update_string" -- "$line/README.html")
    if [[ $grep_count -gt 1 ]]; then
      jvm_patch_folder=$line
      echo "jvm_patch_folder=$jvm_patch_folder"
    fi
  fi
done < <(find "$install_folder_name" -type d -name '[0-9]*')
echo "db_patch_folder=$db_patch_folder"
echo "jvm_patch_folder=$jvm_patch_folder"

if [[ -n "$db_patch_folder" ]]; then
  db_patch_id=$(basename "$db_patch_folder")
  echo "db_patch_id=$db_patch_id"
  if [[ -z "$db_patch_id" ]]; then
    echo "db_patch_id not found"
    exit 1
  fi
else
  echo "db_patch_folder not found"
  exit 1
fi

if [[ -n "$jvm_patch_folder" ]]; then
  jvm_patch_id=$(basename "$jvm_patch_folder")
  echo "jvm_patch_id=$jvm_patch_id"
  if [[ -z "$jvm_patch_id" ]]; then
    echo "jvm_patch_id not found"
    exit 1
  fi
else
  echo "jvm_patch_folder not found, that's okay, not mandatory"
fi

################################################################################
# apply opatch and patch
################################################################################

# Check if OPatch needs to be updated
if [[ -d "$install_folder_name/OPatch" ]]; then
  echo "Check if OPatch needs to be updated..."
  old_opatch_version=$(opatch_version_of "$ORACLE_HOME/OPatch")
  new_opatch_version=$(opatch_version_of "$install_folder_name/OPatch")
  echo "old_opatch_version=$old_opatch_version"
  echo "new_opatch_version=$new_opatch_version"
  vercomp "$old_opatch_version" "$new_opatch_version"
  vercomp_result=$?

  if [[ $vercomp_result -eq 2 ]]; then
    echo "Update OPatch, new_opatch_version=$new_opatch_version is GREATER THAN old_opatch_version=$old_opatch_version"
    cd "$ORACLE_HOME" || usage_error "cannot cd to ORACLE_HOME $ORACLE_HOME"
    rm -rf "$ORACLE_HOME/OPatch.old" || usage_error "cannot remove $ORACLE_HOME/OPatch.old"
    if [[ -e "$ORACLE_HOME/OPatch" ]]; then
      mv "$ORACLE_HOME/OPatch" "$ORACLE_HOME/OPatch.old" || usage_error "cannot move $ORACLE_HOME/OPatch to OPatch.old"
    fi
    if ! cp -R "$install_folder_name/OPatch" "$ORACLE_HOME/OPatch"; then
      echo "ERROR: copying the new OPatch failed, restoring the previous OPatch"
      rm -rf "$ORACLE_HOME/OPatch"
      if [[ -e "$ORACLE_HOME/OPatch.old" ]]; then
        mv "$ORACLE_HOME/OPatch.old" "$ORACLE_HOME/OPatch"
      fi
      exit 1
    fi
    "$ORACLE_HOME/OPatch/opatch" version
  fi
fi

if [[ ! -x "$ORACLE_HOME/OPatch/opatch" ]]; then
  usage_error "$ORACLE_HOME/OPatch/opatch not found or not executable"
fi

# Start from clean status files so a log from an earlier run is never mistaken
# for this run's result.
rm -f "$db_status_file" "$jvm_status_file"

# Apply the Database Release Update (mandatory).
echo "Applying DB RU $db_patch_id from $db_patch_folder (log: $db_status_file)"
"$ORACLE_HOME/OPatch/opatch" apply -silent "$db_patch_folder" 2>&1 | tee "$db_status_file"
check_opatch_status_from_file "$db_status_file"

# Apply the OJVM patch only when one was found (optional).
if [[ -n "$jvm_patch_folder" ]]; then
  echo "Applying OJVM patch $jvm_patch_id from $jvm_patch_folder (log: $jvm_status_file)"
  "$ORACLE_HOME/OPatch/opatch" apply -silent "$jvm_patch_folder" 2>&1 | tee "$jvm_status_file"
  check_opatch_status_from_file "$jvm_status_file"
else
  echo "Skipping OJVM apply: no OJVM patch folder found"
fi
