#!/bin/ksh -x
cat /etc/oratab|grep -v "^#"| while read TEMP
do
    SID=`echo $TEMP|cut -d: -f1`
    procs=$((`/bin/ps -ef | grep ora_smon_$SID | wc -l`-1))
    procs1=$((`/bin/ps -ef | grep ora_pmon_$SID | wc -l`-1))
    procs2=$((`/bin/ps -ef | grep ora_lgwr_$SID | wc -l`-1))
    procs3=$((`/bin/ps -ef | grep ora_ckpt_$SID | wc -l`-1))

    if [ $procs -eq 1 -o $procs1 -eq 1 -o $procs2 -eq 1 -o $procs3 -eq 1 ]
    then
        backup_dir=/oracle/backupdata/${ORACLE_SID}
        if [ -w $backup_dir ]
        then
            echo $SID
            export ORACLE_SID=$SID
            export ORACLE_HOME=`cat /etc/oratab | grep -v "^#" | grep -v "^*" | grep -v "^[0-9]" | grep "^$ORACLE_SID:" | cut -f2 -d: -s`
            export PATH=$PATH:$ORACLE_HOME/bin
            export RMAN_SID=`cat /etc/tnsnames.ora |  grep  "RM.*_A.WORLD"| cut -d '.' -f 1`
            echo $ORACLE_HOME
            echo $ORACLE_SID
            echo $RMAN_SID
            runFile=/oracle/backupdata/rman/RMAN_full_${ORACLE_SID}.cmd
            logFile=/oracle/backupdata/rman/RMAN_full_${ORACLE_SID}.log
            echo " " > ${runFile}
            echo " run { " >> ${runFile}
            echo "sql 'alter session set optimizer_mode=RULE';" >> ${runFile}
            echo "allocate channel 'dev_0' DEVICE TYPE disk;"   >> ${runFile}
            echo "allocate channel 'dev_1' DEVICE TYPE disk;"   >> ${runFile}
            echo "allocate channel 'dev_2' DEVICE TYPE disk;"   >> ${runFile}
            echo "allocate channel 'dev_3' DEVICE TYPE disk;"   >> ${runFile}
            echo "CROSSCHECK BACKUP;"                           >> ${runFile}
            echo "DELETE NOPROMPT EXPIRED BACKUP;"              >> ${runFile}
            echo "crosscheck copy;"                             >> ${runFile}
            echo "DELETE NOPROMPT EXPIRED COPY;"                >> ${runFile}
            echo "crosscheck archivelog all;"                   >> ${runFile}
            echo "delete noprompt expired archivelog all;"      >> ${runFile}
            echo "#sql 'alter system archive log current';"     >> ${runFile}
            echo "backup full database filesperset 1 format '/oracle/backupdata/${ORACLE_SID}/FULL/${ORACLE_SID}_FULL_DBF_%s_%t_%p.dbf'"  >> ${runFile}
            echo "current controlfile filesperset 1  format '/oracle/backupdata/${ORACLE_SID}/FULL/${ORACLE_SID}_FULL_CTL_%s_%t_%p.ctl'"  >> ${runFile}
            echo "plus archivelog filesperset 10 format '/oracle/backupdata/${ORACLE_SID}/FULL/${ORACLE_SID}_FULL_LOG_%s_%t_%p.log';"  >> ${runFile}
            echo "DELETE OBSOLETE;"                             >> ${runFile}
            echo "}"                                            >> ${runFile}
            rman target sys/hgySlDgnUf@${ORACLE_SID}_B log=${logFile} append  cmdfile=${runFile}
        else
            echo "Directory ${backup_dir} in not writeable OR doesn't exsist !!!" >> ${logFile}
            exit;
        fi
    else
        echo "Something Wrong with oratab entry: $SID"
    fi
done
