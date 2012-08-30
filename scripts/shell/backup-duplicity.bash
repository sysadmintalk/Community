#!/bin/bash

#####
#####
#####
##### This script uses "duplicity" backup utility to handle Full and Incremental (snapshot) backups.
#####
##### REQUIREMENTS:
##### - Generate a GnuPG key pair
##### - Generate root SSH exchange key pair and have public key installed on remote server (root) for keyless login
##### - SSHFS package installed on server and make sure mounting ${BACKUP_HOSTS}:/ "read-only" (-o ro) works
#####
##### Only include what you want to back up in ${BACKUP_PATH}_$HOST lines.
##### (Variable $TMPDIR could possibly conflict with $TMPDIR variable from duplicity command. So we name ours $TMPDIR_minor.)
#####
#####
##### SysAdminTalk.Net script and licensed under MIT license.
#####
#####
#####

BASENAME=`basename $0`
DUPLICITY="/usr/bin/duplicity"
DATE_TIME=`date '+%F_%T'`
SSHFS_DIR="/mnt/sshfs"
GPG=`which gpg`
BACKUP_DIR="/backup"
SSHFS_PORT="22"
TMPDIR_minor="/tmp/.$BASENAME"
EMAIL_SUMFILE="$TMPDIR_minor/email_sumfile.txt"

##########
## For every single HOST in $BACKUP_HOSTS, there should be a line for it as BACKUP_PATH_$HOST="". Or else this script will fail.
##########
BACKUP_HOSTS="server1 server2 server3"
GNUPG_KEY="XXXXXXXX"
ADMIN="me@my_own_domain.com"

##########
## ONLY LIST FOLDERS UNDER /!!!
##########
BACKUP_PATH_server1="
/var/www
/etc/apache2
"
BACKUP_PATH_server2="
/home/user
/etc/ssh
"
BACKUP_PATH_server3="
/
"



##########
##########
########## YOU DO NOT NEED TO MAKE ANY MODIFICATIONS BELOW THIS LINE!!!
########## If you want to suggest ideas and/or have comments, please ask on SysAdminTalk.Net. Thank you.
##########
##########

EMAIL_HEADER="
\n<html>
\n<head>
\n<style type=\"text/css\">
\ntable {
\n\tborder-style:solid;
\n\tborder-width:1px;
\n\tborder-spacing:10px;
\n\tborder-collapse:collapse;
\n\tborder-color:rgb(0,0,0);
\n\twidth:30%;
\n}
\nth {
\n\tborder-style:solid;
\n\tborder-width:1px;
\n\tborder-color:rgb(0,0,0);
\n\tcolor:rgb(0,0,0);
\n\ttext-align:center;
\n}
\ntr {
\n\tborder-style:solid;
\n\tborder-width:1px;
\n\tborder-color:rgb(0,0,0);
\n}
\ntd {
\n\tborder-style:solid;
\n\tborder-width:1px;
\n\tborder-color:rgb(0,0,0);
\n\ttext-align:center;
\n\tpadding:5px;
\n}
\n\t.header {
\n\tbackground-color:rgb(217,230,248);
\n}
\n.footer {
\n\tfont-style:italic;
\n\tbackground-color:rgb(230,230,230);
\n}
\n.server {
\n\t//color:rgb(255,165,0);
\n}
\n.spath {
\n\t//color:rgb(0,0,255);
\n}
\n.dpath {
\n\t//color:rgb(128,0,128);
\n}
\n.success {
\n\tcolor:rgb(0,255,0);
\n}
\n.failure {
\n\tcolor:rgb(255,0,0);
\n}
\n</style>
\n</head>
\n<body>
"
EMAIL_END="
\n</body>
\n</html>
"



