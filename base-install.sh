#!/bin/bash

########################################################################
# Install script for initial installation of base system for
# client-server model for execution of workpackages on a
# micro computing system, e.g. raspberry pi
# Felix W. Baumann
# 2017-07-19
# CC-BY
########################################################################

# Follow install instructions from
# https://archlinuxarm.org/platforms/armv7/broadcom/raspberry-pi-2
# but create a third partition
# copy files as instructed then
# copy the folder that represents the repo to /opt/client_repo
# sudo cp ../Artikel_Streaming/code/install-script.service /mnt/mmc/root/etc/systemd/system/
# sudo cp ../Artikel_Streaming/code/base-install.sh /mnt/mmc/root/usr/local/bin/
# sudo chmod u+x /mnt/mmc/root/usr/local/bin/base-install.sh
# enable install service
# cd /mnt/mmc/root/etc/systemd/system/multi-user.target.wants
# sudo ln -s ../install-script.service install-script.service

# TODO, change to F2FS for root dev
# https://wiki.archlinux.org/index.php/F2FS
DEBUG=false
TOR_ENABLE=true

START_DATE=$( date +"%Y-%m-%d %H:%M:%S" )

mount -o remount,rw /

sleep 2m
echo "Begin client install"

PACMAN_BIN=$( which pacman )
PACMAN_OPT="-S --noconfirm"
function installPkgs()
{
	if [ -f /var/lib/pacman/db.lck ]; then
		sudo rm -rf /var/lib/pacman/db.lck
	fi
	${PACMAN_BIN} -Sy
	sudo yes | pacman-db-upgrade
	${PACMAN_BIN} ${PACMAN_OPT} sudo
	sudo ${PACMAN_BIN} --noconfirm -Sc

	PACKAGE_LIST="base-devel git wget curl chrony incron cronie gawk python2 python python-pip python2-pip fail2ban ufw unzip rng-tools i2c-tools lm_sensors cython cython2 darkhttpd watchdog hidepid bc zip openbsd-netcat xmlstarlet python2-pyserial python-pyserial gnupg openssl banner dosfstools f2fs-tools readline libpcap python-pyusb"
	for pkg in ${PACKAGE_LIST}; do
		sudo ${PACMAN_BIN} ${PACMAN_OPT} ${pkg}
	done

	sudo yes | sudo pacman-db-upgrade
	sudo ${PACMAN_BIN} --noconfirm -Sc
	sudo ${PACMAN_BIN} --noconfirm -ruk0
}

function handleWatchdog()
{
	echo "watchdog-device = /dev/watchdog
max-load-1 = 24
realtime = yes
watchdog-timeout = 20
interval = 4
priority = 1" | sudo tee /etc/watchdog.conf

	sudo systemctl daemon-reload
	sudo systemctl enable watchdog

	echo "kernel.panic=60
kernel.panic_on_oops=1
kernel.panic_on_stackoverflow=1
kernel.dmesg_restrict=1
kernel.kptr_restrict=1
net.core.bpf_jit_enable=0
net.ipv4.tcp_rfc1337=1
net.ipv4.conf.all.rp_filter=1
net.ipv6.conf.all.rp_filter=1
net.ipv4.conf.all.log_martians=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0" | sudo tee /etc/sysctl.d/99-sysctl.conf
}

installPkgs
handleWatchdog

sudo mkdir -p /etc/skel/.ssh
VERS="0.1.2"

NET_DEV=eth0
EXT_IP=$( curl -s "https://api.ipify.org"  )
INT_IP=$( ip addr show ${NET_DEV} | grep "inet " | awk '{ print $2 }' | awk -F"/" '{ print $1 }' )
LOCATION=$( curl -s "https://freegeoip.net/csv/${EXT_IP}" )
ZONE_INFO=$( echo "${LOCATION}" | awk -F"," '{ print $8 }' )
LOCATION=$( echo "${LOCATION}" | tr -d "\r\n" )

CLIENT_ID=$( uuidgen -r | sha256sum | base64 -w 15 | cut -c -5 | tr  "\n" "-" | sed -e "s|-o=-$||" )
CLIENT_KEY=$( echo "$( uuidgen )$( date )$( dd if=/dev/urandom of=/dev/stdout bs=1 count=1024 2>/dev/null )" | sha256sum | base64 | head -1l | cut -c -32 )

USER_1="print-pi"
USER_2="p_client" # user_2 is the one that executes the client
USER_1_PW=$( uuidgen | md5sum | base64 | head -8c )
USER_2_PW=$( uuidgen | md5sum | base64 | head -8c )
ROOT_PW=$(   uuidgen | md5sum | base64 | head -8c )

