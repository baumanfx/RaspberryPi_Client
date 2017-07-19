#!/bin/bash

########################################################################
# Client script to retrieve work package instructions
# from a server.
# Felix W. Baumann
# 2017-07-19
# CC-BY
########################################################################

#export PRINT_CHROOT=/mount_rw/print_chroot

export PRINT_CHROOT=${1:-/mount_rw/print_chroot}
export PRINT_BASE_CHROOT=/mount_rw/chroot_base
export PRINT_RW_DIR=$( mktemp -d -p ${PRINT_CHROOT}/.. )

PWD=$( pwd )

if [ ! -d ${PRINT_BASE_CHROOT} ]; then

#	mkdir -p ${PRINT_BASE_CHROOT}
	mkdir -p ${PRINT_BASE_CHROOT}/etc
	mkdir -p ${PRINT_BASE_CHROOT}/dev
	mkdir -p ${PRINT_BASE_CHROOT}/proc
	mkdir -p ${PRINT_BASE_CHROOT}/usr/bin
	mkdir -p ${PRINT_BASE_CHROOT}/usr/sbin
	mkdir -p ${PRINT_BASE_CHROOT}/usr/lib
	mkdir -p ${PRINT_BASE_CHROOT}/var/lib
	mkdir -p ${PRINT_BASE_CHROOT}/bin
	mkdir -p ${PRINT_BASE_CHROOT}/tmp
	mkdir -p ${PRINT_BASE_CHROOT}/lib
	mkdir -p ${PRINT_BASE_CHROOT}/opt/client_repo
	mkdir -p ${PRINT_BASE_CHROOT}/opt/sensor_client_v2

	#ln -s /usr/lib ${PRINT_CHROOT}/lib
	#cd ${PRINT_CHROOT}
	#ln -s usr/lib lib
	#cd ${PWD}

	cp -dpR /lib/ld* ${PRINT_BASE_CHROOT}/lib

	cp /usr/sbin/python2		${PRINT_BASE_CHROOT}/usr/sbin/
	cp /usr/sbin/python			${PRINT_BASE_CHROOT}/usr/sbin/
	cp $( which env )			${PRINT_BASE_CHROOT}/usr/bin/
	cp -dpR /opt/Printrun		${PRINT_BASE_CHROOT}/opt/
	cp -dpR /usr/lib/python*	${PRINT_BASE_CHROOT}/usr/lib/

	cp /usr/lib/libz.*			${PRINT_BASE_CHROOT}/usr/lib/
	cp /usr/lib/libffi.*		${PRINT_BASE_CHROOT}/usr/lib/

	PROG_LIST="cp bash tee cat which mktemp rm dd sha256sum base64 cut tr mv timeout ps ld sleep id pwd ls find grep awk kill bc date tail dirname which python3"
	# http://unix.stackexchange.com/questions/76490/no-such-file-or-directory-on-an-executable-yet-file-exists-and-ldd-reports-al
	for prog in ${PROG_LIST}; do
		prog_path=$( which ${prog} )
		prog_dirname=$( dirname ${prog_path} )
		cp ${prog_path} ${PRINT_BASE_CHROOT}/${prog_dirname}/
		req_libs=$( ldd ${prog_path} | awk '{ print $3 }' | grep --color=never "^/" )
		for l in ${req_libs}; do
			lib_dirname=$( dirname ${l} )
			cp ${l} ${PRINT_BASE_CHROOT}/${lib_dirname}/
		done
	done

	cp -dpR /opt/client_repo/makerbot_connection	${PRINT_BASE_CHROOT}/opt/client_repo/
	cp -dpR /opt/sensor_client_v2/*					${PRINT_BASE_CHROOT}/opt/sensor_client_v2/

	cp $( ldd /usr/sbin/python  | awk '{ print $3 }' | grep --color=never "^/" ) ${PRINT_BASE_CHROOT}/usr/lib/
	cp $( ldd /usr/sbin/python2 | awk '{ print $3 }' | grep --color=never "^/" ) ${PRINT_BASE_CHROOT}/usr/lib/
	cp $( ldd $( which env )    | awk '{ print $3 }' | grep --color=never "^/" ) ${PRINT_BASE_CHROOT}/usr/lib/

	sudo mount -o bind /dev ${PRINT_BASE_CHROOT}/dev
	sudo mount -t proc proc ${PRINT_BASE_CHROOT}/proc
fi

# If the chroot base exists, mount an overlay
# to the execution dir. Make the base read only
# and store all changes to it in a temporary folder
if [ "${1}" == "preCreate" ]; then
	echo "Initial chroot base creation at ${PRINT_BASE_CHROOT}"
else
	sudo mount -t aufs -o br=${PRINT_RW_DIR}=rw:${PRINT_BASE_CHROOT}=ro -o udba=reval none ${PRINT_CHROOT}
fi