#####
##### Help page.
#####
help () {
	echo
	echo

	echo -e "\E[1;33mThis backup script uses \"duplicity\" and requires at least one argument.\E[0m"
	echo
	echo "Usage:"
	echo -e "   \E[1;34m$BASENAME\E[0m [\E[35mbackup\E[0m|\E[35mrestore\E[0m|\E[35mverify\E[0m|\E[35mlistbackup\E[0m]"
	echo
	echo "	Options:"
	echo -e "  	 	\E[35mbackup\E[0m - Automatic backup and no user intervention required."
	echo -e "   		\E[35mrestore\E[0m - Interactive, only outputs restore commands and not running them. \E[31mGnuPG passphrase REQUIRED!\E[0m"
	echo -e "   		\E[35mverify\E[0m - Automatic verification checks between latest backup archive and hosts. No user intervention required. \E[31mGnuPG passphrase REQUIRED!\E[0m"
	echo -e "   		\E[35mlistbackup\E[0m - List backup archives."

	echo
	echo
}


#####
##### Lock session.
#####
lock_session () {
	if [ -f "$TMPDIR_minor/$BASENAME.lck" ]; then
		echo
		echo "Lock file in place! Mutliple instance of this script run now allowed!"
		echo "($TMPDIR_minor/$BASENAME.lck)"
		echo
		echo "Lock file may also be in place from abnormal abort. Please check."
		echo

		exit 1
	elif [ ! -f "$TMPDIR_minor/$BASENAME.lck" ]; then
		touch $TMPDIR_minor/$BASENAME.lck
	fi
}


#####
##### Process variables.
#####
process_vars () {
	local ITEM=""
	BACKUP_HOST_PATH="BACKUP_PATH_$1"
	PATH_LIST=""
	PATH_LIST_BKUP_INC=""
	PATH_LIST=${!BACKUP_HOST_PATH}

	##########
	## Properly parses "--included $DIR $DIR2 $DIR3..." for duplicity command depending upon $1 passed.
	##########
	for ITEM in $PATH_LIST; do
		PATH_LIST_BKUP_INC+="--include /mnt/sshfs/${1}$ITEM "
	done
}


#####
##### Log console output to file. Keep only last 20 runs of log files in directory.
#####
log_console () {
	##########
	## On restore and verify we'll log console outputs to stdout and stderr file.
	##########
	[ `ls -l $TMPDIR_minor/log/*log* 2>/dev/null |wc -l` -gt "21" ] && ls -lt $TMPDIR_minor/log/*log* |tail -1 |awk '{print $9}' |xargs rm -f
	LOGFILE="$TMPDIR_minor/log/${0##*/}.$DATE_TIME.log"

	exec > >(tee ${LOGFILE})
	exec 2> >(tee ${LOGFILE}.err)
}


#####
##### SSHFS mounts all $BACKUP_HOSTS to /mnt/sshfs/$HOST.
#####
sshfs_mount () {
	##########
	## Make sure all required directories exists prior to SSHFS mounting.
	##########
	if [ ! -d "$SSHFS_DIR/$1" ]; then
		mkdir -p $SSHFS_DIR/$1
	elif [ ! -d "$BACKUP_DIR/$1" ]; then
		mkdir -p $BACKUP_DIR/$1
	fi

	##########
	## Unmount mount point if mounted.
	##########
	mount |grep sshfs |grep $1 >/dev/null 2>&1

	if [ "$?" -eq "0" ]; then
		/bin/fusermount -u $SSHFS_DIR/$1
	fi

	##########
	## SSHFS mount $1:/ from $BACKUP_HOSTS to $SSHFS_DIR/$1
	##########
	if [ ! -z "$SSHFS_PORT" ]; then
		/usr/bin/sshfs -p $SSHFS_PORT -o idmap=user -o ro root@$1:/ $SSHFS_DIR/$1
	elif [ -z "$SSHFS_PORT" ]; then
		/usr/bin/sshfs -o idmap=user -o ro root@$1:/ $SSHFS_DIR/$1
	fi
}


#####
##### Function checks for private key availability.
#####
check_gpg_secret_key () {
}
	$GPG --list-secret-keys |grep $GNUPG_KEY >/dev/null 2>&1

	if [ "$?" -ne "0" ]; then
		echo
		echo "GnuPG secret key is not available for decrypting! Make sure desired private key with ID \"$GNUPG_KEY\" is in your keyring first!"
		echo

		exit 1
	fi
}


