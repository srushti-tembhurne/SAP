set pages 0
set line 3000
set feedback off
set trimspool on
spool /tmp/drop_ctx.sql
select 'exec dbms_logstdby.skip(''TABLE'','''||owner||''',''%'||index_name||'%'',null);' from dba_indexes where index_type='DOMAIN'
and owner like 'ANLIVE%'
order by owner, index_name
/

select 'exec dbms_logstdby.skip(''INDEX'','''||owner||''',''%'||index_name||'%'',null);' from dba_indexes where index_type='DOMAIN'
and owner like 'ANLIVE%'
order by owner, index_name
/

select 'exec dbms_logstdby.skip(''DML'','''||owner||''',''%'||index_name||'%'',null);' from dba_indexes where index_type='DOMAIN'
and owner like 'ANLIVE%'
order by owner, index_name
/
select 'exec dbms_logstdby.skip(''SCHEMA_DDL'','''||owner||''',''%'||index_name||'%'',null);' from dba_indexes where index_type='DOMAIN'
and owner like 'ANLIVE%'
order by owner, index_name
/

select 'exec dbms_logstdby.skip(''DML'','''||owner||''','''||table_name||''',null);' from
dba_tables where 
owner like 'ANLIVE%'
and table_name in('NDR_AUDIT_LOG0','NDR_TEXT_INDEX_LOG')
/

select 'drop index '||owner||'.'||index_name||';'
from dba_indexes where owner like 'ANLIVE%'
and index_type='DOMAIN'
/
spool off