MAC_ADDR=$( ip link show ${NET_DEV} | grep "ether" | awk '{ print $2 }' | md5sum | awk '{ print $1 }' )
A=$( echo "$( uuidgen )${MAC_ADDR}$( date )" | md5sum )
HOSTNAME=$( echo "${A:2:2}${A:8:2}${A:12:2}${A:20:2}${A:25:2}" )

RW_DIR=/mount_rw
REPO_DIR=/opt/client_repo

CLIENT_CONF_FILE=${RW_DIR}/.printing-client/client.conf

ID_SECRET=$( uuidgen | md5sum | base64 | head -8c )

REPO_HOST="bitbucket.org"
REPO_ADDR="${REPO_HOST}/[REPO].git"
REPO_USER="git"

SSH_PORT=3600
HTTP_PORT=8080

if ${DEBUG}; then
	ROOT_PW="justin"
	USER_1_PW="orwell"
fi

function handleFirewall()
{
	# firewall rules
	sudo ufw default deny incoming
	sudo ufw default allow outgoing
	#sudo ufw allow SSH
	sudo ufw allow ${SSH_PORT}/tcp # SSH on port 3600 as to thwart port scanning
	sudo ufw allow ${HTTP_PORT}/tcp

	sudo ufw enable
	sudo ufw logging off

	sudo systemctl daemon-reload
	sudo systemctl enable fail2ban
}

function handleTime()
{
	grep -v "server " /etc/chrony.conf | grep -v "makestep" > /tmp/chrony.conf
	cat /tmp/chrony.conf > /etc/chrony.conf
	rm -rf /tmp/chrony.conf

	echo "makestep 1.0 3
server 129.69.1.153 iburst iburst
server 129.69.1.170 iburst iburst
server rustime01.rus.uni-stuttgart.de iburst iburst
server rustime02.rus.uni-stuttgart.de iburst iburst
server ptbtime1.ptb.de iburst iburst
server ptbtime2.ptb.de iburst iburst" | sudo tee -a /etc/chrony.conf
	if [ -f /etc/localtime ]; then
		sudo rm -rf /etc/localtime
	fi
	sudo ln -s /usr/share/zoneinfo/${ZONE_INFO:-Europe/Berlin} /etc/localtime

	sudo systemctl daemon-reload
	sudo systemctl enable chrony
	sudo systemctl start chrony

	#http://thread.gmane.org/gmane.comp.time.chrony.user/1015
	echo -e "#!/bin/bash
#TSTAMP=\"\"
#CHR=a
#while [ \"${TSTAMP}\" == \"\" ]; do
#	TSTAMP=$( nc time-${CHR}.nist.gov 13 | awk '{ print $2" "$3 }' )
#	if [ \"${CHR}\" == \"a\" ]; then
#		CHR=b
#	else
#		CHR=c
#	fi
#	if [ ! \"${TSTAMP}\" == \"\" ]; then
#		date --set=\"${TSTAMP} UTC\"
#	fi
#done
chronyc -a 'burst 4/4'" | sudo tee /usr/local/bin/update-time.sh
	sudo chown root /usr/local/bin/update-time.sh
	sudo chmod u+x,o-rwx,g-rwx /usr/local/bin/update-time.sh
	grep -v "update-time.sh" /etc/crontab > /tmp/crontab.tmp
	cat /tmp/crontab.tmp | sudo tee /etc/crontab
	rm -rf /tmp/crontab.tmp
	echo "35 * * * * root run-parts /usr/local/bin/update-time.sh" | sudo tee -a /etc/crontab

	sudo ln -s /usr/local/bin/update-time.sh /etc/cron.hourly/update-time.sh
	( date && sudo /usr/local/bin/update-time.sh && date ) &
}

