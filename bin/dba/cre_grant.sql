set pages 0
set feedback off
spool /tmp/exec_grant.sql
select 'grant select on v_$session to '||username||';' from dba_users where username like 'S3LIVE%'  or username like 'BYRLIVE%';
select 'grant select on v_$sql_plan to '||username||';' from dba_users where username like 'S3LIVE%'  or username like 'BYRLIVE%';
select 'grant select on v_$sql to '||username||';' from dba_users where username like 'S3LIVE%'  or username like 'BYRLIVE%';
@/tmp/exec_grant.sql