#####
##### Function actually runs "$0 backup".
#####
mode_backup () {
	local HOST=""
	local ITEM=""
	local START_TIME=""
	EMAIL_BODY=""
	BACKUP_RTNVAL="0"

	cat /dev/null > $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.err

	START_TIME=`date`

	echo -e $EMAIL_HEADER > $EMAIL_SUMFILE
	echo -e "<table><thead class=\"header\"><th>Backup Source</th><th>Source Server</th><th>Destination Server</th><th>Status</th></thead><tbody>" >> $EMAIL_SUMFILE

	for HOST in $BACKUP_HOSTS; do
		process_vars $HOST

		##########
		## Goes out and call sshfs_mount().
		##########
		sshfs_mount $HOST

		##########
		## Backing up $HOST and log into individual files in $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt. SSHFS $HOST afterwards.
		##########
		echo "=====" > $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt
		echo "=====" $HOST >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt
		echo "=====" >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt

		echo >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt

		echo "(START TIME: `date '+%F_%T'`)" >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt

		echo >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt
		echo >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt
		echo >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt

		EMAIL_BODY+="<tr><td class=\"server\">$PATH_LIST</td><td class=\"spath\">$HOST</td><td class=\"dpath\">$HOSTNAME</td>"

		##### Backup job result ##### >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt
		$DUPLICITY --verbosity 8 --encrypt-key $GNUPG_KEY $PATH_LIST_BKUP_INC --exclude "**" $SSHFS_DIR/$HOST file://$BACKUP_DIR/$HOST >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt 2>> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.err

		BACKUP_RTNVAL=$?
		if [ "$BACKUP_RTNVAL" -ne "0" ]; then
			EMAIL_BODY+="<td class=\"failure\">FAILED</td>"
		else   
			EMAIL_BODY+="<td class=\"success\">Succeeded</td>"
		fi

		echo >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt

		##### Archives ##### >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt
		$DUPLICITY collection-status file://$BACKUP_DIR/$HOST >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt

		echo >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt
		echo >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt
		echo >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt

		echo "(END TIME: `date '+%F_%T'`)" >> $TMPDIR_minor/backup_result-$HOST.$DATE_TIME.txt

		/bin/fusermount -u $SSHFS_DIR/$HOST
	done

	EMAIL_BODY+="<tr><td colspan="4" bgcolor="#726E6D"><b>Start time:</b> $START_TIME</td>"
	EMAIL_BODY+="<tr><td colspan="4" bgcolor="#726E6D"><b>End time:</b> `date`</td>"
	EMAIL_BODY+="</tr>"
	echo $EMAIL_BODY >> $EMAIL_SUMFILE
	echo -e "</tbody></table>" >> $EMAIL_SUMFILE
	echo -e $EMAIL_END >> $EMAIL_SUMFILE

	return $BACKUP_RTNVAL
}