function userHandling()
{
	sudo groupadd ${USER_1}
	sudo groupadd ${USER_2}

	sudo useradd -r -g ${USER_1} -N -m ${USER_1}
	sudo useradd -r -g ${USER_2} -N -m ${USER_2}
	#sudo mkdir -p /home/${USER_1}/.ssh

	# passwords for root, user_1 and user_2
	echo -e "${USER_1_PW}\n${USER_1_PW}" | passwd ${USER_1}
	echo -e "${USER_2_PW}\n${USER_2_PW}" | passwd ${USER_2}
	echo -e "${ROOT_PW}\n${ROOT_PW}"     | passwd root

	# add user to sudo group
	sudo usermod -a -G uucp  ${USER_1}
	sudo usermod -a -G uucp  ${USER_2}
	sudo usermod -a -G disk  ${USER_2}
	sudo usermod -a -G wheel ${USER_1}

	#sudo permission for user_1
	echo "Cmnd_Alias CDAEMONSVC = /usr/bin/systemctl stop client-daemon, /usr/bin/systemctl start client-daemon, /usr/bin/systemctl restart client-daemon
root ALL=(ALL) ALL
%wheel ALL=(ALL) NOPASSWD: ALL
#p_client ALL=(nobody) NOPASSWD: ALL
p_client ALL=(nobody) NOPASSWD: /bin/mktemp, /usr/bin/tee
p_client ALL=(root) NOPASSWD: /usr/bin/reboot, /usr/bin/poweroff /usr/bin/umount, /usr/bin/rm, /usr/bin/mknod, /usr/bin/chroot, /usr/bin/mount, CDAEMONSVC" | sudo tee /etc/sudoers
	sudo chmod o-rwx,u-wx,g-wx /etc/sudoers
	sudo chown root:root /etc/sudoers
	sudo userdel -r alarm
}

function sshKeys()
{
	sudo -u ${USER_1} mkdir -p /home/${USER_1}/.ssh
	sudo -u ${USER_1} ssh-keygen -b 4096 -t ed25519 -f /home/${USER_1}/.ssh/id_rsa -P ""

	echo "" | sudo tee /home/${USER_1}/.ssh/authorized_keys
	sudo chown -R ${USER_1}:${USER_1} /home/${USER_1}/.ssh

	sudo -u ${USER_2} mkdir -p /home/${USER_2}/.ssh
	sudo -u ${USER_2} ssh-keygen -b 4096 -t ed25519 -f /home/${USER_2}/.ssh/id_rsa -P ""
	sudo chown -R ${USER_2}:${USER_2} /home/${USER_2}/.ssh

	if [ ! -d /root/.ssh ]; then
		sudo mkdir -p /root/.ssh
	else
		if [ -f /root/.ssh/id_rsa ]; then
			sudo mv /root/.ssh/id_rsa /root/.ssh/id_rsa-old
			sudo mv /root/.ssh/id_rsa.pub /root/.ssh/id_rsa.pub-old
		fi
	fi
	sudo ssh-keygen -b 4096 -t ed25519 -f /root/.ssh/id_rsa -P ""
}

function etcHandling()
{
	echo "${HOSTNAME}" | sudo tee /etc/hostname
	sudo hostname ${HOSTNAME}

	echo "Client Install: $( date +"%Y-%m-%d %H:%M:%S" )
Hostname:       ${HOSTNAME}
Mac:            ${MAC_ADDR}
Adaptor ID:     ${CLIENT_ID}
---
Cloud 3D Printing Service - F. Baumann 2017
Vers. ${VERS}" | sudo tee /etc/issue
	echo -e "Cloud Printing Service Adaptor Client\nVers. ${VERS}\nsystemctl status client-daemon\nBased on Arch Linux ARM - http://archlinuxarm.org\n..." | sudo tee /etc/motd
}

function installYaourt()
{
	sudo mkdir -p /tmp/aur-install
	sudo chown -R ${USER_1}:${USER_1} /tmp/aur-install

	cd /tmp/aur-install
	chmod o+rw /tmp/aur-install

	curl -s -k -O "https://aur.archlinux.org/cgit/aur.git/snapshot/package-query.tar.gz"
	sudo -u ${USER_1} tar -xvzf package-query.tar.gz
	cd /tmp/aur-install/package-query
	sudo -u ${USER_1} makepkg --noconfirm -si

	cd /tmp/aur-install
	curl -s -k -O  "https://aur.archlinux.org/cgit/aur.git/snapshot/yaourt.tar.gz"
	sudo -u ${USER_1} tar -xvzf yaourt.tar.gz
	cd /tmp/aur-install/yaourt
	sudo -u ${USER_1} makepkg --noconfirm -si

	sudo rm -rf /tmp/aur-install
}

