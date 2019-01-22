#!/bin/sh
$Id: //ariba/services/monitor/bin/everywhere/lms_cpuq.sh#2 $ 
SCRIPT_VERSION="15.1.0.0"
SCRIPT_NAME=${0}

##########################################################################################
#	
# THE SCRIPT TOOL IS PROVIDED "AS IS" AND WITHOUT WARRANTY. CUSTOMER'S USE OF THE
# SCRIPT TOOL IS AT CUSTOMER'S OWN RISK. BEA EXPRESSLY DISCLAIMS ANY AND ALL
# WARRANTIES, EXPRESS OR IMPLIED, INCLUDING ANY IMPLIED WARRANTIES OF MERCHANTABILITY,
# NON INFRINGEMENT OR FITNESS FOR A PARTICULAR PURPOSE, WHETHER ARISING IN LAW, CUSTOM,
# CONDUCT, OR OTHERWISE.
#
##########################################################################################



################################################################################
#
# this script is used to gather Operating System information for use by the
# Oracle LMS team
#
################################################################################



################################################################################
#
#********************Hardware Identification and Detection**********************
#
################################################################################


################################################################################
#
# time stamp
#

setTime() {

	# set time
	NOW="`date '+%m/%d/%Y %H:%M %Z'`"

}


##############################################################
# make echo more portable
#

echo_print() {
  #IFS=" " command 
  eval 'printf "%b\n" "$*"'
} 


################################################################################
#
# expand debug output
#

echo_debug() {
 
	if [ "$DEBUG" = "true" ] ; then
		$ECHO "$*" 
		$ECHO "$*" >> $ORA_DEBUG_FILE	 
	fi
	
} 

setOutputFiles() {



	FILE_EXT=${$}

	# set tmp directory and files we will use in the script
	TMPDIR="${TMPDIR:-/tmp}"
	ORA_IPADDR_FILE=$TMPDIR/oraipaddrs.$FILE_EXT
	ORA_MSG_FILE=$TMPDIR/oramsgfile.$FILE_EXT
	touch ${ORA_MSG_FILE}

	# this wil allow us to pass the ORA_MACHINE_INFO file name 
	# from a calling shell script
	ORA_MACHINFO_FILE=${1:-${TMPDIR}/${MACHINE_NAME}-lms_cpuq.txt} 

	ORA_PROCESSOR_FILE=$TMPDIR/$MACHINE_NAME-proc.txt

	# debug and error files
	ORA_DEBUG_FILE=$TMPDIR/oradebugfile.$FILE_EXT
	UNIXCMDERR=${TMPDIR}/unixcmderrs.$FILE_EXT

	
	$ECHO_DEBUG "\ndebug.function.setOutputFiles"
}

################################################################################
#
# set parameters based on user and hardware
#

