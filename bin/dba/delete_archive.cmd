CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;
CROSSCHECK archivelog all;
delete noprompt expired archivelog all;
delete noprompt archivelog all completed before 'sysdate-1';