function installPrintrun()
{
	if [ ! "$( which yaourt )" == "" ]; then
		sudo -u ${USER_1} yaourt --noconfirm -S printrun
	else
		echo "Could not locate yaourt"
	fi
	cd /tmp

	sudo pip install --upgrade pip
	sudo pip install pyserial
	sudo pip install RPIO
	sudo pip install psutil
	sudo pip install stopit
	sudo pip install configparser
	sudo pip install pyusb

	sudo pip2 install --upgrade pip
	sudo pip2 install pyserial
	sudo pip2 install RPIO
	sudo pip2 install psutil
	sudo pip2 install stopit
	sudo pip2 install configparser
	sudo pip2 install pyusb

	cd /opt
	git clone -v https://github.com/kliment/Printrun.git /opt/Printrun

	sudo ${PACMAN_BIN} ${PACMAN_OPT} python2-pmw python-pmw
	sudo ${PACMAN_BIN} ${PACMAN_OPT} wxpython2.8 wxpython

	cd /opt/Printrun
	sudo $( which python2 ) /opt/Printrun/setup.py install
	sudo $( which python2 ) /opt/Printrun/setup.py build_ext --inplace
	sudo chown -R ${USER_2} /opt/Printrun
	cd /
}

# Only for debian systems
#curl -sL https://deb.nodesource.com/setup_6.x | sudo -E bash -
function installNodeJS()
{
	sudo fallocate -l 512M ${RW_DIR}/swapfile
	sudo chmod 600 ${RW_DIR}/swapfile
	sudo mkswap ${RW_DIR}/swapfile
	sudo swapon ${RW_DIR}/swapfile

	sudo ${PACMAN_BIN} ${PACMAN_OPT} nodejs npm
	sudo npm cache clean
	sudo swapoff -a
	sudo rm -rf ${RW_DIR}/swapfile
}

function removePkgs()
{
	sudo ${PACMAN_BIN} -Rsn --noconfirm openntpd
	sudo ${PACMAN_BIN} -Rsn --noconfirm haveged
	sudo ${PACMAN_BIN} -Rsn --noconfirm fake-hwclock
	sudo ${PACMAN_BIN} -Rsn --noconfirm logrotate
	sudo ${PACMAN_BIN} -Rsn --noconfirm man-pages man-db
	sudo ${PACMAN_BIN} -Rsn --noconfirm groff
	sudo ${PACMAN_BIN} -Rsn --noconfirm nano
	sudo ${PACMAN_BIN} -Rsn --noconfirm vi

	sudo rm -rf /etc/systemd/system/multi-user.target.wants/haveged.service

	# https://wiki.archlinux.org/index.php/Pacman/Tips_and_tricks#Removing_unused_packages_.28orphans.29
	sudo ${PACMAN_BIN} -Rsn --noconfirm $( sudo ${PACMAN_BIN} -Qtdq ) # remove orphaned packages
}

function handleRepo()
{
	# download git repo
	echo "[PUBLIC KEY TO ACCESS THE REPO]" | sudo -u ${USER_2} tee ${RW_DIR}/${USER_2}/.ssh/common_key
	sudo chown ${USER_2}:${USER_2} ${RW_DIR}/${USER_2}/.ssh/common_key
	sudo chmod o-rwx,g-rwx ${RW_DIR}/${USER_2}/.ssh/common_key
	sudo mkdir ${REPO_DIR}
	sudo chown ${USER_2}:${USER_2} ${REPO_DIR}

	if ${DEBUG}; then
		echo "Not cloning ${REPO_ADDR}, as no anonymous connection is setup. Will transfer to github"
	else
		# http://stackoverflow.com/questions/4565700/specify-private-ssh-key-to-use-when-executing-shell-command-with-or-without-ruby
		sudo -u ${USER_2} ssh-keyscan ${REPO_HOST} | sudo -u ${USER_2} tee ${RW_DIR}/${USER_2}/.ssh/known_hosts
		PWD_2=$( pwd )
		cd /tmp
		sudo -u ${USER_2} ssh-agent bash -c "ssh-add ${RW_DIR}/${USER_2}/.ssh/common_key ; git clone --verbose ssh://${REPO_USER}@${REPO_ADDR} ${REPO_DIR}"
		cd ${PWD_2}
		#git clone ssh://${REPO_USER}@${REPO_ADDR} ${REPO_DIR}
	fi

	if [ ! -d ${REPO_DIR} ]; then
		echo "Repo could not be cloned, error"
	fi

	# copy jail.conf from repo to /etc/fail2ban/
	sudo cp ${REPO_DIR}/jail.conf /etc/fail2ban
	# copy sshd_config from repo to /etc/ssh/
	sudo cp ${REPO_DIR}/sshd_config /etc/ssh/sshd_config

	sudo ${PACMAN_BIN} --noconfirm -Syuu
	yes | sudo pacman-db-upgrade
	# copy client-daemon.service from repo to /etc/systemd/system
	sudo cp ${REPO_DIR}/certificate.pem /etc/ssl/certs/print-service.pem
	sudo cp ${REPO_DIR}/50-tty.rules /etc/udev/rules.d/
	sudo cp ${REPO_DIR}/55-cam-devs.rules /etc/udev/rules.d/
	sudo cp ${REPO_DIR}/45-printer-devs.rules /etc/udev/rules.d/

	sudo cp ${REPO_DIR}/sign-key.crt /mount_rw/.printing-client/
	sudo chown ${USER_2} /mount_rw/.printing-client/sign-key.crt
	sudo chmod 644 /mount_rw/.printing-client/sign-key.crt

	# TODO remove, obsolete by using openssl certs
	gpg --import ${REPO_DIR}/service.gpg
	sudo -u ${USER_2} gpg --import ${REPO_DIR}/service.gpg

	sudo systemctl daemon-reload

	sudo systemctl restart fail2ban
	sudo systemctl disable install-script.service
}

