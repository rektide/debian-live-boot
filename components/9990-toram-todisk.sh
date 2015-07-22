#!/bin/sh

#set -e

test_btrfs ()
{
	btrfs filesystem show "${1}" && is_btrfs="$?"
}

copy_live_btrfs ()
{
	copyfrom="${1}"
	copytodev="${2}"
	copyto="${copyfrom}_swap"

	if [ -z "${MODULETORAM}" ]
	then
		size=$(fs_size "" ${copyfrom}/ "used")
	else
		MODULETORAMFILE="${copyfrom}/${LIVE_MEDIA_PATH}/${MODULETORAM}"

		if [ -f "${MODULETORAMFILE}" ]
		then
			size=$( expr $(ls -la ${MODULETORAMFILE} | awk '{print $5}') / 1024 + 5000 )
		else
			log_warning_msg "Error: toram-module ${MODULETORAM} (${MODULETORAMFILE}) could not be read."
			return 1
		fi
	fi

	if [ "${copytodev}" = "ram" ]
	then
		# copying to ram:
		freespace=$(awk '/^MemFree:/{f=$2} /^Cached:/{c=$2} END{print f+c}' /proc/meminfo)
		mount_options="-o size=${size}k"
		free_string="memory"
		fstype="tmpfs"
		dev="/dev/shm"
	elif [ "{copytodev}" = "btrram" ]
	then
		# copying to btrram:
		freespace=$(awk '/^MemFree:/{f=$2} /^Cached:/{c=$2} END{print f+c}' /proc/meminfo)
		# why bother committing frequently on ephemeral
		# zram handles compression instead of btrfs
		# no physical device needs to know about discarding (although perhaps zram might be able to use this?)
		# utterly corrupt device during crash? it wasn't going to come back anyways.
		# ssd is just a guess
		# we use an explicit subvol so there's outside namespace avail
		mount_options="-o commit=300,compress=no,nodiscard,nobarrier,ssd"
		free_string="zram memory"
		fstype="btrfs"
		dev="/dev/zram0"
		subvol="btrram-$(date +'%Y-%m-%d_%H-%m')"
	else
		# it should be a writable block device
		if [ -b "${copytodev}" ]
		then
			dev="${copytodev}"
			free_string="space"
			fstype=$(get_fstype "${dev}")
			freespace=$(fs_size "${dev}")
		else
			log_warning_msg "${copytodev} is not a block device."
			return 1
		fi
	fi

	if [ "${freespace}" -lt "${size}" ]
	then
		log_warning_msg "Not enough free ${free_string} (${freespace}k free, ${size}k needed) to copy live media in ${copytodev}."
		return 1
	fi

	# Custom ramdisk size
	if [ -z "${mount_options}" ] && [ -n "${ramdisk_size}" ]
	then
		# FIXME: should check for wrong values
		mount_options="-o size=${ramdisk_size}"
	fi

	# Btrram zram initialization and btrfs formatting
	if [ "${copytodev}" = "btrram" ]
	then
		# Initialize zram
		# https://www.kernel.org/doc/Documentation/blockdev/zram.txt
		modprobe lz4
		modprobe zram num_devices=4
		echo 4 > /sys/block/zram0/max_comp_streams
		echo lz4 > /sys/block/zram0/comp_algorithm
		echo "${ramdisk_size}" > /sys/block/zram0/disksize

		# Format Zram as Btrfs
		mkfs.btrfs /dev/zram0 -L btrram
	fi

	# begin copying (or uncompressing)
	mkdir "${copyto}"
	log_begin_msg "mount -t ${fstype} ${mount_options} ${dev} ${copyto}"
	mount -t "${fstype}" ${mount_options} "${dev}" "${copyto}"

	if [ "${extension}" = "tgz" ]
	then
		cd "${copyto}"
		tar zxf "${copyfrom}/${LIVE_MEDIA_PATH}/$(basename ${FETCH})"
		rm -f "${copyfrom}/${LIVE_MEDIA_PATH}/$(basename ${FETCH})"
		mount -r -o move "${copyto}" "${rootmnt}"
		cd "${OLDPWD}"
	else
		if [ -n "${MODULETORAMFILE}" ]
		then
			if [ -x /bin/rsync ]
			then
				echo " * Copying $MODULETORAMFILE to RAM" 1>/dev/console
				rsync -a --progress ${MODULETORAMFILE} ${copyto} 1>/dev/console # copy only the filesystem module
			else
				cp ${MODULETORAMFILE} ${copyto} # copy only the filesystem module
			fi
		else
			if [ -n "${copyfrom_btrram}" ]
			then
				echo " * Creating point in time snapshot of source" 1>/dev/console
				mkdir -p "${copyfrom}/vol"
				btrfs delete "${copyfrom}/vol/btrram"
				btrfs snapshot -r "${copyfrom}" "${copyfrom}/vol/btrram"
				sync

				echo " * Copying source btrfs medium to RAM btrfs" 1>/dev/console
				btrfs send "${copyfrom}/vol/${subvol}" | btrfs receive "${copyto}"
				btrfs snapshot -r "${copyto}/vol/${subvol}" "${copyto}/vol/${subvol}"

				echo " * Remounting newly installed subvolume" 1>/dev/console
				umount "${copyto}"
				mount -t "${fstype}" "${mount_options},subvol=/vol/${subvol}" "${dev}" "${copyto}"
				mv "${copyfrom}/vol/btrram" "${copyfrom}/vol/${subvol}"
			elif [ -x /bin/rsync ]
			then
				echo " * Copying whole medium to RAM" 1>/dev/console
				rsync -a --progress ${copyfrom}/* ${copyto} 1>/dev/console  # "cp -a" from busybox also copies hidden files
			else
				mkdir -p ${copyto}/${LIVE_MEDIA_PATH}
				cp -a ${copyfrom}/${LIVE_MEDIA_PATH}/* ${copyto}/${LIVE_MEDIA_PATH}
				if [ -e ${copyfrom}/${LIVE_MEDIA_PATH}/.disk ]
				then
					cp -a ${copyfrom}/${LIVE_MEDIA_PATH}/.disk ${copyto}
				fi
			fi
		fi

		umount ${copyfrom}
		mount -r -o move ${copyto} ${copyfrom}
	fi

	rmdir ${copyto}
	return 0
}