setOSSystemInfo() {

	# debug
	$ECHO_DEBUG "\ndebug.function.setOSSystemInfo"

	USR_ID=$LOGNAME
	
	if [ "$USR_ID" = "root" ] ; then
		SCRIPT_USER="ROOT"
	else
		SCRIPT_USER=$LOGNAME
	fi
	
	SCRIPT_SHELL=$SHELL
	
	if [ "$OS_NAME" = "Linux" ] ; then
		set -xv	
		cat /proc/cpuinfo 
		set +xv
		if [ "$SCRIPT_USER" = "ROOT" ] ; then
			VERSION=`/usr/sbin/dmidecode 2>/dev/null | grep "# dmidecode" | cut -d ' ' -f3`

			MAJOR=`echo $VERSION | cut -d'.' -f1`
			MINOR=`echo $VERSION | cut -d'.' -f2`


			case "${MAJOR}" in
				2)
					if [ ${MINOR} -le 6 ] ; then
						set -xv
						/usr/sbin/dmidecode
						set +xv
					else
						set -xv
						/usr/sbin/dmidecode --type processor
						/usr/sbin/dmidecode --type system | egrep -i 'system information|manufacturer|product'
						set +xv
					fi
					;;
				*)
						set -xv
						/usr/sbin/dmidecode --type processor
						/usr/sbin/dmidecode --type system | egrep -i 'system information|manufacturer|product'
						set +xv
					;;
			esac
		else
			$ECHO "/usr/sbin/dmidecode command not executed - $SCRIPT_USER insufficient privileges"
		fi
		
		
		## Check for Linux LPAR config file
		if [ -s  /proc/ppc64/lparcfg ]; then
			## file exists so cat it
			cat /proc/ppc64/lparcfg
		fi
		
		## Oracle VM for x86
		if [ -s /OVS/Repositories ]; then
			for CFGFILE in `find /OVS/Repositories/*/VirtualMachines -name vm.cfg -print`
			do
			        $ECHO
			        $ECHO "#### BEGIN OVM Config File: $CFGFILE ####"
			        $ECHO OVM Config File: $CFGFILE
			        cat $CFGFILE
			        $ECHO  "#### END OVM Config File: $CFGFILE ####"
			done
			if [ -x /usr/sbin/xm ];
			then
		        	set -xv
		        	/usr/sbin/xm info
		        	set +xv
		        	$ECHO 
				if [ -x /usr/sbin/xenpm ];
				then
		        		set -xv
		      			/usr/sbin/xenpm get-cpu-topology
		        		set +xv
				fi
		        	$ECHO
		        	set -xv
		        	/usr/sbin/xm vcpu-list
		        	set +xv
			fi
			if [ -s  /var/log/ovs-agent.log ]; then
				## file exists so cat it
				grep "migrate_vm" /var/log/ovs-agent.log | tail
			fi
		fi

                ## Oracle Database Appliance
                if [ -x /opt/oracle/oak/bin/oakcli ];
                then
                	/opt/oracle/oak/bin/oakcli validate -d  > /dev/null 2>&1
			if [ $? -eq 0 ] ; then
	                	$ECHO "Oracle Database Appliance Processor Information"
       		         	set -xv
       	         		/opt/oracle/oak/bin/oakcli show processor
       	         		/opt/oracle/oak/bin/oakcli show core_config_key
       	         		set +xv
                		ODA_IMPL=`/opt/oracle/oak/bin/oakcli validate -d | grep "Type of environment found" |cut -d ":" -f3`
				echo "Implementation type : [$ODA_IMPL]"
			fi

                fi	
	
		RELEASE=`uname -r`
		IPADDR=`/sbin/ifconfig | grep inet | awk '{print $2}' | sed 's/addr://'`
	elif [ "$OS_NAME" = "SunOS" ] ; then
		set -xv
		/usr/sbin/prtconf 
		/usr/sbin/prtdiag
		set +xv
		/usr/sbin/psrinfo -p > /dev/null 2>&1
		isPoptionSupported=${?}

		if [ ${isPoptionSupported} -eq  0 ]
		then
			set -xv
			/usr/sbin/psrinfo -vp
			set +xv
		else
			set -xv
			/usr/sbin/psrinfo -v 
			set +xv
		fi
		## Get a list of cores on the system
		set -xv
		kstat cpu_info | egrep "core_id|on-line|offline" | awk ' /core_id/ { Cores = $0 } /state/ { threadState = $0 ; printf("%s|%s\n", Cores, threadState) }' | sort | uniq
		set +xv
		
		# Let's check if we're a VM - we need prtdiag to run successfully to do this
		/usr/sbin/prtdiag > /dev/null 2>&1
		if [ $? -eq 0 ] ; then
			SYSCON=`/usr/sbin/prtdiag | grep "System Configuration:" | cut -d':' -f2`
			$ECHO $SYSCON | egrep 'Sun Microsystems|Oracle Corporation'
			SUNCHECK=$?
				
			if [ $SUNCHECK -ne 0 ] ; then
				$ECHO "WARNING: Possible Virtual Machine $SYSCON"
			fi
		fi
		
		# Look for LDOMs and get LDOM version
		if [ -x /usr/sbin/virtinfo ] ; then
			set -xv
			/usr/sbin/virtinfo -ap
			set +xv
		fi
		
		if [ -x /usr/sbin/ldm ] ; then
			set -xv
			/usr/sbin/ldm -V
			/usr/sbin/ldm list
			/usr/sbin/ldm list-devices -p cpu
			set +xv
		fi
		
		# Get a list of LDOMs and get their configurations and core allocations
		if [ -x /usr/sbin/ldm ] ; then
			
			for DOM in `/usr/sbin/ldm list | grep -v "NAME" | cut -f1 -d' '`
			do
				set -xv
				/usr/sbin/ldm list -o resmgmt,core $DOM
				set +xv
			done
		fi
				
		RELEASE=`uname -r`
		MAJOR=`echo $RELEASE | cut -d'.' -f1`
		MINOR=`echo $RELEASE | cut -d'.' -f2`
		if [ ${MINOR} -gt 9 ] ; then
			set -xv
			# check and see if we're running in the global zone
			ZONENAME=`/sbin/zonename`
			set +xv
			if [ "$ZONENAME" != "global" ] ; then
				$ECHO "WARNING: ${0} executed in the $ZONENAME zone"
			fi
			set -xv
			# Get a list of zones and their UUIDs
			/usr/sbin/zoneadm list -cp
			# Loop through each zone and get its config info
			for CFG_ZONENAME in `/usr/sbin/zoneadm list -c`
			do
				$ECHO "\nZone $CFG_ZONENAME configuration:"
				/usr/sbin/zonecfg -z $CFG_ZONENAME info
			done
			/usr/sbin/pooladm
			set +xv
		fi

		IPADDR=`grep $MACHINE_NAME /etc/hosts | awk '{print $1}'`
	elif [ "$OS_NAME" = "HP-UX" ] ; then

                # Check if this is server is Instance Capacity System	
	        if [ -x /usr/sbin/icapstatus ] ; then
			set -xv
			/usr/sbin/icapstatus
						set +xv
			if [ $? -eq 2 ] ; then
				$ECHO "\n$MACHINE_NAME is not an Instant Capacity System\n"
			fi
		elif [ -x /usr/sbin/icod_stat ] ; then
			# Check deprecated icod_stat command
			set -xv
			/usr/sbin/icod_stat
			if [ $? -eq 2 ] ; then
				$ECHO "\n$MACHINE_NAME is not an Instant Capacity System\n"
			fi
			set +xv
		fi
		
		set -xv
		/usr/sbin/ioscan -fkC processor 
		set +xv
		set -xv
		/usr/bin/getconf MACHINE_MODEL
		set +xv
		RELEASE=`uname -r`
		IPADDR=`grep $MACHINE_NAME /etc/hosts | awk '{print $1}'`
 
		if [ -x /usr/contrib/bin/machinfo ] ; then
			set -xv
			/usr/contrib/bin/machinfo 
			set +xv
		fi

		## Check if this is a Itanium box
		## if so run hpvmstatus for IVM's and setboot to see if 
		## processors have HyperThread enabled
		MACH_HARDWARE=`uname -m`
		if [ "${MACH_HARDWARE}" = "ia64" ] ; then
				
			## Check to see if Integrity VMs are configured
			## Let's first check if hpvmstatus is installed in the default location
			if [ -x /opt/hpvm/bin/hpvmstatus ] ; then

				for IVM in `/opt/hpvm/bin/hpvmstatus -V | grep "Virtual Machine Name" | cut -d ':' -f2`
				do
					set -xv
				        /opt/hpvm/bin/hpvmstatus -V -P $IVM
				        set +xv
				done
				
			else
				# Let's just see if hpvmstatus can be found
				for IVM in `hpvmstatus -V | grep "Virtual Machine Name" | cut -d ':' -f2`
					do
					set -xv
					hpvmstatus -V -P $IVM
					set +xv
				done
			fi
			
			if [ -x /usr/sbin/setboot ] ; then
				set -xv
				/usr/sbin/setboot
				set +xv
			else
				## if setboot is not where it is should be
				## just try and see if it is in the PATH
				set -xv
				setboot
				set +xv
			fi
		fi
		
		## Check to see if nPars are configured
		if [ -x /usr/sbin/parstatus ] ; then
			set -xv
			/usr/sbin/parstatus			
			set +xv
		fi
		
		## Check to see if vPars are configured
		if [ -x /usr/sbin/vparstatus ] ; then
			set -xv
			# Get the name of the vPar where this script ran
			/usr/sbin/vparstatus -w
			
			# Get info for all the vPars
			/usr/sbin/vparstatus
			
			# check for dual core
			/usr/sbin/vparstatus -d
			set +xv
		fi
		
		## Check to see if Secure Resource Partitions/HP Containers are configured.
		if [ -x /opt/hpsrp/bin/srp ] ; then
			set -xv
			/opt/hpsrp/bin/srp -l -v -s prm			
			set +xv
		fi

		
	elif [ "$OS_NAME" = "AIX" ] ; then
		set -xv
		uname -Mm
		lsdev -Cc processor 
		/usr/sbin/prtconf 
		set +xv
		if [ -x /usr/bin/lparstat ] ; then
			VERSION=`uname -v`
			## Check OS version to see if we need to 
			## pass W option to get WPAR info
			if [ ${VERSION} -gt 5 ] ; then 
				set -xv
				/usr/bin/lparstat -iW
				set +xv
			else
				set -xv
				/usr/bin/lparstat -i
				set +xv
			fi
		fi
		
		if [ -x /usr/bin/errpt ] ; then
			set -xv
			/usr/bin/errpt -a -J CLIENT_PMIG_STARTED,CLIENT_PMIG_DONE | tee ${ORA_MSG_FILE}
			/usr/bin/ls -l ${ORA_MSG_FILE}
			set +xv
		fi
		
		if [ -x /usr/sbin/lsattr ] ; then
			for PROC in `lsdev -Cc processor | cut -d' ' -f1`
			do
				set -xv
				/usr/sbin/lsattr -EH -l ${PROC}
				set +xv
			done
		fi

		if [ "$SCRIPT_USER" = "ROOT" ] ; then
			set -xv
			/usr/sbin/smtctl
			set +xv
		else
			$ECHO "smtctl command not executed - $SCRIPT_USER insufficient privileges"
		fi

		RELEASE="`uname -v`.`uname -r`"
		IPADDR=`grep $MACHINE_NAME /etc/hosts | awk '{print $1}'` 
 
	elif [ "$OS_NAME" = "OSF1" -o "$OS_NAME" = "UnixWare" ] ; then
		set -xv
		/usr/sbin/psrinfo -v
		set +xv
		IPADDR=`grep $MACHINE_NAME /etc/hosts | awk '{print $1}'` 
	fi
	
	# populate IP adresses to file
	$ECHO "$IPADDR" > $ORA_IPADDR_FILE
	
}