function installNetdiscover()
{
	cd /tmp
	wget -O /tmp/netdiscover.tar.gz "http://downloads.sourceforge.net/project/netdiscover/netdiscover/0.3-pre-beta7-LINUXONLY/netdiscover-0.3-pre-beta7-LINUXONLY.tar.gz?r=https%3A%2F%2Fsourceforge.net%2Fprojects%2Fnetdiscover%2F%3Fsource%3Dtyp_redirect&ts=1480366383&use_mirror=netassist"
	tar xzf /tmp/netdiscover.tar.gz
	cd /tmp/netdiscover-*
	./configure
	make
	sudo make install
}

function handleClientDaemon()
{
	sudo chown ${USER_2} /opt/client_repo/client.sh
	sudo chmod o-rwx,g-rwx,u+rwx /opt/client_repo/client.sh

	sudo chown ${USER_2} ${REPO_DIR}/executer-chroot.sh
	sudo chmod u+x ${REPO_DIR}/executer-chroot.sh

	sudo cp ${REPO_DIR}/client-daemon.service /etc/systemd/system/

	sudo systemctl daemon-reload

	sudo systemctl enable client-daemon.service
	sudo systemctl start client-daemon.service
}

#sudo systemctl restart udev

function diskHandling()
{
	###
	# format rw partition
	# create tmpfs config in fstab

	if [ -d /var/lib/dhcp ]; then
		sudo rm -rf /var/lib/dhcp
	fi
	sudo mkdir /var/lib/dhcp
	sudo mkdir /var/spool/mqueue
	#sudo mkfs.ext4 -FF -e remount-ro -L "rw-disk" -t ext4 -v -m 0 /dev/mmcblk0p3
	#sudo mkfs -F -l "rw-disk" -t f2fs -v /dev/mmcblk0p3
	sudo mkfs.f2fs -l "rw-disk" -o 0 /dev/mmcblk0p3
	# client data on /mount_rw or /mount_rw/tmp
	echo "/dev/mmcblk0p2	/	f2fs	ro,noatime	0	0
/dev/mmcblk0p1	/boot	vfat	ro,noatime	0	0
tmpfs	/tmp	tmpfs    defaults,noatime,nosuid,size=32m	0	0
tmpfs	/var/tmp	tmpfs	defaults,noatime,nosuid,size=16m	0	0
tmpfs	/var/log	tmpfs	defaults,noatime,nosuid,mode=0755,size=32m	0	0
#tmpfs	/var/run	tmpfs	defaults,noatime,nosuid,mode=0755,size=2m	0	0
tmpfs	/var/lib/dhcp	tmpfs	defaults,noatime,nosuid,mode=0755,size=2m	0	0
tmpfs	/run	tmpfs	defaults,noatime,nosuid,mode=0755,size=2m	0	0
tmpfs	/var/spool/mqueue	tmpfs	defaults,noatime,nosuid,mode=0700,gid=12,size=12m	0	0
/dev/mmcblk0p3	${RW_DIR}	f2fs	noatime,relatime,nodev,nosuid,acl,user_xattr	0	0" | sudo tee /etc/fstab
#,,errors=remount-ro
	cd /var
	sudo rm -rf /var/run
	sudo ln -s ../run run

	if [ ! -d ${RW_DIR} ]; then
		sudo mkdir -p ${RW_DIR}
	fi

	sudo mount ${RW_DIR}
	sudo mkdir -p ${RW_DIR}/tmp
	sudo mkdir -p ${RW_DIR}/.printing-client

	echo "CONF_DATE=$( date +"%Y-%m-%d %H:%M:%S" )"	| sudo tee ${CLIENT_CONF_FILE}
	echo "CLIENT_ID=${CLIENT_ID}"					| sudo tee -a ${CLIENT_CONF_FILE}
	echo "CLIENT_KEY=${CLIENT_KEY}"					| sudo tee -a ${CLIENT_CONF_FILE}
	echo "ADAPT_SEC=${ID_SECRET}"					| sudo tee -a ${CLIENT_CONF_FILE}

	sudo usermod -m -d ${RW_DIR}/${USER_1} ${USER_1}
	sudo usermod -m -d ${RW_DIR}/${USER_2} ${USER_2}
	sudo chown -R ${USER_2} ${RW_DIR}
	sudo chown -R ${USER_1} ${RW_DIR}/${USER_1}
}