#####
##### Function actually runs "$0 restore".
#####
mode_restore () {
	local HOST=""
	local INPUT=""
	local LINE=""
	local TMP_DATE=""
	local EPOCH_TIME=""
	local INPUT_HOST=""
	local INPUT_ARCHIVE=""
	local SEARCH_STRING=""
	local DONE="1"

	##########
	## Run function to check and see if GnuPG private key is available.
	##########
	check_gpg_secret_key

	##########
	## Collect all available backup archives (Full and Incremental), assign it line number, awk all necessary fields, and output into respected $HOST text file.
	##########
	for HOST in $BACKUP_HOSTS; do
		$DUPLICITY collection-status file://$BACKUP_DIR/$HOST |egrep 'Full|Incremental' |cat -n |awk '{print $1,"\t" $2, $3, $4, $5, $6, $7}' > $TMPDIR_minor/collection-status-$HOST.out
	done

	##########
	## Asking user which server to pull backup archive info from.
	##########
	while true; do
		echo
		echo -e "\E[1;33mI have following servers on backup list, which one would you like to perform the restoration from?\E[0m"

		for HOST in $BACKUP_HOSTS; do
			echo -e "\t* \E[35m$HOST\E[0m"
		done

		echo
		read INPUT

		for HOST in $BACKUP_HOSTS; do
			if [ "$INPUT" == "$HOST" ]; then
				INPUT_HOST=$HOST

				echo "====="
				echo -e "\E[1;34mBelow are archived backups in database for $INPUT_HOST:\E[0m"
				echo "====="

				cat $TMPDIR_minor/collection-status-$HOST.out
				echo

				DONE="0"
			fi
		done

		if [ -z "$INPUT_HOST" ]; then
			echo "Sorry, but I don't have \"$INPUT_HOST\" in my backup database."
		fi

		[ "$DONE" -eq "0" ] && break
	done

	##########
	## Make sure user doesn't type a number that's greater than maximum number of archives.
	##########
	while true; do
		echo -e "\E[1;33mPlease choose a backup archive number to list all files+directories:\E[0m"
		read INPUT
		echo

		if [ "$INPUT" -gt `/usr/bin/wc -l $TMPDIR_minor/collection-status-$INPUT_HOST.out |awk '{print $1}'` ]; then
			echo "You chose a number that's out of range!"
			echo
		else
			INPUT_ARCHIVE=$INPUT
			break
		fi
	done

	##########
	## Converting whatever DATE/TIME from $TMPDIR_minor/collection-status-$INPUT_HOST.out file and converts to Epoch time.
	##########
	TMP_DATE=`/usr/bin/awk "{ if (NR==$INPUT_ARCHIVE) print }" $TMPDIR_minor/collection-status-$INPUT_HOST.out |/usr/bin/awk '{print $4" "$5"," " "$7" "$6}'`
	EPOCH_TIME=`/bin/date +%s -d "$TMP_DATE"`

	##########
	## Let user specify string to search the backup archive.
	##########
	echo -e "\E[1;33mIs there a specific string you want to look for? Sometimes the file+directories list can be large. \"yes\" or \"no\".\E[0m"

	while true; do
		read INPUT

		if [ "`echo $INPUT |tr "[:upper:]" "[:lower:]"`" == "yes" ]; then
			echo
			echo -e "\E[1;33mPlease let me know what specific string you are looking for?\E[0m"
			read SEARCH_STRING

			echo
			$DUPLICITY list-current-files --time $EPOCH_TIME file://$BACKUP_DIR/$INPUT_HOST > $TMPDIR_minor/restore-archive_dump_FULL-$INPUT_HOST.$DATE_TIME.out
			grep $SEARCH_STRING $TMPDIR_minor/restore-archive_dump_FULL-$INPUT_HOST.$DATE_TIME.out > $TMPDIR_minor/restore-archive_dump_GREP-$INPUT_HOST.$DATE_TIME.out

			cat $TMPDIR_minor/restore-archive_dump_GREP-$INPUT_HOST.$DATE_TIME.out |while read LINE; do
				echo -e "\E[1;35m$LINE\E[0m"
			done

			echo
			echo "(You can view the full list of files from $TMPDIR_minor/restore-archive_dump_FULL-$INPUT_HOST.$DATE_TIME.out!)"

			break
		elif [ "`echo $INPUT |tr "[:upper:]" "[:lower:]"`" == "no" ]; then
			echo
			$DUPLICITY list-current-files --time $EPOCH_TIME file://$BACKUP_DIR/$INPUT_HOST > $TMPDIR_minor/restore-archive_dump_FULL-$INPUT_HOST.$DATE_TIME.out

			cat $TMPDIR_minor/restore-archive_dump_FULL-$INPUT_HOST.$DATE_TIME.out |while read LINE; do
				echo -e "\E[1;35m$LINE\E[0m"
			done

			echo
			echo "(You can view the full list of files from $TMPDIR_minor/restore-archive_dump_FULL-$INPUT_HOST.$DATE_TIME.out!)"

			break
		else
			echo "Either \"yes\" or \"no\"..."
		fi
	done

	##########
	## Outputs restore commands to user.
	##########
	echo
	echo
	echo
	echo -e "\E[1;31mRESTORATION COMMANDS:\E[0m"
	echo
	echo -e "\E[1mThis script does not handle the \"REAL\" restoration process. However, we list the actual restore steps and commands below.\E[0m"
	echo
	echo "If you are restoring to the actual server itself, *make sure* SSHFS mount is in read-write and not read-only mode! You probably want to mount like something below."
	if [ ! -z "$SSHFS_PORT" ]; then
		echo -e "\t\E[1;34m/usr/bin/sshfs -p $SSHFS_PORT -o idmap=user $INPUT_HOST:/ $SSHFS_DIR/$INPUT_HOST\E[0m"
	elif [ -z "$SSHFS_PORT" ]; then
		echo -e "\t\E[1;34m/usr/bin/sshfs -o idmap=user $INPUT_HOST:/ $SSHFS_DIR/$INPUT_HOST\E[0m"
	fi
	echo

	echo -e "\t\E[35m!!! GnuPG passphrase REQUIRED! !!!\E[0m"
	echo

	# Restore from entire backup archive
	echo -e "If you want to \E[31mrestore the entire archive\E[0m to /restore/ (a local folder), *make sure* named restore folder exists on restore point first and then try following:"
	echo -e "\t\E[1;34m$DUPLICITY restore --time $EPOCH_TIME file://$BACKUP_DIR/$INPUT_HOST \E[1;33m/restore/\E[0m"
	echo "or if onto the actual server itself..."
	echo -e "\t\E[1;34m$DUPLICITY restore --time $EPOCH_TIME file://$BACKUP_DIR/$INPUT_HOST $SSHFS_DIR/$INPUT_HOST/\E[1;33mrestore/\E[0m\E[0m"
	echo

	# Restore a single directory
	echo -e "If you \E[31mrestore a directory called\E[0m "etc/apache2/", *make sure* named restore folder exists on restore point first and then try following: (Duplicity will not overwrite existing directory)"
	echo -e "\t\E[1;34m$DUPLICITY --file-to-restore \E[1;33metc/apache2\E[0m --time $EPOCH_TIME file://$BACKUP_DIR/$INPUT_HOST \E[1;33m/restore/apache2\E[0m"
	echo "or if onto the actual server itself..."
	echo -e "\t\E[1;34m$DUPLICITY --file-to-restore \E[1;33metc/apache2\E[0m --time $EPOCH_TIME file://$BACKUP_DIR/$INPUT_HOST $SSHFS_DIR/$INPUT_HOST/\E[1;33mrestore/apache2\E[0m"
	echo

	# Restore a single file
	echo -e "If you \E[31mrestore a file\E[0m called "etc/apache2/ports.conf", *make sure* named restore folder exists on restore point first and then try following:"
	echo -e "\t\E[1;34m$DUPLICITY --file-to-restore \E[1;33metc/apache2/ports.conf\E[0m --time $EPOCH_TIME file://$BACKUP_DIR/$INPUT_HOST \E[1;33m/restore/etc/apache2/ports.conf\E[0m"
	echo "or if onto the actual server itself..."
	echo -e "\t\E[1;34m$DUPLICITY --file-to-restore \E[1;33metc/apache2/ports.conf\E[0m --time $EPOCH_TIME file://$BACKUP_DIR/$INPUT_HOST $SSHFS_DIR/$INPUT_HOST/\E[1;33mrestore/etc/apache2/ports.conf\E[0m"
	echo
	echo
	echo -e "(Above file/path in \E[1;33myellow\E[0m means interchangeable.)"
	echo
	echo -e "Be sure to run \"\E[1;34mfusermount -u $SSHFS_DIR/$INPUT_HOST/\E[0m\" to unmount SSHFS volume."
	echo
}


