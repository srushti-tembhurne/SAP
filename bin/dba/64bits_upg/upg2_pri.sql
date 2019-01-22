spool /tmp/upg_2_$ORACLE_SID.log
startup upgrade
ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_2=DEFER;
@?/rdbms/admin/catupgrd.sql
@?/rdbms/admin/utlrp.sql
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER SYSTEM ENABLE RESTRICTED SESSION;
ALTER DATABASE OPEN;
spool off
exit

