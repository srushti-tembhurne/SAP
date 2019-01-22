select owner, object_name, object_type, status from dba_objects where status = 'INVALID' and OWNER = 'OLAPSYS' ;
select count(*) from dba_objects where status='INVALID';
SELECT comp_name, status, substr(version,1,10) as version from dba_registry;
exit

