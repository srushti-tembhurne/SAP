-- analyze the system table stats on S4 SV db, S2 SV db, SDB
-- run as SYSDBA
-- Sql to analyze the S4-SV dictionary stats after 11g upgrade.
-- By James Chiang


set timing on
exec dbms_stats.gather_schema_stats('SYS',gather_fixed=>TRUE);
exec dbms_stats.gather_fixed_objects_stats;
exec DBMS_STATS.GATHER_DICTIONARY_STATS();

exec dbms_stats.gather_table_stats('SYS','ATTRCOL$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec dbms_stats.gather_table_stats('SYS','COL$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec dbms_stats.gather_table_stats('SYS','COLTYPE$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec dbms_stats.gather_table_stats('SYS','HIST_HEAD$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec dbms_stats.gather_table_stats('SYS','OBJ$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec dbms_stats.gather_table_stats('SYS','TAB$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec dbms_stats.gather_table_stats('SYS','USER$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec DBMS_STATS.GATHER_DICTIONARY_STATS(estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);

exec dbms_stats.gather_table_stats('SYS','MLOG$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec dbms_stats.gather_table_stats('SYS','TABPART$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec dbms_stats.gather_table_stats('SYS','TABCOMPART$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec dbms_stats.gather_table_stats('SYS','PARTOBJ$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec dbms_stats.gather_table_stats('SYS','IND$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec dbms_stats.gather_table_stats('SYS','INDSUBPART$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec dbms_stats.gather_table_stats('SYS','FIXED_OBJ$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
-- exec dbms_stats.gather_table_stats('SYS','I_PARTOBJ$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);
exec dbms_stats.gather_table_stats('SYS','INDCOMPART$', estimate_percent=>100, method_opt=>'FOR ALL COLUMNS SIZE 1', cascade=>true);



quit;