################################################################################
#
# output welcome message.
#

beginMsg()
{
$ECHO "\n*******************************************************************************" >&2
$ECHO   "Oracle License Management Services 
License Agreement 
PLEASE SCROLL DOWN AND READ ALL OF THE FOLLOWING TERMS AND CONDITIONS OF THIS LICENSE AGREEMENT (\"Agreement\") CAREFULLY BEFORE DEMONSTRATING YOUR ACCEPTANCE BY CLICKING AN \"ACCEPT LICENSE AGREEMENT\" OR SIMILAR BUTTON OR BY TYPING THE REQUIRED ACCEPTANCE TEXT OR INSTALLING OR USING THE PROGRAMS (AS DEFINED BELOW). 

THIS AGREEMENT IS A LEGALLY BINDING CONTRACT BETWEEN YOU AND ORACLE AMERICA, INC. THAT SETS FORTH THE TERMS AND CONDITIONS THAT GOVERN YOUR USE OF THE PROGRAMS.  BY DEMONSTRATING YOUR ACCEPTANCE BY CLICKING AN \"ACCEPT LICENSE AGREEMENT\" OR SIMILAR BUTTON OR BY TYPING THE REQUIRED ACCEPTANCE TEXT OR INSTALLING AND/OR USING THE PROGRAMS, YOU AGREE TO ABIDE BY ALL OF THE TERMS AND CONDITIONS STATED OR REFERENCED HEREIN.  

IF YOU DO NOT AGREE TO ABIDE BY THESE TERMS AND CONDITIONS, DO NOT DEMONSTRATE YOUR ACCEPTANCE BY THE SPECIFIED MEANS AND DO NOT INSTALL OR USE THE PROGRAMS. 

YOU MUST ACCEPT AND ABIDE BY THESE TERMS AND CONDITIONS AS PRESENTED TO YOU – ANY CHANGES, ADDITIONS OR DELETIONS BY YOU TO THESE TERMS AND CONDITIONS WILL NOT BE ACCEPTED BY US AND WILL NOT MAKE PART OF THIS AGREEMENT.  THE TERMS AND CONDITIONS SET FORTH IN THIS AGREEMENT SUPERSEDE ANY OTHER LICENSE TERMS APPLICABLE TO YOUR USE OF THE PROGRAMS.

Definitions
\"We,\" \"us,\" and \"our\" refers to Oracle America, Inc.  \"Oracle\" refers to Oracle Corporation and its affiliates.  

\"You\" and \"your\" refers to the individual or entity that wishes to use the programs (as defined below) provided by Oracle. 

\"Programs\" or \"programs\" refers to the tool(s), script(s) and/or software product(s) and any applicable program documentation provided to you by Oracle which you wish to access and use to measure, monitor and/or manage your usage of separately-licensed Oracle software. 



Rights Granted
We grant you a non-exclusive, non-transferable limited right to use the programs, subject to the terms of this agreement, for the limited purpose of measuring, monitoring and/or managing your usage of separately-licensed Oracle software.  You may allow your agents and contractors (including, without limitation, outsourcers) to use the programs for this purpose and you are responsible for their compliance with this agreement in such use.  You (including your agents, contractors and/or outsourcers) may not use the programs for any other purpose. 

Ownership and Restrictions 
Oracle and Oracle’s licensors retain all ownership and intellectual property rights to the programs. The programs may be installed on one or more servers; provided, however, that you may only make one copy of the programs for backup or archival purposes. 

Third party technology that may be appropriate or necessary for use with the programs is specified in the program documentation, notice files or readme files.  Such third party technology is licensed to you under the terms of the third party technology license agreement specified in the program documentation, notice files or readme files and not under the terms of this agreement.    

You may not:
-	use the programs for your own internal data processing or for any commercial or production purposes, or use the programs for any purpose except the purpose stated herein; 
-	remove or modify any program markings or any notice of Oracle’s or Oracle’s licensors’ proprietary rights;
-	make the programs available in any manner to any third party for use in the third party’s business operations, without our prior written consent ;  
-	use the programs to provide third party training or rent or lease the programs or use the programs for commercial time sharing or service bureau use; 
-	assign this agreement or give or transfer the programs or an interest in them to another individual or entity; 
-	cause or permit reverse engineering (unless required by law for interoperability), disassembly or decompilation of the programs (the foregoing prohibition includes but is not limited to review of data structures or similar materials produced by programs);
-	disclose results of any program benchmark tests without our prior written consent; 
-	use any Oracle name, trademark or logo without our prior written consent .

Disclaimer of Warranty
ORACLE DOES NOT GUARANTEE THAT THE PROGRAMS WILL PERFORM ERROR-FREE OR UNINTERRUPTED.   TO THE EXTENT NOT PROHIBITED BY LAW, THE PROGRAMS ARE PROVIDED \"AS IS\" WITHOUT WARRANTY OF ANY KIND AND THERE ARE NO WARRANTIES, EXPRESS OR IMPLIED, OR CONDITIONS, INCLUDING WITHOUT LIMITATION, WARRANTIES OR CONDITIONS OF MERCHANTABILITY, NONINFRINGEMENT OR FITNESS FOR A PARTICULAR PURPOSE THAT APPLY TO THE PROGRAMS. 

No Right to Technical Support
You acknowledge and agree that Oracle’s technical support organization will not provide you with technical support for the programs licensed under this agreement.  

End of Agreement
You may terminate this agreement by destroying all copies of the programs. We have the right to terminate your right to use the programs at any time upon notice to you, in which case you shall destroy all copies of the programs. 

Entire Agreement
You agree that this agreement is the complete agreement for the programs and supersedes all prior or contemporaneous agreements or representations, written or oral, regarding such programs. If any term of this agreement is found to be invalid or unenforceable, the remaining provisions will remain effective and such term shall be replaced with a term consistent with the purpose and intent of this agreement. 

Limitation of Liability
IN NO EVENT SHALL ORACLE BE LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, PUNITIVE OR CONSEQUENTIAL DAMAGES, OR ANY LOSS OF PROFITS, REVENUE, DATA OR DATA USE, INCURRED BY YOU OR ANY THIRD PARTY.  ORACLE’S ENTIRE LIABILITY FOR DAMAGES ARISING OUT OF OR RELATED TO THIS AGREEMENT, WHETHER IN CONTRACT OR TORT OR OTHERWISE, SHALL IN NO EVENT EXCEED ONE THOUSAND U.S. DOLLARS (U.S. $1,000).  

Export 
Export laws and regulations of the United States and any other relevant local export laws and regulations apply to the programs.  You agree that such export control laws govern your use of the programs (including technical data) provided under this agreement, and you agree to comply with all such export laws and regulations (including \"deemed export\" and \"deemed re-export\" regulations).    You agree that no data, information, and/or program (or direct product thereof) will be exported, directly or indirectly, in violation of any export laws, nor will they be used for any purpose prohibited by these laws including, without limitation, nuclear, chemical, or biological weapons proliferation, or development of missile technology.   

Other
1.	This agreement is governed by the substantive and procedural laws of the State of California. You and we agree to submit to the exclusive jurisdiction of, and venue in, the courts of San Francisco or Santa Clara counties in California in any dispute arising out of or relating to this agreement. 
2.	You may not assign this agreement or give or transfer the programs or an interest in them to another individual or entity.  If you grant a security interest in the programs, the secured party has no right to use or transfer the programs.
3.	Except for actions for breach of Oracle’s proprietary rights, no action, regardless of form, arising out of or relating to this agreement may be brought by either party more than two years after the cause of action has accrued.
4.	Oracle may audit your use of the programs.  You agree to cooperate with Oracle’s audit and provide reasonable assistance and access to information.  Any such audit shall not unreasonably interfere with your normal business operations.  You agree that Oracle shall not be responsible for any of your costs incurred in cooperating with the audit.    
5.	The relationship between you and us is that of licensee/licensor. Nothing in this agreement shall be construed to create a partnership, joint venture, agency, or employment relationship between the parties.  The parties agree that they are acting solely as independent contractors hereunder and agree that the parties have no fiduciary duty to one another or any other special or implied duties that are not expressly stated herein.  Neither party has any authority to act as agent for, or to incur any obligations on behalf of or in the name of the other.  
6.	This agreement may not be modified and the rights and restrictions may not be altered or waived except in a writing signed by authorized representatives of you and of us.  
7.	Any notice required under this agreement shall be provided to the other party in writing.

Contact Information
Should you have any questions concerning your use of the programs or this agreement, please contact: 

License Management Services at:
http://www.oracle.com/us/corporate/license-management-services/index.html
Oracle America, Inc.
500 Oracle Parkway, 
Redwood City, CA 94065  
\n" | more


ANSWER=y

$ECHO "Accept License Agreement? "
	while [ -z "${ANSWER}" ]
	do
#		$ECHO "$1 [y/n/q]: \c" >&2
#  	read ANSWER
		#
		# Act according to the user's response.
		#
		case "${ANSWER}" in
			Y|y)
				return 0     # TRUE
				;;
			N|n|Q|q)
				exit 1     # FALSE
				;;
			#
			# An invalid choice was entered, reprompt.
			#
			*) ANSWER=
				;;
		esac
	done
}


