#!/bin/ksh -x
cat /etc/oratab|grep -v "^#"|grep -v "^$"| while read TEMP
do
    SID=`echo $TEMP|cut -d: -f1`
    procs=$((`/bin/ps -ef | grep ora_smon_$SID | wc -l`-1))
    procs1=$((`/bin/ps -ef | grep ora_pmon_$SID | wc -l`-1))
    procs2=$((`/bin/ps -ef | grep ora_lgwr_$SID | wc -l`-1))
    procs3=$((`/bin/ps -ef | grep ora_ckpt_$SID | wc -l`-1))

    if [ $procs -eq 1 -o $procs1 -eq 1 -o $procs2 -eq 1 -o $procs3 -eq 1 ]
    then
        backup_dir=/oracle/backuparch/${SID}
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
            getmaxSeq=/tmp/get_max_seq_${ORACLE_SID}.sql
            maxSeq=/tmp/max_seq_${ORACLE_SID}.out
            runFile=/oracle/backuparch/rman/RMAN_arch_${ORACLE_SID}.cmd
            logFile=/oracle/backuparch/rman/RMAN_arch_${ORACLE_SID}.log
            echo "set pagesize 0" >  ${getmaxSeq}
            echo "set linesize 120" >> ${getmaxSeq}
            echo "set feedback off" >> ${getmaxSeq}
        echo "select 'delete noprompt archivelog until sequence '||to_char( max(sequence#)-5)||' thread '||to_char( thread# )||' backed up 1 times to device type disk;' from V\$ARCHIVED_LOG where applied='YES' group by thread#;" >> ${getmaxSeq}
            echo "exit" >> ${getmaxSeq}
            $ORACLE_HOME/bin/sqlplus -s / as sysdba @${getmaxSeq} > ${maxSeq}
            echo " " > ${runFile}
            echo " run { " >> ${runFile}
            echo "sql 'alter session set optimizer_mode=RULE';" >> ${runFile}
            echo "allocate channel 'dev_0' DEVICE TYPE disk;"   >> ${runFile}
            echo "allocate channel 'dev_1' DEVICE TYPE disk;"   >> ${runFile}
            echo "allocate channel 'dev_2' DEVICE TYPE disk;"   >> ${runFile}
            echo "allocate channel 'dev_3' DEVICE TYPE disk;"   >> ${runFile}
            # echo "#sql 'alter system archive log current';"     >> ${runFile}
            echo "backup archivelog all filesperset 10 format '${backup_dir}/ARCH/${ORACLE_SID}_arc.LOG_%s_%t_%p.log';"  >> ${runFile}
            #echo "delete force noprompt archivelog all backed up 1 times to device type disk completed before 'sysdate - 1';"  >> ${runFile}
            cat "${maxSeq}" >> ${runFile}
            echo "backup current controlfile filesperset 1 format '${backup_dir}/ARCH/${ORACLE_SID}_arc.CTL_%s_%t_%p.ctl';" >> ${runFile}
            echo "DELETE OBSOLETE;"                             >> ${runFile}
            echo "}"                                            >> ${runFile}
            echo " `date` : $SID : Start Archvie deletion : " >> ${logFile}
            rman target sys/hgySlDgnUf@${ORACLE_SID}_B log=${logFile} append  cmdfile=${runFile}
        else
            echo "Directory ${backup_dir} in not writeable !!!"
            exit;
        fi
    else
        echo "Something Wrong with oratab entry: $SID"
    fi
done
