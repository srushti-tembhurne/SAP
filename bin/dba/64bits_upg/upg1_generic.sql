spool /tmp/upg1_1_$ORACLE_SID.log
startup upgrade
@?/rdbms/admin/utlirp.sql
@?/rdbms/admin/catalog.sql
@?/rdbms/admin/catproc.sql
@?/olap/admin/catnoamd.sql
@?/olap/admin/olapidrp.plb
@?/olap/admin/olap.sql SYSAUX TEMP;
@?/rdbms/admin/utlrp
SHUTDOWN IMMEDIATE;
spool off
exit