################################################################################
#
# print out the search header
#

printMachineInfo() {
	
	NUMIPADDR=0
	
	# print script information
	$ECHO "[BEGIN SCRIPT INFO]"
	$ECHO "Script Name=$SCRIPT_NAME"
	$ECHO "Script Version=$SCRIPT_VERSION"
	$ECHO "Script Command options=$SCRIPT_OPTIONS"
	$ECHO "Script Command shell=$SCRIPT_SHELL"
	$ECHO "Script Command user=$SCRIPT_USER"
	$ECHO "Script Start Time=$NOW"
	# Get the approximate end time of the script by calling setTime again.
	setTime
	$ECHO "Script End Time=$NOW"
	$ECHO "[END SCRIPT INFO]"

	# print system information
	$ECHO "[BEGIN SYSTEM INFO]"
	$ECHO "Machine Name=$MACHINE_NAME"
	$ECHO "Operating System Name=$OS_NAME"
	$ECHO "Operating System Release=$RELEASE"

	for IP in `cat $ORA_IPADDR_FILE`
	do
		NUMIPADDR=`expr ${NUMIPADDR} + 1`
		$ECHO "System IP Address $NUMIPADDR=$IP"
	done
	
	cat ${ORA_PROCESSOR_FILE}
	cksum ${ORA_MSG_FILE} | cut -d' ' -f1-2

	$ECHO "[END SYSTEM INFO]"



}


