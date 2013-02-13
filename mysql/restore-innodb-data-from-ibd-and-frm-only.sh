#! /usr/bin/env bash

# Restore a innoDB table when all you have is the .ibd / frm (with innodb-file-per-table enabled)
# This is a helper script bringing together the following
# http://www.mysqlperformanceblog.com/2011/05/13/connecting-orphaned-ibd-files/
# http://www.chriscalender.com/?p=28

# This must contain both .ibd and frm files
FILES_TO_RECOVER=/var/lib/mysql/torecover

# This must be large enough to store the resulting .sql files
TEMP_PATH=/var/lib/mysql/temp

# The DataDir (in my.cnf)
DATADIR=/var/lib/mysql/data
LOGSDIR=/var/lib/mysql/logs

if [[ "x${1}" == "x" ]]; then
    echo "Pass in a .ibd file as $1. This file must have a frm file in the same directory"
    exit 1
fi;

function restart_mysql {
    # Kill and restart MySQL 
    chown -R mysql:mysql ${DATADIR}
    mysqladmin shutdown >> /dev/null 2>&1
    killall -9 mysqld
    /usr/sbin/mysqld --basedir=/usr --datadir=${DATADIR} --plugin-dir=/usr/lib/mysql/plugin --user=mysql --log-error=/var/log/mysql/mysql.log --open-files-limit=65535 --pid-file=/var/run/mysqld/mysqld.pid --socket=/var/run/mysqld/mysqld.sock &
    count=0
    echo "Waiting for MySQL to start"
    while [ $count -lt 200  ]; do
        mysql -h localhost -e "SELECT 1" >> /dev/null 2>&1 && break
        sleep 1
        let count=$count+1
    done
    echo "MySQL started"
    sleep 5
}

[[ -d ${TEMP_PATH} ]] || mkdir -p ${TEMP_PATH}

table_name=$(basename $1 .ibd)
echo "Attempting to recover ${table_name}";

## STEP 1: Retrieve the schema

# Check there is a frm file
if [[ ! -f ${FILES_TO_RECOVER}/${table_name}.frm || ! -f ${FILES_TO_RECOVER}/${table_name}.ibd ]]; then
    echo "Can not find a FRM file for ${table_name} - can not continue";
    exit 1
fi

# Restart MySQL
killall -9 mysqld
rm -rf ${DATADIR}/ib* ${DATADIR}/restore/ ${LOGSDIR}/*
restart_mysql

# Create a test DB
echo "create database restore" | mysql

# Create a table
echo "create table ${table_name} (id int) engine=innodb" | mysql restore

# Overwrite the .frm file with the one from the restore location
rm -f ${DATADIR}/restore/${table_name}.frm
cp ${FILES_TO_RECOVER}/${table_name}.frm ${DATADIR}/restore/${table_name}.frm

# sleep 5    

# Restart MySQL
restart_mysql

# Retrieve the schema
echo "show create table ${table_name}" | mysql restore > ${TEMP_PATH}/${table_name}-schema.sql
echo "Dumping schema for table"
mysqldump -d restore  ${table_name} >  ${TEMP_PATH}/${table_name}-schema.sql

## STEP 2: establish the InnoDB tablespace details

# Basically we replace the .ibd file (blank) created above and import it, seeing what value it produces
echo "ALTER TABLE ${table_name} DISCARD TABLESPACE;" | mysql restore

# Move rather than copy to be efficient
mv ${FILES_TO_RECOVER}/${table_name}.ibd ${DATADIR}/restore/${table_name}.ibd
chown -R mysql:mysql ${DATADIR}

echo "ALTER TABLE ${table_name} IMPORT TABLESPACE;" | mysql restore
if [[ $? -eq 0 ]]; then
    echo "Data is imported. Try to access restore.${table_name}";
    exit 0
fi;

# If we get to here, almost certainly it failed
# Retrieve log file and get the magic numbers
# Note the subtraction in perl
tables_to_add=$(grep "tablespace id and flags in file" /var/log/mysql/mysql.log  | tail -1 | perl -wlne 'print $1-10 if /are (\d+)/')

killall -9 mysqld
mv ${DATADIR}/restore/${table_name}.ibd ${FILES_TO_RECOVER}/${table_name}.ibd
rm -rf ${DATADIR}/ib* ${DATADIR}/restore/ ${LOGSDIR}/*
restart_mysql

# Create DB
echo "create database restore" | mysql

echo "Creating filler tables (x ${tables_to_add})"
for i in $(seq ${tables_to_add}); do
    echo "create table testx$i (i int) engine=innodb" | mysql restore;
done;

# Import schema
cat ${TEMP_PATH}/${table_name}-schema.sql | mysql restore
    
echo "ALTER TABLE ${table_name} DISCARD TABLESPACE;" | mysql restore
mv ${FILES_TO_RECOVER}/${table_name}.ibd ${DATADIR}/restore/

echo "ALTER TABLE ${table_name} IMPORT TABLESPACE;" | mysql restore
if [[ $? -eq 0 ]]; then
    echo "Data is imported. Dumping restore.${table_name} to ${TEMP_PATH}/recovered-${table_name}.sql";
    mysqldump restore ${table_name} > ${TEMP_PATH}/recovered-${table_name}.sql
    exit 0
else
    echo "Data did not work - check logs"
    exit 2
fi;

done
