#!/bin/bash

export PATH=$PATH:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin
export ORACLE_SID=BYRCN0
export ORAENV_ASK=NO
. oraenv >> /dev/null

for sid in `cat /etc/tnsnames.ora | grep -i "_B.WORLD" | cut -d '.' -f1`
do
      nohup echo " `date` : $sid : Start Archvie deletion : " >> ${sid}_delete_archives.log &
         nohup  $ORACLE_HOME/bin/rman target  sys/hgySlDgnUf@${sid} cmdfile=delete_archive.cmd log=${sid}_delete_archives.log  append &
           nohup echo " `date` : $sid : End Archvie deletion   : " >> ${sid}_delete_archives.log &
       done

