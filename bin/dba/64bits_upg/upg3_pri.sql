spool /tmp/upg_3_$ORACLE_SID.log
startup
ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_2=DEFER;
@catcpu.sql
@?/rdbms/admin/utlrp.sql
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER SYSTEM ENABLE RESTRICTED SESSION;
ALTER DATABASE OPEN;
spool off
exit
