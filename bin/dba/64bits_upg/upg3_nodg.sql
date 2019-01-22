spool /tmp/upg_3_$ORACLE_SID.log
startup
@catcpu.sql
@?/rdbms/admin/utlrp.sql
shutdown immediate;
spool off
exit

