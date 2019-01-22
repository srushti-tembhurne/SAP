spool /tmp/upg2_nodg_$ORACLE_SID.log
startup upgrade
@?/rdbms/admin/catupgrd.sql
@?/rdbms/admin/utlrp.sql
shutdown
spool off
exit