#####
##### Function actually runs "$0 verify".
#####
mode_verify () {
	local INPUT=""
	local HOST=""
	local ITEM=""
	local ITEM_PATH=""
	local PATH_NO_ROOT=""
	local VERIFY_ONE_ITEM=""
	local PASSPHRASE=""

	##########
	## Run function to check and see if GnuPG private key is available.
	##########
	check_gpg_secret_key

	echo
	echo -e "\E[1mVERIFYING BACKUP ARCHIVE COULD TAKE A LONG TIME!!!\E[0m"
	echo
	echo "Enter a hostname to verify just that host or press [ENTER] to continue verify all hosts, or \"CTRL-C\" to exit."
	for ITEM_PATH in $BACKUP_HOSTS; do
		echo -e "\t* \E[35m$ITEM_PATH\E[0m"
	done
	echo "(If you CTRL-C at this point you'll need to remove the lock file - \"$TMPDIR_minor/$BASENAME.lck\"."

	read INPUT
	[ -n "$INPUT" ] && BACKUP_HOSTS=$INPUT

	echo
	echo -e "\E[1;33mVerifying backup archive against host for differences...\E[0m"
	echo -e "\E[35m!!! GnuPG passphrase REQUIRED! !!!\E[0m"

	while true; do
		echo
		##########
		## We are redirecting "read -p" from stderr to stdout because "-p prompt Display prompt on standard error, without a trailing newline, before attempting to read any input" (BASH man page).
		##########
		read -s -p "Please enter your GnuPG passphrase right now: " PASSPHRASE 2>&1
		echo
		read -s -p "Please enter your GnuPG passphrase again: " PASSPHRASE2 2>&1
		echo

		if [ "$PASSPHRASE" == "$PASSPHRASE2" ]; then
			export PASSPHRASE

			break
		else
			echo "Negative! Passphrases entered does not match! Try again!"
		fi
	done

	echo
	echo

	##########
	## Runs duplicity verify. GnuPG passphrase required. Unmount SSHFS mounts afterwards.
	##########
	for HOST in $BACKUP_HOSTS; do
		[ -n "$INPUT" ] && 
		process_vars $HOST

		##########
		## Goes out and call sshfs_mount().
		##########
		sshfs_mount $HOST

		if [ `echo $PATH_LIST |wc -w` -gt "1" ]; then
			while true; do
				echo -e "\E[1;33mMultiple restore paths found for server $HOST! Please select one of the paths below to do verification! Or if you want to verify all paths, type \"all\".\E[0m"

				for ITEM_PATH in $PATH_LIST; do
					echo -e "\t* \E[35m$ITEM_PATH\E[0m"
				done

				read LINE

				if [ `echo $LINE |tr "[:upper:]" "[:lower:]"` == "all" ]; then
					WHAT_TO_VERIFY="all"

					break
				fi

				for ITEM in $PATH_LIST; do
					if [ "$LINE" == "$ITEM" ]; then
						echo "You want to verify path \"$ITEM\"!"
						echo

						WHAT_TO_VERIFY="some"
						VERIFY_ONE_ITEM=$ITEM

						break 2
					fi
				done

				echo "\"$LINE\" doesn't seem to be one of the paths. Please try again!"
				echo
			done

			if [ "$WHAT_TO_VERIFY" == "all" ]; then
				for VERIFY_ALL_ITEM in $PATH_LIST; do
					echo
					echo -e "\E[1;34mChecking path \"$VERIFY_ALL_ITEM\" on $HOST...\E[0m"

					##########
					## Remove leading "/" from $VERIFY_ALL_ITEM
					##########
					PATH_NO_ROOT=`echo $VERIFY_ALL_ITEM |sed 's/^\///g'`

					$DUPLICITY verify --file-to-restore $PATH_NO_ROOT file://$BACKUP_DIR/$HOST $SSHFS_DIR/${HOST}$VERIFY_ALL_ITEM
					RTNVAL=$?

					if [ "$RTNVAL" -ne "0" ]; then
						echo
						echo -e "\E[31mCheck exited with an error! There may be file differences... if so, you probably want to run this script with \"backup\" as argument to sync everything!\E[0m"
						echo
					fi
				done
			elif [ "$WHAT_TO_VERIFY" == "some" ]; then
				echo -e "\E[1;34mChecking path \"$VERIFY_ONE_ITEM\" on $HOST...\E[0m"

				##########
				## Remove leading "/" from the single $VERIFY_ONE_ITEM
				##########
				PATH_NO_ROOT=`echo $VERIFY_ONE_ITEM |sed 's/^\///g'`

				$DUPLICITY verify --file-to-restore $PATH_NO_ROOT file://$BACKUP_DIR/$HOST $SSHFS_DIR/${HOST}$VERIFY_ONE_ITEM
				RTNVAL=$?

				if [ "$RTNVAL" -ne "0" ]; then
					echo
					echo -e "\E[31mCheck exited with an error! There may be file differences... if so, you should run this script with \"backup\" as argument to sync everything!\E[0m"
					echo
				fi

			fi

			/bin/fusermount -u $SSHFS_DIR/$HOST

			echo
			echo
		elif [ `echo $PATH_LIST |wc -w` -eq "1" ]; then
			echo -e "\E[1;34mChecking path \"`echo $PATH_LIST |sed "s/\n//"`\" on $HOST...\E[0m"

			##########
			## Remove leading "/" from the single $PATH_LIST.
			##########
			PATH_NO_ROOT=`echo $PATH_LIST |sed 's/^\///g'`

			$DUPLICITY verify --file-to-restore $PATH_NO_ROOT file://$BACKUP_DIR/$HOST $SSHFS_DIR/${HOST}`echo $PATH_LIST |sed "s/\n//"`
			RTNVAL=$?

			if [ "$RTNVAL" -ne "0" ]; then
				echo
				echo -e "\E[31mCheck exited with an error! There may be file differences... if so, you should run this script with \"backup\" as argument to sync everything!\E[0m"
				echo
			fi

			/bin/fusermount -u $SSHFS_DIR/$HOST

			echo
			echo
		fi
	done

	PASSPHRASE=""
}


