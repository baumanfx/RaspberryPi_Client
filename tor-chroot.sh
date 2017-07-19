#!/bin/bash

########################################################################
# Tor Chroot system for the client to execute workpackages in.
# Felix W. Baumann
# 2017-07-19
# CC-BY
########################################################################

export RW_DIR=/mount_rw
export TORCHROOT=${RW_DIR}/torchroot

if [ ! -d ${RW_DIR} ]; then
	echo "Root directory does not exist at ${TORCHROOT}/.. ERROR"
	exit 2
fi

mkdir -p ${TORCHROOT}
mkdir -p ${TORCHROOT}/etc/tor
mkdir -p ${TORCHROOT}/dev
mkdir -p ${TORCHROOT}/usr/bin
mkdir -p ${TORCHROOT}/usr/lib
mkdir -p ${TORCHROOT}/usr/share/tor
mkdir -p ${TORCHROOT}/var/lib

ln -s /usr/lib					${TORCHROOT}/lib
cp -v /etc/hosts				${TORCHROOT}/etc/
cp -v /etc/host.conf			${TORCHROOT}/etc/
cp -v /etc/localtime			${TORCHROOT}/etc/
cp -v /etc/nsswitch.conf		${TORCHROOT}/etc/
cp -v /etc/resolv.conf			${TORCHROOT}/etc/
cp -v /etc/tor/torrc			${TORCHROOT}/etc/tor/

cp -v /usr/bin/tor				${TORCHROOT}/usr/bin/
cp -v /usr/share/tor/geoip*		${TORCHROOT}/usr/share/tor/
cp -v /lib/libnss*				${TORCHROOT}/usr/lib/
cp -v /lib/libnsl* 				${TORCHROOT}/usr/lib/
cp -v /lib/ld-linux-*.so*		${TORCHROOT}/usr/lib/
cp -v /lib/libresolv* 			${TORCHROOT}/usr/lib/
cp -v /lib/libgcc_s.so*			${TORCHROOT}/usr/lib/
cp -v $( ldd /usr/bin/tor | awk '{ print $3 }' | grep --color=never "^/" ) ${TORCHROOT}/usr/lib/
cp -r /var/lib/tor				${TORCHROOT}/var/lib/
#chown -R tor:tor				${TORCHROOT}/var/lib/tor

sh -c "grep --color=never ^tor /etc/passwd > ${TORCHROOT}/etc/passwd"
sh -c "grep --color=never ^tor /etc/group > ${TORCHROOT}/etc/group"

mknod -m 644 ${TORCHROOT}/dev/random	c 1 8
mknod -m 644 ${TORCHROOT}/dev/urandom	c 1 9
mknod -m 666 ${TORCHROOT}/dev/null		c 1 3

sudo chown -R tor:tor			${TORCHROOT}

