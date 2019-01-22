set line 300
set trimspool on
set pages 0
set feedback off

spool rename_temp_file.sql
select 'alter tablespace '||b.name||' add tempfile '''||replace(t.name,'ora'||SUBSTR(t.name,5,2),'ora'||SUBSTR(t.name,5,2)||'data01')||''' SIZE 300M REUSE AUTOEXTEND ON NEXT 100M MAXSIZE 1800M;' from v$tempfile t, sys.ts$ b
where t.ts#=b.ts# and b.bitmapped !=0;
spool off
!mv rename_temp_file.sql rename_temp_file_$ORACLE_SID.sql

spool rename_file.sql

select 'alter database rename file '''||name||''' to '''||replace(name,'ora'||SUBSTR(name,5,2),'ora'||SUBSTR(name,5,2)||'data01')||''';' from v$datafile;

select 'alter database rename file '''||t.name||''' to '''||replace(t.name,'ora'||SUBSTR(t.name,5,2),'ora'||SUBSTR(t.name,5,2)||'data01')||''';' from v$tempfile t, sys.ts$ b
where t.ts#=b.ts# and b.bitmapped = 0;

select 'alter database tempfile '''||t.name||''' drop;'
from v$tempfile t, sys.ts$ b
where t.ts#=b.ts# and b.bitmapped !=0 ;

select 'alter database rename file '''||member||''' to '''||replace(member,'ora'||SUBSTR(member,5,2),'ora'||SUBSTR(member,5,2)||'log01')||''';' from v$logfile where type='ONLINE' and instr(member,'_')=0 ; 

select 'alter database rename file '''||member||''' to '''||replace(member,'ora'||SUBSTR(member,5,2)||'b','ora'||SUBSTR(member,5,2)||'log02')||''';' from v$logfile where type='ONLINE' and instr(member,'_') != 0 and instr(substr(member,1,7),'b') !=0; 

select 'alter database rename file '''||a.member||''' to '''||replace(a.member,'ora'||SUBSTR(a.member,5,2),'ora'||SUBSTR(a.member,5,2)||'log01')||''';' 
from v$logfile a, v$standby_log b 
where b.status !='ACTIVE' 
and b.group#=a.group# 
and a.type='STANDBY' 
and instr(a.member,'_')!=0; 

spool off
!mv rename_file.sql rename_file_$ORACLE_SID.sql 
