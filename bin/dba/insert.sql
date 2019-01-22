rem Tomo Olson
rem truncate table count_table;
set heading off
set pagesize 0
set linesize 100
rem set feedback off
spool goinsert.sql
select  'insert into count_table (owner,table_name)
values ('''||cc.owner||''''||','||''''||cc.table_name||''''||');'
from dba_tables cc
where owner = upper('&1')
and table_name not like '%BAK'
and table_name not like '%TMP'
;
@goinsert.sql
commit;
spool goinsert2.sql
select 'update count_table '||
 'set (created,num_rows) = 
 (select sysdate, /*+parallel ('||cc1.table_name||','||' 3) */ 
 count('||cc1.column_name||') 
 from '||cc1.owner||'.'||cc1.table_name||')
 where table_name = '''||cc1.table_name||''' 
 and num_rows is null
 and owner = '||''''||cc1.owner||''''||'
 and table_name = '||''''||cc1.table_name||''''||';'
 ||'
 commit;'
from dba_cons_columns cc1, dba_constraints c1
where c1.constraint_type = 'P'
and cc1.table_name = c1.table_name
and cc1.constraint_name = c1.constraint_name
and (cc1.table_name) in
     (select cc.table_name
     from dba_cons_columns cc, dba_constraints c
     where
     c.constraint_type = 'P'
     and cc.table_name = c.table_name
     and cc.constraint_name = c.constraint_name
     and cc.owner = upper('&&1')
     group by cc.table_name
     having count(cc.table_name) < 2)
;
spool off
@goinsert2
commit;
spool goinsert3.sql
select 'update count_table '||
 'set (created,num_rows) =
 (select sysdate, count(*)
 from '||c.owner||'.'||c.table_name||')
 where table_name = '''||c.table_name||'''
 and num_rows is null;'
 ||'
 commit;'
from count_table c
where num_rows is null
;
spool off
@goinsert3.sql
commit;
exit
exit
exit
