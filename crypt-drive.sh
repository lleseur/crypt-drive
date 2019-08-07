#!/bin/sh
#
# This script will unlock multiple drives encrypted with luks
# All the drives must be unlockable with one single key
# The key must be contained within a password protected luks partition
#
# The script will mount the luks partition containing the key
# Then it will unlock all the disks
# Then it will mount all the disks
#
# Each disk in $device_list will be unlocked to /dev/mapper/${device_name}-drive${n}-layer${m}
# With $n being the n-th disk unlocked
# With $m being the m-th luks layer
# Filesystem will be mounted to ${mount_dir}/drive${n}

# The directory where everything will be mounted
mount_dir='/mnt/crypt'
# Mount parameters for all drives
mount_param=''
# Mount type
# mount_type='multi' to have each drive mounted to ${mount_dir}/drive${n}
# mount_type='single' to have only the first drive to be mounted (useful for BTRFS)
# mount_type='none' to have no drive mounted at all
mount_type='multi'
# Override which drive to be mounted in single mode
mount_single_override=''
# Override mount directory the drive will be mounted to (default is ${mount_dir}/data)
mount_single_dir_override=''

# The file or device containing the luks partition with the key file
# Example: /dev/sdb1 or /path/to/file
keyfile_partition='/tmp/key'
# Key partition mount parameters
usb_mount_param='-o ro'
# Override key file path
# Default key file path is "${mount_dir}/key/key-${device_name}-level${n}.key" for the n-th level of encryption
keyfile_path_override=''

# List of encrypted devices to unlock, space separated
device_list='/tmp/disk1 /tmp/disk2'

# Device name to use for /dev/mapper
device_name="crypt"

# How many encryption layer
luks_level=1

# Merge filesystem with mergerfs
merge=0 # Boolean to enable mergerfs
merge_mount_dir='/mnt/crypt/merger'
# MergerFS mount options
merger_mount_param=''

# Default values
force=0
action=0 # 1 for lock, 2 for unlock, 3 for check, 4 for help, 5 for debug
config=''

# Redirect stdout to stderr
STDERR () {
cat - 1>&2
}

# Pre-execution tests
CHECK_CONFIG ()
{
	# Test for root permission
	if [ "$(whoami)" != "root" ]
	then
		echo 'Need root permission' | STDERR
		return 1 # Cannot ignore
	fi

	# Test if ${mount_dir} exists, if not, create it
	if [ ! -d "${mount_dir}" ]
	then
		echo "Creating ${mount_dir}"
		if ! mkdir -p "${mount_dir}"
		then
			echo "Could not create ${mount_dir}" | STDERR
			return 2 # Cannot ignore
		fi
	fi


	# Test if all devices are LUKS encrypted and if their mountpoint exists
	count=0
	for i in ${device_list}
	do
		count=$((count+1))
		if ! cryptsetup isLuks "${i}"
		then
			echo "${i} is not a LUKS device" | STDERR
			if [ ${force} -ne 1 ]; then return 4; fi
		fi

		# If mount in multi mode, need directory for each drive
		if [ "${mount_type}" = "multi" ]
		then
			if ! [ -d "${mount_dir}/drive${count}" ] || [ -n "$(ls -A ${mount_dir}/drive${count})" ]
			then
				if ! mkdir "${mount_dir}/drive${count}"
				then
					echo "${mount_dir}/drive${count} is not a directory or is not empty" | STDERR
					if [ ${force} -ne 1 ]; then return 5; fi
				fi
			fi
		fi
	done

	# If mount in single mode, need only one mountpoint
	if [ "${mount_type}" = "single" ]
	then
		if [ -z "${mount_single_dir_override}" ]
		then
			mount_single_dir_override="${mount_dir}/data"
		fi
		if ! [ -d "${mount_single_dir_override}" ] || [ -n "$(ls -A ${mount_single_dir_override})" ]
		then
			if ! mkdir "${mount_single_dir_override}"
			then
				echo "${mount_single_dir_override} is not a directory or is not empty" | STDERR
				if [ ${force} -ne 1 ]; then return 5; fi
			fi
		fi
	fi

	if ! cryptsetup isLuks "${keyfile_partition}"
	then
		echo "${keyfile_partition} is not a LUKS device" | STDERR
		if [ ${force} -ne 1 ]; then return 4; fi
	fi
	if ! [ -d "${mount_dir}/key" ] || [ -n "$(ls -A ${mount_dir}/key)" ]
	then
		if ! mkdir "${mount_dir}/key"
		then
			echo "${mount_dir}/key is not a directory or is not empty" | STDERR
			if [ ${force} -ne 1 ]; then return 5; fi
		fi
	fi

	if [ ${merge} -eq 1 ]
	then
		if [ ! -d "${merge_mount_dir}" ] || [ -n "$(ls -A \"${merge_mount_dir}\")" ]
		then
			if ! mkdir "${merge_mount_dir}"
			then
				echo "${merge_mount_dir} is not a directory or is not empty" | STDERR
				if [ ${force} -ne 1 ]; then return 5; fi
			fi
		fi
	fi

	return 0
}