#####
##### List backup archives.
#####
mode_listbackup () {
	for HOST in $BACKUP_HOSTS; do
		echo
		echo
		echo -e "\E[1;34mListing backup archives in $HOST...\E[0m"

		$DUPLICITY collection-status file://$BACKUP_DIR/$HOST
	done
}



#####
##### MAIN
#####

/usr/bin/which duplicity > /dev/null 2>&1
[ "$?" != "0" ] && echo "\"duplicity\" command cannot be fount in \$PATH. Please check and make sure \$PATH contains \"duplicity\" command." && exit 1

/usr/bin/which sshfs > /dev/null 2>&1
[ "$?" != "0" ] && echo "\"sshfs\" command cannot be fount in \$PATH. Please check and make sure \$PATH contains \"sshfs\" command." && exit 1

/usr/bin/which gpg > /dev/null 2>&1
[ "$?" != "0" ] && echo "\"gpg\" command cannot be fount in \$PATH. Please check and make sure \$PATH contains \"gpg\" command." && exit 1

##########
## Make sure $TMPDIR_minor(/log) is available for temporary processing and store. Purge temporary output files on every start run.
##########
[ ! -d "$TMPDIR_minor/log" ] && mkdir -p $TMPDIR_minor/log
[ `ls -l $TMPDIR_minor/*out 2>/dev/null |wc -l` -gt "11" ] && ls -lt $TMPDIR_minor/log/*log* |tail -1 |awk '{print $9}' |xargs rm -f

if [ -z "$1" ]; then
	help

	exit 1
elif [ "$1" == "backup" ]; then
	lock_session


	mode_backup

	EMAIL_SUBJECT="synchronize on [$HOSTNAME] (WebNX) for [`date "+%m/%d/%Y"`] "
	if [ "$BACKUP_RTNVAL" -ne "0" ]; then
		EMAIL_SUBJECT+="had FAILURES"
	else
		EMAIL_SUBJECT+="was successful"
	fi

	/usr/bin/mutt -e 'set content_type="text/html"' -s "${EMAIL_SUBJECT}" -a $TMPDIR_minor/backup_result-*.$DATE_TIME.txt -- $ADMIN < $EMAIL_SUMFILE

	rm -f $TMPDIR_minor/$BASENAME.lck
elif [ "$1" == "restore" ]; then
	lock_session

	log_console

	mode_restore

	rm -f $TMPDIR_minor/$BASENAME.lck
elif [ "$1" == "verify" ]; then
	lock_session

	log_console

	mode_verify

	rm -f $TMPDIR_minor/$BASENAME.lck
elif [ "$1" == "listbackup" ]; then
	log_console

	mode_listbackup
else
	echo
	echo "I did not understand your argument \"$1\"."

	help

	exit 1
fi

if [[ "$BACKUP_RTNVAL" -ne "0" && -s "$TMPDIR_minor/backup_result-$HOST.$DATE_TIME.err" ]]; then
	echo "Some backup errors were produced, please see $HOSTNAME:$TMPDIR_minor/backup_result-$HOST.$DATE_TIME.err for more details." |mailx -s "$BASENAME ($HOSTNAME) failed!" $ADMIN
fi



exit 0
