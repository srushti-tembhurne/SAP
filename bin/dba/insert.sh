#!/bin/ksh 
# Tomo Olson
date
ERRMSG1='>>>>>>> ERROR topio.sh: syntax error, parameter=<ORACLE_SID> <owner>'
ERRMSG2='>>>>>>> ERROR topio.sh: syntax error, parameter=<ORACLE_SID> <owner>'

DBNAME=$1
OWNER=$2
if [ "$1" ]
then DBNAME=$1
else echo $ERRMSG1
exit
fi
if [ "$2" ]
then OWNER=$2
else echo $ERRMSG2
exit
fi
HOST=`hostname`
. /oracle/app/oracle/scripts/exec_cron.sh -s $DBNAME
ORACLE_SID=$DBNAME;export ORACLE_SID
ORACLE_HOME=/oracle/app/oracle/product/8.1.6;export ORACLE_HOME
$ORACLE_HOME/bin/sqlplus system/$systempass @/oracle/app/oracle/admin/dbascripts/insert.sql $OWNER > /oracle/app/oracle/admin/dbascripts/insert.out        
mailx -s  "$DBNAME $OWNER count is done" tolson@ariba.com < /dev/null
date