MOUNT_KEY ()
{
	# First level unlock
	if ! cryptsetup luksOpen "${keyfile_partition}" "${device_name}-key-level1"
	then
		echo "Could not open ${keyfile_partition} with name ${device_name}-key-level1" | STDERR
		if [ ${force} -ne 1 ]; then return 6; fi
	fi
	level_count=1
	while [ ${level_count} -ne ${luks_level} ]
	do
		# Unlock level $level_count
		if ! cryptsetup luksOpen "/dev/mapper/${device_name}-key-level${level_count}" "${device_name}-key-level$((level_count+1))"
		then
			echo "Could not open /dev/mapper/${device_name}-key-level${level_count} with name ${device_name}-key-level$((level_count+1))" | STDERR
			if [ ${force} -ne 1 ]; then return 6; fi
		fi
		level_count=$((level_count+1))
	done

	# Mount key filesystem
	if ! mount ${usb_mount_param} "/dev/mapper/${device_name}-key-level${level_count}" "${mount_dir}/key"
	then
		echo "Could not mount /dev/mapper/${device_name}-key-level${level_count} to ${mount_dir}/key" | STDERR
		if [ ${force} -ne 1 ]; then return 7; fi
	fi

	# Verify the key file exists
	level_count=0
	while [ ${level_count} -ne ${luks_level} ]
	do
		level_count=$((level_count+1))

		# Get key file path
		if [ -z "${keyfile_path_override}" ]
		then
			keyfile_path="${mount_dir}/key/key-${device_name}-level${level_count}.key"
		else
			keyfile_path="${keyfile_path_override}"
		fi

		# Check key exists
		if [ ! -f "${keyfile_path}" ]
		then
			echo "${keyfile_path} does not exists or is not a regular file. Cannot use the key" | STDERR
			return 8 # Cannot ignore
		else
			echo 'Mounted key successfully'
			return 0
		fi
	done
}

