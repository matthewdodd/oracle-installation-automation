#!/usr/bin/bash

if [[ -z "$1" ]]
then
  echo "first argument must be Database SID"
  exit 1
elif [[ -z "$2" ]]
then
  echo "first argument must be Database Owner ID"
  exit 1
elif [[ -z "$3" ]]
then
  echo "remote_script_directory parameter required, i.e. /tmp/ora_ansible_scripts_{{ DATABASE_NAME }}"
  exit 1
elif [[ -z "$4" ]]
then
  echo "remote_output_directory parameter required, i.e. /tmp/oracle_database_install_{{ DATABASE_NAME }}"
  exit 1
elif [[ -z "$5" ]]
then
  echo "install_folder_name parameter required, i.e. /local/software/{{ database_version }}"
  exit 1
fi

ORACLE_SID=$1
. /local/$ORACLE_SID.env

db_owner=$2
remote_script_directory=$3/oracle_database_install_role
remote_output_directory=$4
db_owner_grp=$(id -g -n $db_owner)
install_folder_name=$5

echo $ORACLE_HOME
echo $db_owner
echo $remote_script_directory
echo $remote_output_directory

check_opatch_status_from_file () {
  opatch_success_expression="OPatch succeeded"
  opatch_ignore_success="OPatch completed with warnings"
  # if AIX, OPatch completed with warnings, is considered successfull
  if [[ $OSTYPE == "aix"* ]]; then
    opatch_success_expression="OPatch completed with warnings"
  fi

  opatch_status=$(tail -1 $remote_output_directory/opatch_status.txt)
  if [ ! -z "$opatch_status" ]
  then
    if [[ $opatch_status == *"$opatch_success_expression"* ]]; then
      echo "opatch_status=$opatch_status, opatch succeeded"
    else
      if [[ $opatch_status == *"$opatch_ignore_success"* ]]; then
        echo "opatch_status=$opatch_status, opatch succeeded"
      else
        echo "opatch_status=$opatch_status, opatch did not succeed"
        exit 1
      fi
    fi
  else
    echo "opatch did not succeed"
    exit 1
  fi
}

vercomp () {
    if [[ $1 == $2 ]]
    then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

db_patch_update_string="Database * Release Update"
jvm_patch_update_string="\- Oracle JavaVM Component"

patch_root_folder=$install_folder_name
lines=$(find $patch_root_folder -type d -name '[0-9]*')
while read -r line ; do
  if [ -e $line/README.html ]; then
    grep_count=$(grep "$db_patch_update_string" $line/README.html | wc -l)
    if [[ $grep_count -gt 0 ]] ; then
      db_patch_folder=$line
    fi
    grep_count=$(grep "$jvm_patch_update_string" $line/README.html | wc -l)
    if [[ $grep_count -gt 1 ]] ; then
      jvm_patch_folder=$line
       echo jvm_patch_folder=$jvm_patch_folder
    fi
  fi
done <<< "$lines"
echo db_patch_folder=$db_patch_folder
echo jvm_patch_folder=$jvm_patch_folder

if [ ! -z "$db_patch_folder" ]
then
  db_patch_id="$(basename $db_patch_folder)"
  echo db_patch_id=$db_patch_id
  if [ -z "$db_patch_id" ]
  then
    echo "db_patch_id not found"
    exit 1
  fi
else
  echo "db_patch_folder not found"
  exit 1
fi

if [ ! -z "$jvm_patch_folder" ]
then
  jvm_patch_id="$(basename $jvm_patch_folder)"
  echo jvm_patch_id=$jvm_patch_id
  if [ -z "$jvm_patch_id" ]
  then
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
if [ -d "$install_folder_name/OPatch" ]; then
  echo "Check if OPatch needs to be updated..."
  old_opatch_version=$(grep "OPATCH_VERSION" $ORACLE_HOME/OPatch/version.txt | sed -e "s/OPATCH_VERSION\://g")
  new_opatch_version=$(grep "OPATCH_VERSION" $install_folder_name/OPatch/version.txt | sed -e "s/OPATCH_VERSION\://g")
  echo old_opatch_version=$old_opatch_version
  echo new_opatch_version=$new_opatch_version
  vercomp $old_opatch_version $new_opatch_version
  
  if [ $? == "2" ]; then
    echo "Update OPatch, new_opatch_version=$new_opatch_version is GREATER THAN old_opatch_version=$old_opatch_version"
    cd $ORACLE_HOME
    rm -rf $ORACLE_HOME/OPatch.old
    mv $ORACLE_HOME/OPatch $ORACLE_HOME/OPatch.old
    cp -R $install_folder_name/OPatch .
    $ORACLE_HOME/OPatch/opatch version
  fi
fi

# PREPARE apply patch via OPatch
$ORACLE_HOME/OPatch/opatch apply -silent $db_patch_folder 2>&1 | tee $remote_output_directory/opatch_status.txt
check_opatch_status_from_file

$ORACLE_HOME/OPatch/opatch apply -silent $jvm_patch_folder 2>&1 | tee $remote_output_directory/opatch_status.txt
check_opatch_status_from_file