################################################################################
#
#*********************************** MAIN **************************************
#
################################################################################

umask 022

# command line defaults
SCRIPT_OPTIONS=${*}
OUTPUT_DIR="."
LOG_FILE="true"
DEBUG="false"

# initialize script values
# set up default os non-specific machine values
OS_NAME=`uname -s`
MACHINE_NAME=`uname -n`

# set up $ECHO
ECHO="echo_print"

# set up $ECHO for debug
ECHO_DEBUG="echo_debug"

# search start time
setTime
SEARCH_START=$NOW
$ECHO "\nScript started at $SEARCH_START" 

# see if any check* Oracle LMS scripts are running is running, if not then print license. 
ps -eaf | grep LMS*.sh | grep -v grep >/dev/null 2>&1
if [ $? -eq 0 ] ; then
        STANDALONE="false"
else
        ps -eaf | grep "checkBEA" | grep -v grep >/dev/null 2>&1
        if [ $? -eq 0 ] ; then
              STANDALONE="false"
        else
              STANDALONE="true"
        fi
fi

if [ "${STANDALONE}" = "true" ] ; then

        # print welcome message
        beginMsg > /dev/null 2>&1
fi

# set output files
setOutputFiles ${1}

# set current system info
setOSSystemInfo> $ORA_PROCESSOR_FILE 2>&1


# Write machine infot to the output file
printMachineInfo > $ORA_MACHINFO_FILE 2>>$UNIXCMDERR

if [ -s $UNIXCMDERR ];
then
	cat $UNIXCMDERR >> $ORA_MACHINFO_FILE
fi

# search finish time
setTime
SEARCH_FINISH=$NOW

# if ${1} is set then we probably got called from checkBEAinst.sh and we  
# don't need to print the following
if [ "${1}" = "" ] ; then
	$ECHO "\nScript $SCRIPT_NAME finished at $SEARCH_FINISH"
	$ECHO "\nPlease collect the output file generated: $ORA_MACHINFO_FILE"
fi


# delete the tmp files
rm -rf $ORA_IPADDR_FILE $ORA_DEBUG_FILE $ORA_PROCESSOR_FILE $ORA_MSG_FILE $UNIXCMDERR 2>/dev/null

exit 0