MOUNT_DRIVES ()
{
	# Unlock and mount each drives
	drive_count=1
	for drive in ${device_list}
	do
		# Get key file path
		if [ -z "${keyfile_path_override}" ]
		then
			keyfile_path="${mount_dir}/key/key-${device_name}-level1.key"
		else
			keyfile_path="${keyfile_path_override}"
		fi

		# First level unlock
		if ! cryptsetup -d "${keyfile_path}" luksOpen "${drive}" "${device_name}-drive${drive_count}-level1"
		then
			echo "Could not open ${drive} with name ${device_name}-drive${drive_count}-level1" | STDERR
			if [ ${force} -ne 1 ]; then return 9; fi
		fi

		# Unlock each levels
		level_count=1
		while [ ${level_count} -ne ${luks_level} ]
		do
			# Get key file path
			if [ -z "${keyfile_path_override}" ]
			then
				keyfile_path="${mount_dir}/key/key-${device_name}-level$((level_count+1)).key"
			else
				keyfile_path="${keyfile_path_override}"
			fi

			# Unlock level $level_count
			if ! cryptsetup -d "${keyfile_path}" luksOpen "/dev/mapper/${device_name}-drive${drive_count}-level${level_count}" "${device_name}-drive${drive_count}-level$((level_count+1))"
			then
				echo "Could not open /dev/mapper/${device_name}-drive${drive_count}-level${level_count} with name ${device_name}-drive${drive_count}-level$((level_count+1))" | STDERR
				if [ ${force} -ne 1 ]; then return 9; fi
			fi
			level_count=$((level_count+1))
		done

		# Mount drive ${drive_count}
		if [ "${mount_type}" = "multi" ]
		then
			if ! mount ${mount_param} "/dev/mapper/${device_name}-drive${drive_count}-level${level_count}" "${mount_dir}/drive${drive_count}"
			then
				echo "Could not mount /dev/mapper/${device_name}-drive${drive_count}-level${level_count} to ${mount_dir}/drive${drive_count}" | STDERR
				if [ ${force} -ne 1 ]; then return 10; fi
			fi
			echo "Drive ${drive_count} mounted successfully"
		# If single mode we want to save the device path to mount later (the first one by default)
		elif [ "${mount_type}" = "single" ] && [ ${drive_count} -eq 1 ] && [ -z "${mount_single_override}" ]
		then
			mount_single_override="/dev/mapper/${device_name}-drive${drive_count}-level${level_count}"
			echo "Will mount drive ${drive_count} only"
		else
			echo "Drive ${drive_count} unlocked (no mount)"
		fi

		drive_count=$((drive_count+1))
	done

	# Mount drive in single mode
	if [ "${mount_type}" = "single" ]
	then
		if [ -z "${mount_single_dir_override}" ]
		then
			mount_single_dir_override="${mount_dir}/data"
		fi
		if ! mount ${mount_param} "${mount_single_override}" "${mount_single_dir_override}"
		then
			echo "Could not mount ${mount_single_override} to ${mount_single_dir_override}" | STDERR
			if [ ${force} -ne 1 ]; then return 10; fi
		fi
		echo 'Single drive mounted successfully'
	else
		echo 'All drives mounted successfully'
	fi
	return 0
}

MERGE ()
{
	if mergerfs ${merger_mount_param} "${mount_dir}/drive*" "${merge_mount_dir}"
	then
		echo 'Filesystem merged successfully'
		return 0
	else
		echo "Could not mount with mergerfs ${mount_dir}/drive* to ${merge_mount_dir}" | STDERR
		if [ ${force} -ne 1 ]; then return 11; fi
	fi
}

UMOUNT_KEY ()
{
	# Unmount key
	if ! umount "${mount_dir}/key"
	then
		echo "Error unmounting ${mount_dir}/key" | STDERR
		if [ ${force} -ne 1 ]; then return 12; fi
	fi

	# Lock each levels
	level_count=${luks_level}
	while [ ${level_count} -ne 0 ]
	do
		if ! cryptsetup close "/dev/mapper/${device_name}-key-level${level_count}"
		then
			echo "Could not close /dev/mapper/${device_name}-key-level${level_count}" | STDERR
			if [ ${force} -ne 1 ]; then return 13; fi
		fi
		level_count=$((level_count-1))
	done

	echo 'Unmounted key successfully'
	return 0
}

UNMERGE ()
{
	if umount "${merge_mount_dir}"
	then
		echo "Unmerged successfully"
		return 0
	else
		echo "Could not umount ${merge_mount_dir}" | STDERR
		if [ ${force} -ne 1 ]; then return 14; fi
	fi
}

