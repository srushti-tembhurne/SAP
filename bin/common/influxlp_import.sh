#!/bin/bash

# [HOA-136907] A simple utility used by telegraf to ingest Influx LP lines
# into influxdb. Some scripts are scheduled by salt/cfengine to run either 
# via cron, manual, etc (and are run by other users, like root).
#
# This script looks for a file named: influx.import.txt in the following 
# directory: /nfs/never/<user|anyDir>/stratus/.
#
# For example, mon11:/nfs/never/svcprod/stratus/influx.import.txt
# 
# The root (e.g., /nfs/never) can be changed with a parameter
# This will process n number of lines per run (also a parameter)

IMPORT_FILENAME="influx.import.txt"
IMPORTED_BACKUP_FILENAME="influx.import.backup.txt"

function usage {
    echo "Usage: $0 <sharedDirRoot> <linesToProcess>"
    echo "  sharedDirRoot:  Something like '/nfs/never'. By convention, will try to process all"
    echo "                  the following files within <sharedDirRoot>/*/stratus/import_influx_lp.txt"
    echo "                  if it exists."
    echo ""
    echo "  linesToProcess: Will print out the first n lines passed here of each file it processes" 
    exit 1
}

function main {
    # make sure we have two params
    if [ "$1" = "" ] || [ "$2" = "" ]; then
        usage
    fi

    numre='^[0-9]+$'
    rootDir=$1
    linesToProcess=$2
    if [ ! -d $rootDir ] || ! [[ $linesToProcess =~ $numre ]]; then
        usage
    fi

    for importFile in ${rootDir}/*/stratus/*; do 
        currentPath=${importFile%/*}

        # keep backups in /tmp, we need it initially to check up, may remove it after
        backupFileDir=/tmp/$(basename ${0})/${currentPath}
        backupImportFile=${backupFileDir}/${IMPORTED_BACKUP_FILENAME}
        if [ ! -d ${backupFileDir} ]; then
            mkdir -p ${backupFileDir}
        fi

        # let's see if a file we want to import is here (as read/write) and not zero-byte
        if [ "$(basename $importFile)" = "$IMPORT_FILENAME" ] && \
           [ -s $importFile ] && \
           [ -r $importFile ] && \
           [ -w $importFile ]; then 

    	    # if gz'd backup file exists, uncompress it so we can write what we import
    	    if [ -f "${backupImportFile}.gz" ]; then
                gunzip ${backupImportFile}.gz
            fi
 
            # output for telegraf
            head -n $linesToProcess $importFile 
	
            # output for backup
            head -n $linesToProcess $importFile >> $backupImportFile
	    gzip $backupImportFile 

            # remove the processed lines so they dont get processed next time
            sed -i -e 1,${linesToProcess}d $importFile
        fi 
    done

    exit 0
}

main $*
exit 1