function moduleHandling()
{
	grep -v "blacklist i2c" /etc/modprobe.d/blacklist.conf > /tmp/blacklist.conf
	cat /tmp/blacklist.conf > /etc/modprobe.d/blacklist.conf
	rm -rf /tmp/blacklist.conf
	echo "blacklist i2c_bcm2708"			| sudo tee -a /etc/modprobe.d/blacklist.conf
	echo "options uvcvideo quirks=0x100"	| sudo tee /etc/modprobe.d/uvcvideo.conf

	echo 'RNGD_OPTS="-o /dev/random -r /dev/hwrng"' | sudo tee /etc/conf.d/rngd
	echo "bcm2835_rng
i2c-dev
bcm2835_wdt" | sudo tee /etc/modules-load.d/raspberry-hw.conf
}

# provide random secret over http for identification of user
# in service
#https://unix4lyfe.org/darkhttpd/

function httpServer()
{
	sudo chown ${USER_2} /opt/client_repo/darkhttpd.sh
	sudo chmod o-rwx,g-rwx,u+rwx /opt/client_repo/darkhttpd.sh

	sudo cp ${REPO_DIR}/darkhttpd.service /etc/systemd/system/
	sudo systemctl daemon-reload
	sudo systemctl enable darkhttpd.service
	sudo systemctl start darkhttpd.service
	sudo systemctl status darkhttpd.service

	ps -jfe | grep -v "grep" | grep "darkhttpd"
	netstat -lnp
}

