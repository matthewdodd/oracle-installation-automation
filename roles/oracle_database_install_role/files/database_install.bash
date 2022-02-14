#!/usr/bin/bash

if [[ -z "$1" ]]
then
  echo "first argument must be Database SID"
  exit 1
elif [[ -z "$2" ]]
then
  echo "second argument must be Database Owner ID"
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
  echo "fifth argument must be the databse version"
  exit 1
fi

ORACLE_SID=$1
. /local/$ORACLE_SID.env

db_owner=$2
remote_script_directory=$3/oracle_database_install_role
remote_output_directory=$4
db_owner_grp=$(id -g -n $db_owner)

echo $ORACLE_HOME
echo $db_owner
echo $remote_script_directory
echo $remote_output_directory

check_install_status_from_file () {
  install_success_expression="Successfully Setup Software"
  install_ignore_success="Successfully Setup Software with warning"

  install_status=$(tail -1 $remote_output_directory/install_status.txt)
  if [ ! -z "$install_status" ]
  then
    if [[ $install_status == *"$install_success_expression"* ]]; then
      echo "install_status=$install_status, install succeeded"
    else
      if [[ $install_status == *"$install_ignore_success"* ]]; then
        echo "install_status=$install_status, install succeeded"
      else
        echo "install_status=$install_status, install did not succeed"
        exit 1
      fi
    fi
  else
    echo "install did not succeed"
    exit 1
  fi
}

# Create the Response File

resp=$ORACLE_HOME/responseFile.rsp

echo $resp

if [ $5 == "19.0.0.0" ]
then 
  echo "oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v19.0.0" >> $resp
  echo "oracle.install.db.rootconfig.executeRootScript=false" >> $resp
elif [ $5 == "12.2.0.1" ]
then
  echo "oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v12.2.0" >> $resp
fi

echo "oracle.install.db.InstallEdition=EE" >> $resp
echo "oracle.install.option=INSTALL_DB_SWONLY" >> $resp
echo "INVENTORY_LOCATION=/etc/oraInst.loc" >> $resp
echo "UNIX_GROUP_NAME=$db_owner_grp" >> $resp
echo "ORACLE_HOME=$ORACLE_HOME" >> $resp
echo "ORACLE_BASE=$ORACLE_BASE" >> $resp
echo "oracle.install.db.OSDBA_GROUP=$db_owner_grp" >> $resp
echo "oracle.install.db.OSOPER_GROUP=$db_owner_grp" >> $resp
echo "oracle.install.db.OSBACKUPDBA_GROUP=$db_owner_grp" >> $resp
echo "oracle.install.db.OSDGDBA_GROUP=$db_owner_grp" >> $resp
echo "oracle.install.db.OSKMDBA_GROUP=$db_owner_grp" >> $resp
echo "oracle.install.db.OSRACDBA_GROUP=$db_owner_grp" >> $resp

export SKIP_ROOTPRE=TRUE

$ORACLE_HOME/runInstaller -ignorePrereq -waitforcompletion -silent -responseFile $resp 2>&1 | tee $remote_output_directory/install_status.txt
check_install_status_from_file