UMOUNT_DRIVES ()
{
	# If mounted in single mode, umount only one drive
	if [ "${mount_type}" = "single" ]
	then
		if [ -z "${mount_single_dir_override}" ]
		then
			mount_single_dir_override="${mount_dir}/data"
		fi
		if ! umount "${mount_single_dir_override}"
		then
			echo "Could not unmount ${mount_single_dir_override}" | STDERR
			if [ ${force} -ne 1 ]; then return 15; fi
		fi
	fi

	# Unmount and lock all drives
	drive_count=1
	for drive in ${device_list}
	do
		# Unmount drive if multi mode
		if [ "${mount_type}" = "multi" ]
		then
			if ! umount "${mount_dir}/drive${drive_count}"
			then
				echo "Could not unmount ${mount_dir}/drive${drive_count}" | STDERR
				if [ ${force} -ne 1 ]; then return 15; fi
			fi
		fi

		# Lock all levels
		level_count=${luks_level}
		while [ ${level_count} -ne 0 ]
		do
			if ! cryptsetup close "/dev/mapper/${device_name}-drive${drive_count}-level${level_count}"
			then
				echo "Could not lock /dev/mapper/${device_name}-drive${drive_count}-level${level_count}" | STDERR
				if [ ${force} -ne 1 ]; then return 16; fi
			fi

			level_count=$((level_count-1))
		done
		echo "Drive ${drive_count} locked"
		drive_count=$((drive_count+1))
	done
	echo 'Unmounted and locked all drives'
	return 0
}


# Parse arguments
while [ $# -gt 0 ]
do
	i="$1"
	shift
	case "$i" in
		-c)
			config="$1"
			shift
			;;
		--config=*)
			config="${i#*=}"
			;;
		-f|--force)
			force=1
			;;
		lock)
			action=1
			;;
		unlock)
			action=2
			;;
		check)
			action=3
			;;
		--help|-h)
			action=4
			;;
		*)
			echo "Unknown parameter: $i. Type --help to get help" | STDERR
			exit 30
			;;
	esac
done

# Unlock
if [ ${action} -eq 2 ]
then
	if [ -z "${config}" ]
	then
		echo 'Config file not found' | STDERR
		exit 31
	fi
	. "${config}"

	if ! CHECK_CONFIG
	then
		exit $?
	fi
	if ! MOUNT_KEY
	then
		exit $?
	fi
	if ! MOUNT_DRIVES
	then
		exit $?
	fi
	if [ ${merge} -eq 1 ]
	then
		if ! MERGE
		then
			exit $?
		fi
	fi
	if ! UMOUNT_KEY
	then
		exit $?
	fi
# Lock
elif [ ${action} -eq 1 ]
then
	if [ -z "${config}" ]
	then
		echo 'Config file not found' | STDERR
		exit 31
	fi
	. "${config}"

	if [ ${merge} -eq 1 ]
	then
		if ! UNMERGE
		then
			exit $?
		fi
	fi
	if ! UMOUNT_DRIVES
	then
		exit $?
	fi
# Check
elif [ ${action} -eq 3 ]
then
	if [ -z "${config}" ]
	then
		echo 'Config file not found' | STDERR
		exit 31
	fi
	. "${config}"

	echo 'Checking...'
	if ! CHECK_CONFIG
	then
		exit $?
	else
		echo 'All OK.'
	fi
# Help
elif [ ${action} -eq 4 ]
then
	cat << EOF
Usage: crypt-drive.sh action [parameters]
Actions:
	lock			Unmount and lock the drives
	unlock			Unlock and mount the drives
	check			Check system for problems before unlock (automatically checked at unlock)
Parameters:
	-h, --help		Show this help message
	-f, --force		Try to ignore errors
	-c, --config	Config file path (example: "-c /path/crypt-drive.config" or "--config=/path/crypt-drive.config")
EOF
# Debug
elif [ ${action} -eq 5 ]
then
	if [ -z "${config}" ]
	then
		echo 'Config file not found' | STDERR
		exit 31
	fi
	. "${config}"

	echo 'Debug mode enabled'
	CHECK_CONFIG
	exit $?
# Unknown command
else
	echo 'Unknown action, type --help to get help' | STDERR
	exit 40
fi


exit 0