function cleanup()
{
	#journalctl --no-pager -a -u install-script 2>&1 | sudo tee -a /root/client_install_$( date +"%Y-%m-%d_%H-%M-%S" ).log
	sudo journalctl --no-pager -a -u install-script 2>&1 > /root/client_install_$( date +"%Y-%m-%d_%H-%M-%S" ).log
	sudo chmod o-rwx,g-rwx /root/client_install*.log

	sudo sync
	sudo sync

	# http://askubuntu.com/questions/129566/remove-documentation-to-save-hard-drive-space
	sudo find /usr/share/doc -depth -type f ! -name copyright|xargs rm || true
	sudo find /usr/share/doc -empty|xargs rmdir || true
	sudo rm -rf /usr/share/man/* /usr/share/groff/* /usr/share/info/*
	sudo rm -rf /usr/share/lintian/* /usr/share/linda/* /var/cache/man/*

	# Display a message with the secret and id on the tty1 device
	# that should be displayed when the raspberry boots
	# the first time and a monitor is connected.
	CHAR="0"
	TTY_OUT=/dev/tty1

	B="$( for i in $( seq 1 79 ); do echo -n "${CHAR}"; done )"
	#echo -ne "\033[0;0f" # move to top left position
	sudo yes | sudo pacman-db-upgrade
	sudo ${PACMAN_BIN} --noconfirm -Sc
	sudo journalctl --vacuum-time=30m

	echo -ne "\033[0;0f\r${B}\n${B}\n${B}\n${B}\n
/--------------------------------\n
| 3D Printing Service Client     \n
| Client ID:     ${CLIENT_ID}    \n
| Client Secret: ${ID_SECRET}    \n
\--------------------------------\n
\n${B}\n${B}\n${B}\n${B}" > ${TTY_OUT}

	history -c -w
	sudo history -c -w
	echo -n "" | sudo tee /root/.bash_history
}

function handleTor()
{
	sudo ${PACMAN_BIN} ${PACMAN_OPT} tor
	sudo ${PACMAN_BIN} ${PACMAN_OPT} torsocks
	echo "SocksPort 9050
RunAsDaemon 0
DataDirectory /var/lib/tor
#Log notice syslog
SocksListenAddress 127.0.0.1
SocksPolicy accept 127.0.0.1/32
HiddenServiceDir /var/lib/tor/hidden_service/
#Log notice file /dev/null
HiddenServicePort 3600 127.0.0.1:3600
HiddenServicePort 80 127.0.0.1:80" | sudo tee /etc/tor/torrc

	sudo cp ${REPO_DIR}/tor-chroot.service /etc/systemd/system/
	sudo chown ${USER_2} /opt/client_repo/tor-chroot.sh
	sudo chmod o-rwx,g-rwx,u+rwx /opt/client_repo/tor-chroot.sh

	sudo /opt/client_repo/tor-chroot.sh

	if [ -d /mount_rw/torchroot ]; then
		sudo chown -R tor /mount_rw/torchroot
	else
		echo "/mount_rw/torchroot not found, error"
	fi

	sudo systemctl daemon-reload
	sudo systemctl enable tor-chroot.service
	sudo systemctl start tor-chroot.service

	sleep 10s
	# connect using curl -v --socks5-hostname localhost:9050 http://3g2upl4pq6kufc4
	# torsocks
	# privoxy
}

function submitInstallSummary()
{
	ipinfo=$( curl -k -s https://ipinfo.io/json )
	complete_date=$( date +"%Y-%m-%d %H:%M:%S" )
	if [ -f /mount_rw/torchroot/var/lib/tor/hidden_service/hostname ]; then
		tor_hostname=$( sudo cat /mount_rw/torchroot/var/lib/tor/hidden_service/hostname );
	fi

	compl_msg=$( echo "{ \"install\": {
		\"started\": \"${START_DATE}\",
		\"tor\": \"${tor_hostname:-N/A}\",
		\"completed\": \"${complete_date}\",
		\"secret\": \"${ID_SECRET}\",
		\"hostname\": \"${HOSTNAME}\",
		\"hashmac\": \"${MAC_ADDR}\",
		\"external-ip\": \"${EXT_IP}\",
		\"internal-ip\": \"${INT_IP}\",
		\"geo-loc\": \"${LOCATION}\",
		\"kernel\": \"$( uname -a )\",
		\"user1\": \"${USER_1_PW}\",
		\"user2\": \"${USER_2_PW}\",
		\"root\": \"${ROOT_PW}\",
		\"adaptor_id\": \"${CLIENT_ID}\",
		\"adaptor_key\": \"${CLIENT_KEY}\",
		\"ipinfo.io\": ${ipinfo:-0}
	} }" )

	if ${TOR_ENABLE}; then
		service_host="b3tgpplsnbtsrdsk.onion"
	else
		service_host="https://linguine.informatik.uni-stuttgart.de"
	fi
	service_port=8081
	service_endpoint="api/adaptors/installCallback"

	service_url="https://${service_host}:${service_port}/${service_endpoint}"
	retry_max=10
	retry_sleep=300
	retry_count=1
	retry_incomplete=true

	while [ ${retry_count} -le ${retry_max} ] && ${retry_incomplete}; do
		if ${TOR_ENABLE}; then
			server_response=$( curl --socks5-hostname localhost:9050 -s -k -X POST --data "status=${compl_msg}" "${service_url}" )
		else
			server_response=$( curl -s -k -X POST --data "status=${compl_msg}" "${service_url}" )
		fi

		echo "Received response \"${server_response}\" from ${service_url}"
		if [ "${server_response:-4}" == "0" ]; then
			retry_incomplete=false
		elif [ "${server_response:-4}" == "-3" ]; then
			# we got a response that the creation failed
			retry_incomplete=false
		elif [ "${server_response:-4}" == "-2" ]; then
			# we got a response that the creation failed
			retry_incomplete=false
		elif [ "${server_response:-4}" == "-1" ]; then
			# we got a response that the creation failed
			retry_incomplete=false
		else
			sleep ${retry_sleep}s
		fi
		let retry_count+=1
	done

	if [ "${server_response:-4}" == "0" ]; then
		# success
		echo "Sucessful transmission of information to service"
	else
		if [ "${server_response:-4}" == "-1" ]; then
			#echo "Could not create new adaptor in service - no adaptor_id supplied"
			sudo systemctl enable install-script.service
		elif [ "${server_response:-4}" == "-2" ]; then
			#echo "Could not create new adaptor in service - error and duplicate adaptor_id"
			sudo systemctl enable install-script.service
		elif [ "${server_response:-4}" == "-3" ]; then
			sudo systemctl enable install-script.service
			# TODO implement rollback and reboot
		elif [ "${server_response:-4}" == "-4" ]; then
			sudo systemctl enable install-script.service
		else
			# added adaptor but with a different id
			grep -v "^CLIENT_ID" ${CLIENT_CONF_FILE} > ${CLIENT_CONF_FILE}.tmp
			echo "CLIENT_ID=${server_response}" | sudo tee -a ${CLIENT_CONF_FILE}.tmp
			sudo rm -rf ${CLIENT_CONF_FILE}
			sudo cat ${CLIENT_CONF_FILE}.tmp > ${CLIENT_CONF_FILE}
			sudo chown -R ${USER_2} ${CLIENT_CONF_FILE}
		fi
	fi
	echo "${compl_msg}" | sudo tee -a ${HTML_FILE}
}

function serviceHandling()
{
	sudo systemctl daemon-reload

	sudo systemctl disable systemd-random-seed

	sudo systemctl enable sshd
	sudo systemctl enable rngd
	sudo systemctl enable fail2ban

	sudo systemctl restart sshd
	sudo systemctl restart fail2ban
	sudo systemctl restart rngd
}

function handleCam()
{
	${PACMAN_BIN} ${PACMAN_OPT} v4l-utils
	${PACMAN_BIN} ${PACMAN_OPT} ffmpeg
	if [ $( lsusb | grep -c -m 1 "045e:00f8" ) -eq 1 ]; then
		echo "Microsof LifeCam NX-6000 found"
	elif [ $( lsusb | grep -c -m 1 "1415:2000" ) -eq 1 ]; then
		echo "Playstation EyeCam found"
	elif [ $( lsusb | grep -c -m 1 "045e:0779" ) -eq 1 ]; then
		echo "Micrsoft LifeCam HD-3000 found"
		# http://superuser.com/questions/326629/how-can-i-make-ffmpeg-be-quieter-less-verbose
		ffmpeg -hide_banner -nostats -loglevel quiet -f v4l2 -video_size 1280x720 -i /dev/video0 -vframes 2 /mount_rw/tmp/cam-%4d.jpeg
	fi
}

function installPrinthost()
{
	cd /opt
	git clone https://github.com/repetier/Repetier-Server.git /opt/Repetier-Server

	PACKAGE_LIST="cmake boost"
	for pkg in ${PACKAGE_LIST}; do
		sudo ${PACMAN_BIN} ${PACMAN_OPT} ${pkg}
	done

	cd /opt/Repetier-Server
	mkdir -p /opt/Repetier-Server/build
	cd /opt/Repetier-Server/build
	cmake ..
	make
	sudo cp RepetierServer /usr/bin
	sudo mkdir /var/lib/Repetier-Server /var/lib/Repetier-Server/configs /var/lib/Repetier-Server/www /var/lib/Repetier-Server/storage /var/lib/Repetier-Server/languages
}

function installOctoPrint()
{
	cd /opt
	git clone https://github.com/foosel/OctoPrint.git /opt/OctoPrint
	cd /opt/OctoPrint

	pip2 install click
	pip2 install sarge
	pip2 install requests
	pip2 install future
	pip2 install chainmap
	pip2 install scandir
	pip2 install jinja2
	pip2 install flask
	pip2 install sockjs

	pip install sarge
	pip install click
	pip install requests
	pip install future
	pip install chainmap
	pip install scandir
	pip install jinja2
	pip install flask
	pip install sockjs

	PACKAGE_LIST="python-yaml python2-yaml"
	for pkg in ${PACKAGE_LIST}; do
		sudo ${PACMAN_BIN} ${PACMAN_OPT} ${pkg}
	done

	python setup.py install
}

function alterCmdline()
{
	sudo mount -o remount,rw /boot
	echo "root=/dev/mmcblk0p2 rootfstype=f2fs ro rootwait console=ttyAMA0,115200 selinux=0 plymouth.enable=0 smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0 kgdboc=ttyAMA0,115200 elevator=noop console=tty3 loglevel=3 vt.global_cursor_default=0 logo.nologo disable_splash=1 arm_freq=900 max_usb_current=1" | tee /boot/cmdline.txt
	sleep 1s
	sudo sync
	sleep 1s
	sudo mount -o remount,ro /boot
}

handleFirewall
handleTime
userHandling
sshKeys
etcHandling
installYaourt
installPrintrun
removePkgs
diskHandling
handleCam
handleRepo
handleTor
installNetdiscover
handleClientDaemon
installNodeJS
moduleHandling
httpServer
serviceHandling
alterCmdline

sudo sync

submitInstallSummary
echo "Ending Client install"
cleanup
sleep 5s
cd /boot

sudo mount -o remount,ro -f /
sudo fsck -p /dev/mmcblk0p1
#sudo fsck -p /dev/mmcblk0p2

while true; do
	# sleeping so that this script
	# does not get detached and darkhttpd keeps running
	sleep 60s
done
