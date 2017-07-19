#!/bin/bash

########################################################################
# Client script to retrieve work package instructions
# from a server.
# Felix W. Baumann
# 2017-07-19
# CC-BY
########################################################################

MAIN_SCRIPT_NAME=$0
MAIN_SCRIPT_HASH=""

#TMP_FOLDER=/tmp
TMP_FOLDER=/mount_rw/tmp
if [ -d ${TMP_FOLDER} ]; then
	WP_FOLDER=$( mktemp -d --tmpdir=${TMP_FOLDER} )
else
	WP_FOLDER=$( mktemp -d --tmpdir=/tmp )
fi

CONFIG_DIR=${TMP_FOLDER}/../.printing-client

if [ ! -d ${CONFIG_DIR} ]; then
	mkdir -p ${CONFIG_DIR}
fi

CHROOT_BASE_DIR=${TMP_FOLDER}/../chroot_base
CONFIG_FILE=${CONFIG_DIR}/client.conf
VERS="0.1.2a"
TO_VAL="70"

CURL_OPTS_BASE="--socks5-hostname localhost:9050 -k -s --compressed --tr-encoding --cacert /etc/ssl/certs/print-service.pem"
CURL_OPTS="${CURL_OPTS_BASE} -m $( bc <<< "${TO_VAL:-70} - 5" )"
CURL_OPTS_LONG="${CURL_OPTS_BASE} -m $( bc <<< "( ${TO_VAL:-70} - 5 ) * 2" )"
CURL_OPTS_ULTRA_LONG="${CURL_OPTS_BASE} -m $( bc <<< "( ${TO_VAL:-70} - 5 ) * 10" )"
TO_VAL="${TO_VAL}s"

###
# User config variables declared here
# for global usage.
CLIENT_ID=""
CLIENT_SECRET=""
CLIENT_UA=""
BASE_URL=""
ALT_BASE_URL=""
SERVICE_PORT=""
BASE_SCHEMA=""

###
# Variables for third party tools that
# are required for this script.

SHA_BIN=$(     which sha256sum  )
AWK_BIN=$(     which awk        )
GREP_BIN=$(    which grep       )
CURL_BIN=$(    which curl       )
WGET_BIN=$(    which wget       )
UUIDGEN_BIN=$( which uuidgen    )
DATE_BIN=$(    which date       )
DD_BIN=$(      which dd         )
ZIP_BIN=$(     which zip        )
UNZIP_BIN=$(   which unzip      )
NC_BIN=$(      which nc         )
BASH_BIN=$(    which bash       )
TR_BIN=$(      which tr         )
XML_BIN=$(     which xmlstarlet )
TAIL_BIN=$(    which tail       )
CHMOD_BIN=$(   which chmod      )
TIMEOUT_BIN=$( which timeout    )
RM_BIN=$(      which rm         )
MKTEMP_BIN=$(  which mktemp     )
CHOWN_BIN=$(   which chown      )
DF_BIN=$(      which df         )
FDISK_BIN=$(   which fdisk      )
IP_BIN=$(      which ip         )
SLEEP_BIN=$(   which sleep      )
PS_BIN=$(      which ps         )
PYTHON_BIN=$(  which python2    )
SUDO_BIN=$(    which sudo       )
BASE_BIN=$(    which base64     )
CUT_BIN=$(     which cut        )
HEAD_BIN=$(    which head       )
CAT_BIN=$(     which cat        )
ID_BIN=$(      which id         )
ROUTE_BIN=$(   which route      )
WC_BIN=$(      which wc         )
TORSOCKS_BIN=$(which torsocks   )
TORIFY_BIN=$(  which torify     )
EGREP_BIN=$(   which egrep      )
GPG_BIN=$(     which gpg        )
OPENSSL_BIN=$( which openssl    )
SED_BIN=$(     which sed        )
CHROOT_BIN=$(  which chroot     )
UMOUNT_BIN=$(  which umount     )
LS_BIN=$(      which ls         )
###
#
DEBUG=true
VERB_DEBUG=false
LOG_FILE=${CONFIG_DIR}/client.log
USER_NAME="p_client"
STATUS_COUNTER=0
WP_START_COUNTER=0
WP_COMPL_COUNTER=0
WP_FAIL_COUNTER=0
WP_SUCC_COUNTER=0
STATUS_INTERVAL=90

OFFLINE_MODE=true
OFFLINE_INDICATOR_FILE=/dev/shm/is_client_offline
BUSY_INDICATOR_FILE=/dev/shm/is_client_busy
SR_BUSY_INDICATOR_FILE=/dev/shm/is_client_busy_sr
RNDV_FILE=/dev/shm/client_var_exchange

LOW_DISK_SPACE=false
BUSY=false
SERVICE_REQUEST_BUSY=false
echo "${BUSY}" > ${BUSY_INDICATOR_FILE}
echo "${SERVICE_REQUEST_BUSY}" > ${SR_BUSY_INDICATOR_FILE}

EXIT_SIGNAL=false

GRACE_PERIOD=15 # Sleeping time in the main loop
SPAWN_TMP_SH=$( mktemp --tmpdir=/dev/shm )
ETH_DEV="eth0"

PRINTRUN_DIR="/opt/Printrun"
if [ -d ${PRINTRUN_DIR} ] && [ -f ${PRINTRUN_DIR}/pronsole.py ]; then
	PRINTRUN_VERS=$( ${PYTHON_BIN} ${PRINTRUN_DIR}/pronsole.py -V 2>/dev/null )
else
	PRINTRUN_VERS="N/A"
fi

CHROOT_SH="$( dirname ${MAIN_SCRIPT_NAME} )/executer-chroot.sh"

###
# Endpoints for the remote service
LOG_SUBMISSION_ENDPOINT="api/adaptors/submitLog"
WP_STATUS_ENDPOINT="api/adaptors/sendStatus"
WP_RETRIEVE_ENDPOINT="api/adaptors/getWP"
ADAPTOR_STATUS_ENDPOINT="api/adaptors/adaptorStatus"
GET_WP_ID_ENDPOINT="api/adaptors/getNextWPId"
SUBMIT_WP_STAT_ENDPOINT="api/adaptors/wpStat"

###
# Formatter for all output with proper date-time formatting and
# preparation for logging output

function output()
{
	if ${DEBUG}; then
		echo "[$( date +"%Y-%m-%d %H:%M:%S.%N" )] [$$] ${1}" | tee -a ${LOG_FILE}
	else
		echo "[$( date +"%Y-%m-%d %H:%M:%S.%N" )] [$$] ${1}"
	fi
}

###
# Trapping function to catch the CTRL+C calls and
# set the exiting flag that is then checked each
# round for structured exiting.

function signal_trap()
{
	output "Trapped signal - Preparing Exit"
	EXIT_SIGNAL=true
}

trap signal_trap INT SIGHUP SIGINT SIGTERM

###
# Function to spawn a watchdog daemon on the system
# to check on the operation of this script

function spawnDaemon()
{
	if ${DEBUG}; then
		output "start spawnDaemon"
	fi

	echo "#!/bin/bash
while true; do
	if [ \$( ps -jfe | grep -v \"grep\" | grep -c \"${MAIN_SCRIPT_NAME}\" ) -eq 0 ]; then
		\$( which bash ) ${MAIN_SCRIPT_NAME}
	fi
	sleep 1s
done" > ${SPAWN_TMP_SH}
	${CHOWN_BIN} ${USER_NAME} ${SPAWN_TMP_SH}
	${CHMOD_BIN} u+x,o-rwx,g-rwx ${SPAWN_TMP_SH}

	# Check if the executing user is identical to the root user
	if [ "$( ${ID_BIN} -n -u )" == "${USER_NAME}" ]; then
		( ${BASH_BIN} ${SPAWN_TMP_SH} ) &
	else
		( ${SUDO_BIN} -u ${USER_NAME} ${BASH_BIN} ${SPAWN_TMP_SH} ) &
	fi

	if ${DEBUG}; then
		output "end spawnDaemon"
	fi
}

###
# Function to see the liveness of the daemon

function checkDaemon()
{
	if ${DEBUG}; then
		output "start checkDaemon"
	fi

	if [ $( ${PS_BIN} -jfe | ${GREP_BIN} -v "grep" | ${GREP_BIN} -c "${SPAWN_TMP_SH}" ) -eq 0 ]; then
		output "Checking daemon is not running, restarting"
		spawnDaemon
	fi

	if ${DEBUG}; then
		output "end checkDaemon"
	fi
}

###
# Function to clean the retrieved workpackage

function cleanWP()
{
	if ${DEBUG} && ${VERB_DEBUG}; then
		output "start cleanWP, WP_CHECK=\"${1}\"" 1>&2
	fi

	#WP_CHECK=$( echo "${1}" | ${TR_BIN} -d "~;\"\'\$@\\" )
	WP_CHECK=$( echo "${1}" | ${TR_BIN} -dc "0-9a-z\-" )
	WP_OUT=""

	# Cleanup the WP_ID so it does not contain any
	# characters usable for directory evasion
	# -> Variable sanitizing

	if [ $( ${EGREP_BIN} -c "(--|\.\.|/|\\\)" <<< "${WP_CHECK}" ) -ne 0 ]; then
		# failed the check for malicious formatting
		output "WP_ID malformed" 1>&2
	else
		WP_OUT="${WP_CHECK}"
	fi

	echo "${WP_OUT}"

	if ${DEBUG} && ${VERB_DEBUG}; then
		output "end cleanWP, WP_OUT=\"${WP_OUT}\"" 1>&2
	fi
}

###
# Function to check the required
# binaries and exit if one or more of them are missing.

function checkBinaries()
{
	if ${DEBUG}; then
		output "start checkBinaries"
	fi

	if [ "${SHA_BIN}" == "" ]; then
		output "sha256sum not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${AWK_BIN}" == "" ]; then
		output "awk not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${GREP_BIN}" == "" ]; then
		output "grep not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${CURL_BIN}" == "" ]; then
		output "curl not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${WGET_BIN}" == "" ]; then
		output "wget not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${UUIDGEN_BIN}" == "" ]; then
		output "uuidgen not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${DATE_BIN}" == "" ]; then
		output "date not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${DD_BIN}" == "" ]; then
		output "dd not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${ZIP_BIN}" == "" ]; then
		output "zip not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${UNZIP_BIN}" == "" ]; then
		output "unzip not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${NC_BIN}" == "" ]; then
		output "nc not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${BASH_BIN}" == "" ]; then
		output "bash not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${TR_BIN}" == "" ]; then
		output "tr not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${XML_BIN}" == "" ]; then
		output "xmlstarlet not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${TAIL_BIN}" == "" ]; then
		output "tail not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${CHMOD_BIN}" == "" ]; then
		output "chmod not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${TIMEOUT_BIN}" == "" ]; then
		output "timeout not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${RM_BIN}" == "" ]; then
		output "rm not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${MKTEMP_BIN}" == "" ]; then
		output "mktemp not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${CHOWN_BIN}" == "" ]; then
		output "chown not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${DF_BIN}" == "" ]; then
		output "df not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${FDISK_BIN}" == "" ]; then
		output "fdisk not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${IP_BIN}" == "" ]; then
		output "ip not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${SLEEP_BIN}" == "" ]; then
		output "sleep not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${PS_BIN}" == "" ]; then
		output "ps not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${PYTHON_BIN}" == "" ]; then
		output "python2 not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${SUDO_BIN}" == "" ]; then
		output "sudo not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${BASE_BIN}" == "" ]; then
		output "base64 not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${CUT_BIN}" == "" ]; then
		output "cut not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${HEAD_BIN}" == "" ]; then
		output "head not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${CAT_BIN}" == "" ]; then
		output "cat not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${ID_BIN}" == "" ]; then
		output "id not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${ROUTE_BIN}" == "" ]; then
		output "route not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${WC_BIN}" == "" ]; then
		output "wc not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${TORSOCKS_BIN}" == "" ]; then
		output "torsocks not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${TORIFY_BIN}" == "" ]; then
		output "torify not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${EGREP_BIN}" == "" ]; then
		output "egrep not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${GPG_BIN}" == "" ]; then
		output "gpg not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${OPENSSL_BIN}" == "" ]; then
		output "openssl not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ "${SED_BIN}" == "" ]; then
		output "sed not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ ! -f ${CHROOT_SH} ]; then
		output "chroot executor script not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ ! -f ${CHROOT_bin} ]; then
		output "chroot not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ ! -f ${UMOUNT_bin} ]; then
		output "umount not found, abort"
		EXIT_SIGNAL=true
	fi

	if [ ! -f ${LS_bin} ]; then
		output "ls not found, abort"
		EXIT_SIGNAL=true
	fi

	if ${DEBUG}; then
		output "end checkBinaries"
	fi
}

###
# Function to generate a pseudo-random hashed key for
# identification

function genKey()
{
	if ${DEBUG}; then
		output "start genKey" 1>&2
	fi

	# Check if /dev/urandom exists, for now we assume
	# that every system we are on, has one.

	#generatedKey=$( echo "$( ${UUIDGEN_BIN} )$( ${DATE_BIN} )$( ${DD_BIN} if=/dev/urandom of=/dev/stdout bs=1 count=1024 2>/dev/null )" | ${SHA_BIN} | ${AWK_BIN} '{ print $1 }' )
	generatedKey=$( echo "$( ${UUIDGEN_BIN} )$( ${DATE_BIN} )$( ${DD_BIN} if=/dev/urandom of=/dev/stdout bs=1 count=1024 2>/dev/null )" | ${SHA_BIN} | ${BASE_BIN} | ${HEAD_BIN} -1l | ${CUT_BIN} -c -32 )
	echo "${generatedKey}"

	if ${DEBUG}; then
		output "end genKey, generatedKey=\"${generatedKey}\"" 1>&2
	fi
}

function readConfig()
{
	if ${DEBUG}; then
		output "start readConfig" 1>&2
	fi
	MAIN_SCRIPT_HASH=$( ${SHA_BIN} ${MAIN_SCRIPT_NAME} | ${CUT_BIN} -c-32 )

	if [ ! -f ${CONFIG_FILE} ]; then
		if ${DEBUG}; then
			output "CONFIG_FILE=${CONFIG_FILE} not present, creating new config" 1>&2
		fi

		touch ${CONFIG_FILE}
		echo "CONF_DATE=$( ${DATE_BIN} +"%Y-%m-%d %H:%M:%S" )" > ${CONFIG_FILE}
	fi

	CLIENT_ID=$( ${GREP_BIN} "^CLIENT_ID=" ${CONFIG_FILE} | ${AWK_BIN} -F"=" '{ print $2 }' )
	if [ "${CLIENT_ID}" == "" ]; then
		CLIENT_ID=$( ${UUIDGEN_BIN} -r | SHA)
		${UUIDGEN_BIN} -r | ${SHA_BIN} | base64 -w 15 | cut -c -5 | tr  "\n" "-" | ${SED_BIN} -e "s|-o=-$||"
		echo "CLIENT_ID=${CLIENT_ID}" >> ${CONFIG_FILE}
	fi
	export CLIENT_ID

	CLIENT_SECRET=$( ${GREP_BIN} "^CLIENT_KEY=" ${CONFIG_FILE} | ${AWK_BIN} -F"=" '{ print $2 }' )
	if [ "${CLIENT_SECRET}" == "" ]; then
		CLIENT_SECRET=$( genKey )
		echo "CLIENT_KEY=${CLIENT_KEY}" >> ${CONFIG_FILE}
	fi
	export CLIENT_SECRET

	CLIENT_UA=$( ${GREP_BIN} "^UA=" ${CONFIG_FILE} | ${AWK_BIN} -F"=" '{ print $2 }' )
	if [ "${CLIENT_UA}" == "" ]; then
		CLIENT_UA="3dprinting service client v ${VERS}"
		echo "UA=${CLIENT_UA}" >> ${CONFIG_FILE}
	fi
	export CLIENT_UA

	BASE_URL=$( ${GREP_BIN} "^BASE_URL=" ${CONFIG_FILE} | ${AWK_BIN} -F"=" '{ print $2 }' )
	if [ "${BASE_URL}" == "" ]; then
		#BASE_URL="linguine.informatik.uni-stuttgart.de"
		#BASE_URL="192.168.178.80"
		BASE_URL="b3tgpplsnbtsrdsk.onion"
		echo "BASE_URL=${BASE_URL}" >> ${CONFIG_FILE}
	fi
	export BASE_URL
	
	ALT_BASE_URL=$( ${GREP_BIN} "^ALT_BASE_URL=" ${CONFIG_FILE} | ${AWK_BIN} -F"=" '{ print $2 }' )
	if [ "${BASE_URL}" == "" ]; then
		#BASE_URL="linguine.informatik.uni-stuttgart.de"
		#BASE_URL="192.168.178.80"
		ALT_BASE_URL="192.168.178.80"
		echo "ALT_BASE_URL=${ALT_BASE_URL}" >> ${CONFIG_FILE}
	fi
	export ALT_BASE_URL

	BASE_SCHEMA=$( ${GREP_BIN} "^BASE_SCHEMA=" ${CONFIG_FILE} | ${AWK_BIN} -F"=" '{ print $2 }' )
	if [ "${BASE_SCHEMA}" == "" ]; then
		# TODO: Change BASE_SCHEMA from http to https
		BASE_SCHEMA="https"
		echo "BASE_SCHEMA=${BASE_SCHEMA}" >> ${CONFIG_FILE}
	fi
	export BASE_SCHEMA

	SERVICE_PORT=$( ${GREP_BIN} "^SERVICE_PORT=" ${CONFIG_FILE} | ${AWK_BIN} -F"=" '{ print $2 }' )
	if [ "${SERVICE_PORT}" == "" ]; then
		SERVICE_PORT=8081
		echo "SERVICE_PORT=${SERVICE_PORT}" >> ${CONFIG_FILE}
	fi
	export SERVICE_PORT

	SERVICE_FINGERPRINT=$( ${GREP_BIN} "^SERVICE_FINGERPRINT=" ${CONFIG_FILE} | ${AWK_BIN} -F"=" '{ print $2 }' )
	if [ "${SERVICE_FINGERPRINT}" == "" ]; then
		#SERVICE_FINGERPRINT="FAEE81E0DD1FE262220A8AB3E2289F2EBA2870D6"
		SERVICE_FINGERPRINT="011B98FD0CA000622619D1088B906B6D1D70797A"
		echo "SERVICE_FINGERPRINT=${SERVICE_FINGERPRINT}" >> ${CONFIG_FILE}
	fi
	export SERVICE_FINGERPRINT

	if ${DEBUG}; then
		output "end readConfig, CLIENT_ID=\"${CLIENT_ID}\", CLIENT_SECRET=OMITTED, CLIENT_UA=\"${CLIENT_UA}\", BASE_URL=\"${BASE_URL}\"" 1>&2
	fi
}

function submitWPStatus()
{
	if ${DEBUG}; then
		output "start submitWPStatus" 1>&2
	fi

	WP_ID=$( cleanWP "${1}" )
	WP_STATUS=${2}

	# Status:
	# 0 -> Not Available
	# 1 -> WP Available
	# 2 -> WP downloaded
	# 3 -> WP download, succesful
	# 4 -> WP download, failed
	# 5 -> WP in queue
	# 6 -> WP processing
	# 7 -> WP overdue
	# 8 -> WP completed succesful
	# 9 -> WP completed failed
	# 22 -> Client local error
	if [ ! "${WP_ID}" == "" ]; then
		#WP_ID=${WP_ID}
		${TIMEOUT_BIN} ${TO_VAL} ${CURL_BIN} ${CURL_OPTS} -X POST \
			--data "status=${WP_STATUS}" \
			--data "adaptor_id=${CLIENT_ID}" \
			--data "adaptor_key=${CLIENT_SECRET}" \
			--user-agent "${CLIENT_UA}" \
			"${BASE_SCHEMA}://${BASE_URL}:${SERVICE_PORT}/${WP_STATUS_ENDPOINT}/${WP_ID}" 2>/dev/null >/dev/null
	else
		output "submitWPStatus, WP_ID is empty" 1>&2
	fi

	#${WGET_BIN} -q --post-data="" --user-agent="${CLIENT_UA}" "${BASE_SCHEMA}${BASE_URL}/${WP_STATUS_ENDPOINT}"
	if ${DEBUG}; then
		output "end submitWPStatus" 1>&2
	fi
}

function retrieveWP()
{
	if ${DEBUG}; then
		output "start retrieveWP" 1>&2
	fi
	# make call to service for WP-ID
	WP_ID=$( cleanWP "${1}" )
	if ${DEBUG}; then
		output "retrieveWP, WP_ID=\"${WP_ID}\"" 1>&2
	fi

	if [ ! "${WP_ID}" == "" ]; then
		if [ -d ${WP_FOLDER} ]; then

			${CURL_BIN} ${CURL_OPTS_ULTRA_LONG} -C - \
				-o ${WP_FOLDER}/${WP_ID}.zip -X POST \
				--data "adaptor_id=${CLIENT_ID}" \
				--data "adaptor_key=${CLIENT_SECRET}" \
				--user-agent "${CLIENT_UA}" \
				"${BASE_SCHEMA}://${BASE_URL}:${SERVICE_PORT}/${WP_RETRIEVE_ENDPOINT}/${WP_ID}" 2>/dev/null >/dev/null

			curl_response=$?

			if [ ${curl_response:-1} -eq 0 ]; then
				submitWPStatus "${WP_ID}" 2 # wp downloaded
			else
				submitWPStatus "${WP_ID}" 4 # wp download failed
			fi
			# check correct retrieval
		else
			output "WP_FOLDER - ${WP_FOLDER} does not exist" 1>&2
		fi
	else
		output "retrieveWP, WP_ID is empty" 1>&2
	fi
	echo "${curl_response:--1}"

	if ${DEBUG}; then
		output "end retrieveWP, curl_response=${curl_response:-100}" 1>&2
	fi
}

function checkConnectivity()
{
	if ${DEBUG}; then
		output "start checkConnectivity" 1>&2
	fi

	dnsPort="53"
	httpPort="80"

	dnsSite_1="8.8.8.8"
	testSite_1="google.com"
	#testSite_2=""

	if $( ${NC_BIN} -zw1 ${dnsSite_1} ${dnsPort} ); then
		if $( ${NC_BIN} -zw1 ${testSite_1} ${httpPort} ); then
			# this fails as we cannot resolv .onion addresses
			if [ $( ${GREP_BIN} -m 1 -c "\.onion" <<< "${BASE_URL}" ) -eq 0 ] && \
				$( ${NC_BIN} -zw1 ${BASE_URL} ${SERVICE_PORT} 2>/dev/null ); then
				OFFLINE_MODE=false
				echo -n "false" > ${OFFLINE_INDICATOR_FILE}
			else
				if ( ${TORSOCKS_BIN} ${NC_BIN} -zw1 ${BASE_URL} ${SERVICE_PORT} 2>/dev/null ); then
					if ${OFFLINE_MODE}; then
						output "Service is reachable again" 1>&2
					fi
					OFFLINE_MODE=false
					echo -n "false" > ${OFFLINE_INDICATOR_FILE}
				else
					if ( ${NC_BIN} -zw1 ${ALT_BASE_URL} ${SERVICE_PORT} 2>/dev/null ); then
						output "Could not reach service at ${BASE_URL}:${SERVICE_PORT} but alt at ${ALT_BASE_URL}:${SERVICE_PORT} is available" 1>&2
						OFFLINE_MODE=false
						tmp_host=${BASE_URL}
						BASE_URL=${ALT_BASE_URL}
						ALT_BASE_URL=${tmp_host}

						echo -n "false" > ${OFFLINE_INDICATOR_FILE}
					else
						output "Could not reach service at ${BASE_URL}:${SERVICE_PORT}" 1>&2
						OFFLINE_MODE=true
						echo -n "true" > ${OFFLINE_INDICATOR_FILE}
					fi
				fi
			fi
		else
			output "Could not reach ${testSite_1}, marking offline" 1>&2
			OFFLINE_MODE=true
			echo -n "true" > ${OFFLINE_INDICATOR_FILE}
		fi
	else
		output "Could not check if ${dnsSite_1} is online, marking offline" 1>&2
		OFFLINE_MODE=true
		echo -n "true" > ${OFFLINE_INDICATOR_FILE}
	fi

	if ${OFFLINE_MODE}; then
		# increase sleeping time
		# in case we are offline
		GRACE_PERIOD=40
	else
		GRACE_PERIOD=15
	fi

	if ${DEBUG}; then
		output "end checkConnectivity, OFFLINE_MODE=${OFFLINE_MODE}" 1>&2
	fi
}

function removeWP()
{
	###
	# Removes WP locally
	if ${DEBUG}; then
		output "start removeWP" 1>&2
	fi

	WP_ID=$( cleanWP "${1}" )
	if [ ! "${WP_ID}" == "" ]; then
		if ${DEBUG}; then
			output "Removing folder for WP_ID=${WP_ID} at ${WP_FOLDER}/${WP_ID}" 1>&2
		fi
		if [ -d ${WP_FOLDER}/${WP_ID} ]; then
			${SUDO_BIN} ${UMOUNT_BIN} -f ${WP_FOLDER}/${WP_ID}
			#${RM_BIN} -rf ${WP_FOLDER}/${WP_ID}
		else
			output "Could not find folder at ${WP_FOLDER}/${WP_ID}" 1>&2
		fi
	else
		output "removeWP, WP_ID is empty" 1>&2
	fi

	if ${DEBUG}; then
		output "end removeWP" 1>&2
	fi
}

function createWPFolder()
{
	if ${DEBUG}; then
		output "start createWPFolder" 1>&2
	fi

	WP_ID=$( cleanWP "${1}" )

	if ${DEBUG}; then
		output "createWPFolder, WP_ID=\"${WP_ID}\"" 1>&2
	fi

	folder_created=false
	if [ ! "${WP_ID}" == "" ]; then
		if [ -d ${WP_FOLDER}/${WP_ID} ]; then
			output "${WP_FOLDER}/${WP_ID} already exists, error" 1>&2
			folder_created=false
		else
			mkdir -p ${WP_FOLDER}/${WP_ID}
			if [ -d ${WP_FOLDER}/${WP_ID} ]; then
				folder_created=true
			else
				folder_created=false
			fi
		fi
	else
		output "createWPFolder, WP_ID is empty" 1>&2
	fi

	echo "${folder_created}"

	if ${DEBUG}; then
		output "end createWPFolder" 1>&2
	fi
}

function checkDiskSpace()
{
	if ${DEBUG}; then
		output "start checkDiskSpace" 1>&2
	fi

	diskSpaceWarningLimit=95
	space_used=$( ${DF_BIN} --output=pcent -h ${TMP_FOLDER} | ${TAIL_BIN} -1l | ${TR_BIN} -dc "0-9" )
	if [ ${space_used:-100} -ge ${diskSpaceWarningLimit:-0} ]; then
		output "Low disk space" 1>&2
		LOW_DISK_SPACE=true
	else
		LOW_DISK_SPACE=false
	fi

	if ${DEBUG}; then
		output "end checkDiskSpace, LOW_DISK_SPACE=${LOW_DISK_SPACE}" 1>&2
	fi
}

function checkWPIntegrity()
{
	if ${DEBUG}; then
		output "start checkWPIntegrity" 1>&2
	fi

	WP_ID=$( cleanWP "${1}" )
	fileIntegrity="false"

	if [ ! "${WP_ID}" == "" ]; then
		if [ -f ${WP_FOLDER}/${WP_ID}/wp-meta.xml ] && \
			[ -f ${WP_FOLDER}/${WP_ID}/${WP_ID}.sh ] && \
			[ -f ${WP_FOLDER}/${WP_ID}/${WP_ID}.data ] && \
			[ -f ${WP_FOLDER}/${WP_ID}.zip ]; then
			#glob_file_hash=$( ${SHA_BIN} ${WP_FOLDER}/${WP_ID}.zip           | ${AWK_BIN} '{ print $1 }' )
			data_file_hash=$( ${SHA_BIN} ${WP_FOLDER}/${WP_ID}/${WP_ID}.data | ${AWK_BIN} '{ print $1 }' )
			script_file_hash=$( ${SHA_BIN} ${WP_FOLDER}/${WP_ID}/${WP_ID}.sh | ${AWK_BIN} '{ print $1 }' )

			script_file_hash_prov=$( ${XML_BIN} sel -t -m "/workpackage/payload/script" -v "hash" ${WP_FOLDER}/${WP_ID}/wp-meta.xml  )
			data_file_hash_prov=$(   ${XML_BIN} sel -t -m "/workpackage/payload/data" -v "hash" ${WP_FOLDER}/${WP_ID}/wp-meta.xml )
			adaptor_intent=$(        ${XML_BIN} sel -t -m "/workpackage" -v "execute_on" ${WP_FOLDER}/${WP_ID}/wp-meta.xml )

			#glob_file_hash_prov=$(   ${XML_BIN} sel -t -m "/workpackage" -v "packHash" ${WP_FOLDER}/${WP_ID}/wp-meta.xml  )

			# can't store hash of zip within zip as it is being altered when the zip is created
			#if [ "${glob_file_hash:-0}"    == "${glob_file_hash_prov:-1}" ] &&
			if ${DEBUG}; then
				output "data_file_hash=${data_file_hash}" 1>&2
				output "data_file_hash_prov=${data_file_hash_prov}" 1>&2
				
				output "script_file_hash=${script_file_hash}" 1>&2
				output "script_file_hash_prov=${script_file_hash_prov}" 1>&2
				
				output "adaptor_intent=${adaptor_intent}" 1>&2
				output "CLIENT_ID=${CLIENT_ID}" 1>&2
			fi

			# TODO provide public key from server
			# and check if zip file is signed

			if	[ "${data_file_hash:-0}"   == "${data_file_hash_prov:-1}" ] && \
				[ "${adaptor_intent:-0}"   == "${CLIENT_ID:-1}" ] && \
				[ "${script_file_hash:-0}" == "${script_file_hash_prov:-1}" ]; then
				fileIntegrity=true
				${RM_BIN} -rf ${WP_FOLDER}/${WP_ID}.zip
				output "WP ${WP_ID} is valid" 1>&2
			else
				fileIntegrity=false
				${RM_BIN} -rf ${WP_FOLDER}/${WP_ID}.zip
				output "fileIntegrity is broken" 1>&2
			fi
		else
			fileIntegrity=false
		fi
	else
		output "checkWPIntegrity, WP_ID is empty" 1>&2
	fi

	#fileIntegrity=true
	echo "${fileIntegrity}"

	if ${DEBUG}; then
		output "end checkWPIntegrity" 1>&2
	fi
}

function unpackWP()
{
	if ${DEBUG}; then
		output "start unpackWP" 1>&2
	fi

	WP_ID=$( cleanWP "${1}" )
	WP_TYPE="${2}"

	if [ ! "${WP_ID}" == "" ]; then
		if [ -f ${WP_FOLDER}/${WP_ID}.zip ]; then
			if [ ! -d ${WP_FOLDER}/${WP_ID} ]; then
				mkdir -p ${WP_FOLDER}/${WP_ID}
			fi
			
			if [ "${WP_TYPE:--1}" == "WP" ]; then 
				if ${DEBUG}; then
					output "WP type is workpackage, creating chroot environment" 1>&2
				fi
				${CHROOT_SH} "${WP_FOLDER}/${WP_ID}" 2>/dev/null
			elif [ "${WP_TYPE:--1}" == "SR" ]; then
				if ${DEBUG}; then
					output "WP type is service request, not creating a chroot env" 1>&2
				fi
			else
				output "WP type is unknown, error" 1>&2
				zip_ret_val=4
			fi

			# extract the signature from the zip file
			# and remove the signature so that
			# it can be extracted normally

			zip_tmp=$( ${MKTEMP_BIN} -d -p ${TMP_FOLDER} )
			mv ${WP_FOLDER}/${WP_ID}.zip ${zip_tmp}/${WP_ID}.dat

			# https://raymii.org/s/tutorials/Sign_and_verify_text_files_to_public_keys_via_the_OpenSSL_Command_Line.html
			cp ${zip_tmp}/${WP_ID}.dat /tmp/
			${DD_BIN} bs=1 skip=512  if=${zip_tmp}/${WP_ID}.dat of=${WP_FOLDER}/${WP_ID}.zip status=none 2>/dev/null
			${DD_BIN} bs=1 count=512 if=${zip_tmp}/${WP_ID}.dat of=${zip_tmp}/${WP_ID}.sig status=none   2>/dev/null

			fingerprint=$( ${OPENSSL_BIN} dgst -sha256 -verify <( ${OPENSSL_BIN} x509 -in ${CONFIG_DIR}/sign-key.crt -pubkey -noout ) -signature ${zip_tmp}/${WP_ID}.sig ${WP_FOLDER}/${WP_ID}.zip 2>&1 )
			#fingerprint=$( ${GPG_BIN} --output ${WP_FOLDER}/${WP_ID}.zip --decrypt ${zip_tmp} 2>&1 | ${GREP_BIN} "fingerprint" | ${AWK_BIN} -F":" '{ print $2 }' | ${TR_BIN} -d " " )

			${RM_BIN} -rf ${zip_tmp}/${WP_ID}.dat
			${RM_BIN} -rf ${zip_tmp}/${WP_ID}.sig
			${RM_BIN} -rf ${zip_tmp}

			if [ "${fingerprint:-0}" == "Verified OK" ]; then
				${UNZIP_BIN} -qq ${WP_FOLDER}/${WP_ID}.zip -d ${WP_FOLDER}/${WP_ID}
				zip_ret_val=$?

				${CHOWN_BIN} -R ${USER_NAME} ${WP_FOLDER}/${WP_ID}/${WP_ID}.*
				${CHMOD_BIN} u+x,o-rwx,g-rwx ${WP_FOLDER}/${WP_ID}/${WP_ID}.sh

				if [ -f ${WP_FOLDER}/${WP_ID}/${WP_ID}.data ]; then
					${CHMOD_BIN} u-x,o-rwx,g-rwx ${WP_FOLDER}/${WP_ID}/${WP_ID}.data
				else
					output "Data not present at ${WP_FOLDER}/${WP_ID}/${WP_ID}.data" 1>&2
					zip_ret_val=2
				fi
			else
				zip_ret_val=1
			fi

			#cp ${WP_FOLDER}/${WP_ID}.zip /tmp/
			if [ ${zip_ret_val:-1} -eq 0 ]; then
				output "Unzip of ${WP_FOLDER}/${WP_ID}.zip to ${WP_FOLDER}/${WP_ID}/ succesful" 1>&2
			else
				output "Unzip of ${WP_FOLDER}/${WP_ID}.zip to ${WP_FOLDER}/${WP_ID}/ failed" 1>&2
				output "Fingerprint: ${fingerprint}" 1>&2
				cp ${WP_FOLDER}/${WP_ID}.zip /tmp/
			fi
		else
			output "${WP_FOLDER}/${WP_ID}.zip not found" 1>&2
		fi
	else
		output "unpackWP, WP_ID is empty" 1>&2
	fi

	if [ ${zip_ret_val:-1} -eq 0 ]; then
		echo "true"
	else
		echo "false"
	fi

	if ${DEBUG}; then
		output "end unpackWP, zip_ret_val=${zip_ret_val}" 1>&2
	fi
}

function queryServer()
{
	if ${DEBUG}; then
		output "start queryServer" 1>&2
	fi
	server_response=$( ${TIMEOUT_BIN} ${TO_VAL} ${CURL_BIN} ${CURL_OPTS} -X POST \
			--data "adaptor_key=${CLIENT_SECRET}" \
			--user-agent "${CLIENT_UA}" \
			"${BASE_SCHEMA}://${BASE_URL}:${SERVICE_PORT}/${ADAPTOR_STATUS_ENDPOINT}/${CLIENT_ID}" 2>/dev/null )
	# responses:
	# -1 -> no response or error
	#  1 -> no workpackage available
	#  2 -> one workpackage available
	#  3 -> multiple workpackages available
	#  4 -> service requests update (This is also a work package
	#	that is downloaded even if there is currently a work package
	# 	in execution. This workpackage contains information on
	#	what the service wants to know.
	#  5 -> new adaptor/unclaimed

	echo "${server_response:--1}"

	if ${DEBUG}; then
		output "end queryServer, server_response=\"${server_response}\"" 1>&2
	fi
}

function getWPId()
{
	if ${DEBUG}; then
		output "start getWPId" 1>&2
	fi

	server_response=$( ${TIMEOUT_BIN} ${TO_VAL} ${CURL_BIN} ${CURL_OPTS} -X POST \
			--data "adaptor_key=${CLIENT_SECRET}" \
			--user-agent "${CLIENT_UA}" \
			"${BASE_SCHEMA}://${BASE_URL}:${SERVICE_PORT}/${GET_WP_ID_ENDPOINT}/${CLIENT_ID}" 2>/dev/null )
	# responses:
	#	-1    -> no wp or error
	#	wp_id -> workpackage id
	output "server response: ${server_response}" 1>&2
	echo "${server_response:--1}"

	if ${DEBUG}; then
		output "end getWPId" 1>&2
	fi
}

function submitWPLog()
{
	if ${DEBUG}; then
		output "start submitWPLog" 1>&2
	fi
	WP_ID=$( cleanWP "${1}" )

	if [ ! "${WP_ID}" == "" ]; then
		WP_LOG=${2}
		if [ ! "${WP_LOG}" == "" ] && [ -f ${WP_LOG} ]; then
			#http://askubuntu.com/questions/650391/send-base64-encoded-image-using-curl
			#-F "log=@${WP_LOG};action=submit_wp_log;adaptor_id=${CLIENT_ID};adaptor_key=${CLIENT_SECRET};WP_ID=${WP_ID}"
			# WP_ID=${WP_ID}
			# set timeout to two minutes
			server_response=$( ${CURL_BIN} ${CURL_OPTS_LONG} -X POST \
				--data "adaptor_id=${CLIENT_ID}" \
				--data "adaptor_key=${CLIENT_SECRET}" \
				--data 'logfile='"$( base64 ${WP_LOG} )"'' \
				--user-agent "${CLIENT_UA}" \
				"${BASE_SCHEMA}://${BASE_URL}:${SERVICE_PORT}/${LOG_SUBMISSION_ENDPOINT}/${WP_ID}" 2>/dev/null )
		else
			output "Could not read WP_LOG=${WP_LOG}" 1>&2
		fi

	else
		output "submitWPLog, WP_ID is empty" 1>&2
	fi

	if ${DEBUG}; then
		output "end submitWPLog, server_response=${server_response}" 1>&2
	fi
}

function processWP()
{
	# ensure that WP processing is in the background
	# so that status requests are able to be processes
	# but only one wp can be processed at a time.
	# Also enable checking for overdue processes, so that
	# they can be killed
	if ${DEBUG}; then
		output "start processWP" 1>&2
	fi

	# WARNING:
	# No user limitations and restrictions are implemented
	# and enforced at this stage. This is a prototype and
	# the user is assumed non-hostile.
	# The downloaded script is executed as user p_client
	# from the group p_client.

	WP_ID=$( cleanWP "${1}" )
	WP_TYPE="${2}"

	if [ ! "${WP_ID}" == "" ]; then
		if [ -d ${WP_FOLDER}/${WP_ID} ] && [ -f ${WP_FOLDER}/${WP_ID}/${WP_ID}.sh ]; then
			wp_tmp=$( ${MKTEMP_BIN} --tmpdir=${WP_FOLDER}/${WP_ID} )

			submitWPStatus "${WP_ID}" 5 # wp in queue
			output "Processing WP ${WP_ID}"
			#${CHOWN_BIN} -R ${USER_NAME} ${WP_FOLDER}/${WP_ID}/${WP_ID}.*
			#${CHMOD_BIN} u+x,o-rwx,g-rwx ${WP_FOLDER}/${WP_ID}/${WP_ID}.sh

			exec_limit=$( ${XML_BIN} sel -t -m "/workpackage" -v "expected_runtime" ${WP_FOLDER}/${WP_ID}/wp-meta.xml  )

			echo "[$( ${DATE_BIN} +"%Y-%m-%d %H:%M:%S.%N" )] START WP=${WP_ID} as user=${USER_NAME} with limit=${exec_limit:-3600}s TYPE=${WP_TYPE:-N/A}" > ${wp_tmp}
			exec_start=$( ${DATE_BIN} +"%s.%N" )
			let WP_START_COUNTER+=1
			echo -n "WP_START_COUNTER=${WP_START_COUNTER:-0} WP_COMP_COUNTER=${WP_COMP_COUNTER:-0} WP_SUCC_COUNTER=${WP_SUCC_COUNTER:-0} WP_FAIL_COUNTER=${WP_FAIL_COUNTER:-0} MAIN_PID=$$" > ${RNDV_FILE}
			if [ "$( ${ID_BIN} -n -u )" == "${USER_NAME}" ]; then
				#( ${TIMEOUT_BIN} ${exec_limit:-3600}s ${BASH_BIN} ${WP_FOLDER}/${WP_ID}/${WP_ID}.sh 2>&1 >>${wp_tmp} ; echo "WP_RESULT=$?" >>${wp_tmp} ) &
				#( ${TIMEOUT_BIN} ${exec_limit:-3600}s ${CHROOT_BIN} ${WP_FOLDER} ${BASH_BIN} ${WP_ID}.sh 2>&1 >>${wp_tmp} ; echo "WP_RESULT=$?" >> ${wp_tmp} ) &
				if [ "${WP_TYPE:--1}" == "WP" ]; then
					if ${DEBUG}; then
						output "WP type is normal WP, executing in chroot env"
					fi
					( ( ${TIMEOUT_BIN} ${exec_limit:-3600}s ${SUDO_BIN} ${CHROOT_BIN} ${WP_FOLDER}/${WP_ID} /${WP_ID}.sh /${WP_ID}.data 2>&1 ) >>${wp_tmp}; echo "WP_RESULT=$?" >> ${wp_tmp} ) &
				elif [ "${WP_TYPE:--1}" == "SR" ]; then
					if ${DEBUG}; then
						output "WP type is service request, not executing in chroot env"
					fi
					( ${TIMEOUT_BIN} ${exec_limit:-3600}s ${BASH_BIN} ${WP_FOLDER}/${WP_ID}/${WP_ID}.sh 2>&1 >>${wp_tmp} ; echo "WP_RESULT=$?" >>${wp_tmp} ) &
				else
					output "Unknown WP type, error"
				fi

				#cp -dpR ${WP_FOLDER} /tmp/
			else
				( ${TIMEOUT_BIN} ${exec_limit:-3600}s ${SUDO_BIN} -u ${USER_NAME} -r ${BASH_BIN} ${WP_FOLDER}/${WP_ID}/${WP_ID}.sh 2>&1 >>${wp_tmp} ; echo "WP_RESULT=$?" >> ${wp_tmp} ) &
			fi
			# send ${wp_tmp} back to server on completion
			submitWPStatus "${WP_ID}" 6 # wp processing

			wait

			exec_end=$( ${DATE_BIN} +"%s.%N" )
			if [ -f ${WP_FOLDER}/${WP_ID}/tmp/stdout.txt ]; then
				${CAT_BIN} ${WP_FOLDER}/${WP_ID}/tmp/stdout.txt >> ${wp_tmp}
			else
				if [ "${WP_TYPE:--1}" == "SR" ]; then
					if ${DEBUG}; then
						output "No output from chroot execution found, OKAY, as this is a service request"
					fi
				else
					if ${DEBUG}; then
						output "No output from chroot execution found, error"
					fi
				fi
			fi

			let WP_COMP_COUNTER+=1
			echo -n "WP_START_COUNTER=${WP_START_COUNTER:-0} WP_COMP_COUNTER=${WP_COMP_COUNTER:-0} WP_SUCC_COUNTER=${WP_SUCC_COUNTER:-0} WP_FAIL_COUNTER=${WP_FAIL_COUNTER:-0} MAIN_PID=$$" > ${RNDV_FILE}

			exec_dur=$( ${AWK_BIN} '{ print $1 - $2 }' <<< "${exec_end:-0} - ${exec_start:-0}" )
			wp_ret_val=$( ${GREP_BIN} "^WP_RESULT=" ${wp_tmp} | ${TAIL_BIN} -1l | ${AWK_BIN} -F"=" '{ print $2 }' )
			if [ ${wp_ret_val:-1} -eq 0 ]; then
				echo "[$( ${DATE_BIN} +"%Y-%m-%d %H:%M:%S.%N" )] END WP=${WP_ID}, ind=SUCC (${wp_ret_val:-1})" >> ${wp_tmp}
				let WP_SUCC_COUNTER+=1
				echo -n "WP_START_COUNTER=${WP_START_COUNTER:-0} WP_COMP_COUNTER=${WP_COMP_COUNTER:-0} WP_SUCC_COUNTER=${WP_SUCC_COUNTER:-0} WP_FAIL_COUNTER=${WP_FAIL_COUNTER:-0} MAIN_PID=$$" > ${RNDV_FILE}
			else
				echo "[$( ${DATE_BIN} +"%Y-%m-%d %H:%M:%S.%N" )] END WP=${WP_ID}, ind=FAIL (${wp_ret_val:-1})" >> ${wp_tmp}
				let WP_FAIL_COUNTER+=1
				echo -n "WP_START_COUNTER=${WP_START_COUNTER:-0} WP_COMP_COUNTER=${WP_COMP_COUNTER:-0} WP_SUCC_COUNTER=${WP_SUCC_COUNTER:-0} WP_FAIL_COUNTER=${WP_FAIL_COUNTER:-0} MAIN_PID=$$" > ${RNDV_FILE}
			fi
			echo -e "TYPE=${WP_TYPE:-N/A} EXECUTION_DUR\tWP=${WP_ID}\tdur=${exec_dur}\tstart=${exec_start}\tend=${exec_end}" >> ${wp_tmp}

			# extract expected result var from meta
			# extract policy from wp
			submitWPLog "${WP_ID}" "${wp_tmp}"
			mv ${wp_tmp} ${WP_FOLDER}/${WP_ID}/execution-$( ${DATE_BIN} +"%Y-%m-%d_%H_%M_%S" ).log

			if [ ${wp_ret_val:-1} -eq 0 ]; then
				output "WP processing of ${WP_ID} is successful"
				submitWPStatus "${WP_ID}" 8 # wp processing success
			else
				output "WP processing of ${WP_ID} not succesful"
				submitWPStatus "${WP_ID}" 9 # wp processing failed
			fi
		else
			if [ ! -d ${WP_FOLDER}/${WP_ID} ]; then
				output "processWP, ${WP_FOLDER}/${WP_ID} does not exist" 1>&2
			else
				if [ ! -f ${WP_FOLDER}/${WP_ID}/${WP_ID}.sh ]; then
					output "${WP_FOLDER}/${WP_ID}/${WP_ID}.sh is not a file" 1>&2
				fi
			fi
		fi
	else
		output "processWP, WP_ID is empty" 1>&2
	fi

	if ${DEBUG}; then
		output "end processWP, wp_ret_val=${wp_ret_val:-100}" 1>&2
	fi
}

function preprocessWP()
{
	if ${DEBUG}; then
		output "start preprocessWP" 1>&2
	fi
	# manage queue
	if ${LOW_DISK_SPACE}; then
		output "Not downloading any workpackage as the disk space is low" 1>&2
	else
		#if ${BUSY}; then
		if [ -f ${BUSY_INDICATOR_FILE} ] && $( ${CAT_BIN} ${BUSY_INDICATOR_FILE} ); then
			output "Not downloading any workpackage as the client is processing another one" 1>&2
		else
			BUSY=true
			echo -n "${BUSY}" > ${BUSY_INDICATOR_FILE}

			WP_ID=$( getWPId )

			retr_status=$( retrieveWP "${WP_ID}" )
			#  remove this debug output
			output "retr_status: ${retr_status}" 1>&2

			if [ ${retr_status:-1} -eq 0 ]; then
				folder_create_ret_val=$( createWPFolder "${WP_ID}" )
				#  remove this debug output
				output "folder_create_ret_val: ${folder_create_ret_val}" 1>&2

				if ${folder_create_ret_val}; then
					unpack_res=$( unpackWP "${WP_ID}" "WP" )
					# TODO remove this debug output
					output "unpack_res: ${unpack_res}" 1>&2

					if ${unpack_res}; then
						wp_integrity=$( checkWPIntegrity "${WP_ID}" )
						# TODO remove this debug output
						output "wp_integrity: ${wp_integrity}" 1>&2

						if ${wp_integrity}; then
							#s
							submitWPStatus "${WP_ID}" 3 # download succesful
							processWP "${WP_ID}" "WP"
						else
							output "WP integrity could not be verified, removing wp" 1>&2
							removeWP "${WP_ID}"
							submitWPStatus "${WP_ID}" 4 # download Faulty
							#setWPStatus downloadFaulty
						fi
					else
						if ${DEBUG}; then
							output "Unpack failed, WP not processed" 1>&2
						fi
						removeWP "${WP_ID}"
						submitWPStatus "${WP_ID}" 4 # download Faulty
					fi
				else
					output "Could not create folder for WP_ID=${WP_ID}" 1>&2
					removeWP "${WP_ID}"
					submitWPStatus "${WP_ID}" 22 # local error
				fi
			else
				output "PreprocessWP, failure with downloading WP_ID=${WP_ID}, status=${retr_status}" 1>&2
			fi
			BUSY=false
			echo -n "${BUSY}" > ${BUSY_INDICATOR_FILE}
		fi
	fi

	if ${DEBUG}; then
		output "end preprocessWP" 1>&2
	fi
}

function processServiceRequest()
{
	if ${DEBUG}; then
		output "start processServiceRequest" 1>&2
	fi
	# ignore low space warning
	# ignore busy
	# cannot ignore no-connectivity
	if ${OFFLINE_MODE}; then
		output "processServiceRequest - Cannot retrieve service request as no network connectivity is detected" 1>&2
	else
		#if ${SERVICE_REQUEST_BUSY}; then
		if [ -f ${SR_BUSY_INDICATOR_FILE} ] && $( ${CAT_BIN} ${SR_BUSY_INDICATOR_FILE} ); then
			output "processServiceRequest - Cannot download service request, as another service request is currently executed" 1>&2
		else
			# relies on the server responding with the most important
			# service request first
			SERVICE_REQUEST_BUSY=true
			echo -n "${SERVICE_REQUEST_BUSY}" > ${SR_BUSY_INDICATOR_FILE}

			WP_ID=$( getWPId )

			retr_status=$( retrieveWP "${WP_ID}" )
			if [ "${retr_status:-1}" == "0" ]; then
				folder_create_ret_val=$( createWPFolder "${WP_ID}" )
				if ${folder_create_ret_val}; then
					unpack_res=$( unpackWP "${WP_ID}" "SR" )
					if ${unpack_res}; then
						wp_integrity=$( checkWPIntegrity "${WP_ID}" )
						if ${wp_integrity}; then
							submitWPStatus "${WP_ID}" 3 # download succesful
							processWP "${WP_ID}" "SR"
						else
							output "processServiceRequest - WP integrity could not be verified, removing WP/SR" 1>&2
							removeWP "${WP_ID}"
							submitWPStatus "${WP_ID}" 4 # download Faulty
							#setWPStatus downloadFaulty
						fi
					else
						if ${DEBUG}; then
							output "Unpack failed, WP/SR not processed" 1>&2
						fi
						removeWP "${WP_ID}"
						submitWPStatus "${WP_ID}" 4 # download Faulty
					fi
				else
					output "processServiceRequest - Could not create folder for WP_ID=${WP_ID}" 1>&2
					removeWP "${WP_ID}"
					submitWPStatus "${WP_ID}" 22 # local error
				fi
			else
				output "processServiceRequest - Could not download SR for WP_ID=${WP_ID}" 1>&2
			fi
			SERVICE_REQUEST_BUSY=false
			echo -n "${SERVICE_REQUEST_BUSY}" > ${SR_BUSY_INDICATOR_FILE}
		fi
	fi

	if ${DEBUG}; then
		output "end processServiceRequest" 1>&2
	fi
}
# execute sa user scriptex
# part of group script
# group has access to printer/usb and can execute only
# from the WP_FOLDER

function cleanup()
{
	if ${DEBUG}; then
		output "start cleanup" 1>&2
	fi
	# Wait until the last WP is completed
	while ${BUSY}; do
		${SLEEP_BIN} 1s
	done
	# Wait until the last service request is completed
	while ${SERVICE_REQUEST_BUSY}; do
		${SLEEP_BIN} 1s
	done

	if ${OFFLINE_MODE}; then
		output "Not deleting ${WP_FOLDER} as the client is offline" 1>&2
	else
		if [ -d ${CHROOT_BASE_DIR}/dev ]; then
			if ${DEBUG}; then
				output "Umount /dev from chroot"
			fi
			${SUDO_BIN} ${UMOUNT_BIN} -f ${CHROOT_BASE_DIR}/dev
		fi
		if [ -d ${CHROOT_BASE_DIR}/proc ]; then
			if ${DEBUG}; then
				output "Deleting /proc from chroot"
			fi
			${SUDO_BIN} ${UMOUNT_BIN} -f ${CHROOT_BASE_DIR}/proc
		fi

		#for f in $( ${LS_BIN} -d ${WP_FOLDER}/*/ ); do
		#	if ${DEBUG}; then
		#		output "Removing dev and proc in ${f}"
		#	fi
		#	${SUDO_BIN} ${UMOUNT_BIN} -f ${f}/dev
		#	${SUDO_BIN} ${UMOUNT_BIN} -f ${f}/proc
		#do
		if [ -d ${WP_FOLDER} ]; then
			if ${DEBUG}; then
				output "Deleting WP_FOLDER at ${WP_FOLDER}"
			fi
			${SUDO_BIN} ${RM_BIN} -rf ${WP_FOLDER}
		fi
		
		if [ -d ${CHROOT_BASE_DIR} ]; then
			if ${DEBUG}; then
				output "Deleting ${CHROOT_BASE_DIR}"
			fi
			${SUDO_BIN} ${RM_BIN} -rf ${CHROOT_BASE_DIR}
		fi
	fi
	# kill watchdog daemon
	# make sure all data is uploaded

	if [ $( ${PS_BIN} -jfe | ${GREP_BIN} -v "grep" | ${GREP_BIN} -c "${SPAWN_TMP_SH}" ) -eq 0 ]; then
		output "Checking daemon is not running, good" 1>&2
	else
		PS_LIST=$( ${PS_BIN} -jfe | ${GREP_BIN} -v "grep" | ${GREP_BIN} "${SPAWN_TMP_SH}" | ${AWK_BIN} '{ print $2 }' | ${TR_BIN} "\n" " " )
		kill ${PS_LIST}
		${SLEEP_BIN} 2s
		kill -KILL ${PS_LIST}
		${RM_BIN} -rf ${SPAWN_TMP_SH}
	fi

	${RM_BIN} -rf ${OFFLINE_INDICATOR_FILE}
	${RM_BIN} -rf ${SR_BUSY_INDICATOR_FILE}
	${RM_BIN} -rf ${BUSY_INDICATOR_FILE}
	${RM_BIN} -rf ${RNDV_FILE}

	if ${DEBUG}; then
		output "end cleanup" 1>&2
	fi
}

function getMAC()
{
	if ${DEBUG}; then
		output "start getMAC" 1>&2
	fi

	${IP_BIN} link show ${ETH_DEV} | ${GREP_BIN} "ether" | ${AWK_BIN} '{ print $2 }'

	if ${DEBUG}; then
		output "end getMAC" 1>&2
	fi
}

function getCPUId()
{
	if ${DEBUG}; then
		output "start getCPUId" 1>&2
	fi

	${CAT_BIN} /proc/cpuinfo | ${GREP_BIN} "^Serial" | ${TAIL_BIN} -1l | ${AWK_BIN} -F ":" '{ print $2 }' | ${TR_BIN} -d " "

	if ${DEBUG}; then
		output "end getCPUId" 1>&2
	fi
}

function getMMCId()
{
	if ${DEBUG}; then
		output "start getMMCId" 1>&2
	fi

	${FDISK_BIN} -l /dev/mmcblk0 | ${GREP_BIN} -m 1 "^Disk identifier" | ${AWK_BIN} '{ print $3 }'

	if ${DEBUG}; then
		output "end getMMCId" 1>&2
	fi
}

function getCPUData()
{
	if ${DEBUG}; then
		output "start getCPUData" 1>&2
	fi

	${CAT_BIN} /proc/cpuinfo

	if ${DEBUG}; then
		output "end getCPUData" 1>&2
	fi
}

function getLoad()
{
	if ${DEBUG}; then
		output "start getLoad" 1>&2
	fi
#	1min 5min 15min
	${CAT_BIN} /proc/loadavg | ${AWK_BIN} '{ print $1" "$2" "$3 }'

	if ${DEBUG}; then
		output "end getLoad" 1>&2
	fi
}

function getMemInfo()
{
	if ${DEBUG}; then
		output "start getMemInfo" 1>&2
	fi
#	MemTotal_KiB MemFree_KiB MemAvailable_KiB
	${CAT_BIN} /proc/meminfo | ${GREP_BIN} "^Mem" | ${AWK_BIN} '{ print $2 }' | ${TR_BIN} "\n" " "

	if ${DEBUG}; then
		output "end getMemInfo" 1>&2
	fi
}

function getNetInfo()
{
	if ${DEBUG}; then
		output "start getNetInfo" 1>&2
	fi
#	RX_bytes RX_packets TX_bytes TX_packets
	${CAT_BIN} /proc/net/dev | ${GREP_BIN} "${ETH_DEV}" | ${AWK_BIN} '{ print $2" "$3" "$10" "$11 }'

	if ${DEBUG}; then
		output "end getNetInfo" 1>&2
	fi
}

function getTemperature()
{
	if ${DEBUG}; then
		output "start getTemperature" 1>&2
	fi

	${AWK_BIN} '{ printf "%3.1f\n", $1/1000 }' /sys/class/thermal/thermal_zone0/temp

	if ${DEBUG}; then
		output "end getTemperature" 1>&2
	fi
}

function getInternalIP()
{
	if ${DEBUG}; then
		output "start getInternalIP" 1>&2
	fi

	${IP_BIN} addr show dev ${ETH_DEV} | ${GREP_BIN} -m 1 "inet" | ${AWK_BIN} '{ print $2 }' | ${AWK_BIN} -F"/" '{ print $1 }'

	if ${DEBUG}; then
		output "end getInternalIP" 1>&2
	fi
}

function getExternalIP()
{
	if ${DEBUG}; then
		output "start getExternalIP" 1>&2
	fi

	curl_opts="-k -m 2 -s"
	# IPV6
	IPV6=$( ${CURL_BIN} ${curl_opts} "https://icanhazip.com" 2>/dev/null | ${TR_BIN} -d "\r\n" ) # provides IPv4
	if [ "${IPV6}" == "" ]; then
		IPV6=$( ${CURL_BIN}	${curl_opts} "https://myexternalip.com/raw" 2>/dev/null | ${TR_BIN} -d "\r\n" )
		if [ "${IPV6}" == "" ]; then
			IPV6=$( ${CURL_BIN} ${curl_opts} "https://wtfismyip.com/text" 2>/dev/null | ${TR_BIN} -d "\r\n" )
		fi
	fi

	# IPV4
	IPV4=$( ${CURL_BIN} ${curl_opts} "https://ip.appspot.com" 2>/dev/null | ${TR_BIN} -d "\r\n" )
	if [ "${IPV4}" == "" ]; then
		IPV4=$( ${CURL_BIN} ${curl_opts} "https://api.ipify.org" 2>/dev/null | ${TR_BIN} -d "\r\n" )
		if [ "${IPV4}" == "" ]; then
			#IPV4=$( ${WGET_BIN} --timeout=2 -O - -q --no-check-certificate "https://myip.dnsomatic.com/" | ${TR_BIN} -d "\r\n" )
			IPV4=$( ${CURL_BIN} ${curl_opts} "https://myip.dnsomatic.com/" 2>/dev/null | ${TR_BIN} -d "\r\n" )
		fi
	fi

	IPV4=$( echo "${IPV4}" | ${TR_BIN} -dc "0-9\.:" )
	#IPV6=$( echo "${IPV6}" | ${TR_BIN} -dc "0-9\.:" )

	if [ "${IPV6}" == "${IPV4}" ]; then
		echo "N/A ${IPV4:-N/A}"
	else
#	${CURL_BIN} -s http://whatismijnip.nl | ${AWK_BIN} '{ print $5 }'
#	${CURL_BIN} -s http://whatismyip.akamai.com/
#	${CURL_BIN} -s "http://ipecho.net/plain"

	#${IP_BIN} addr show dev ${ETH_DEV} | ${GREP_BIN} -m 1 "inet" | ${AWK_BIN} '{ print $2 }' | ${AWK_BIN} -F"/" '{ print $1 }'
		echo "${IPV6:-N/A} ${IPV4:-N/A}"
	fi

	if ${DEBUG}; then
		output "end getExternalIP" 1>&2
	fi
}

function getDiskSpace()
{
	if ${DEBUG}; then
		output "start getDiskSpace" 1>&2
	fi
	root_info=$( ${DF_BIN} --output=size,used,avail / | ${TAIL_BIN} -1l )
	disk_info=$( ${DF_BIN} --output=size,used,avail ${TMP_FOLDER}/.. | ${TAIL_BIN} -1l )

	echo "${root_info:--1 -1 -1} ${disk_info:--1 -1 -1}"
	if ${DEBUG}; then
		output "end getDiskSpace" 1>&2
	fi
}

function getUptime()
{
	if ${DEBUG}; then
		output "start getUptime" 1>&2
	fi
	# second value in /proc/uptime is idle time
	${CAT_BIN} /proc/uptime | ${AWK_BIN} '{ print $1 }'

	if ${DEBUG}; then
		output "end getUptime" 1>&2
	fi
}

function getAdaptorInfo()
{
	if ${DEBUG}; then
		output "start getAdaptorInfo" 1>&2
	fi

	version=$( ${CAT_BIN} /proc/version )
	mac=$( getMAC )
	load=$( getLoad )
	load_1m=$(  echo "${load}" | ${AWK_BIN} '{ print $1 }' )
	load_5m=$(  echo "${load}" | ${AWK_BIN} '{ print $2 }' )
	load_15m=$( echo "${load}" | ${AWK_BIN} '{ print $3 }' )
	mem=$( getMemInfo )
	mem_total=$( echo "${mem}" | ${AWK_BIN} '{ print $1 }' )
	mem_free=$(  echo "${mem}" | ${AWK_BIN} '{ print $2 }' )
	mem_avail=$( echo "${mem}" | ${AWK_BIN} '{ print $3 }' )

	net=$( getNetInfo )
	net_rx_bytes=$(   echo "${net}" | ${AWK_BIN} '{ print $1 }' )
	net_rx_packets=$( echo "${net}" | ${AWK_BIN} '{ print $2 }' )
	net_tx_bytes=$(   echo "${net}" | ${AWK_BIN} '{ print $3 }' )
	net_tx_packets=$( echo "${net}" | ${AWK_BIN} '{ print $4 }' )

	int_ip=$( getInternalIP )
	ext_ip=$( getExternalIP )
	ext_ip_v6=$( echo "${ext_ip}" | ${AWK_BIN} '{ print $1 }' )
	ext_ip_v4=$( echo "${ext_ip}" | ${AWK_BIN} '{ print $2 }' )
	default_gw=$( ${ROUTE_BIN} -n | ${GREP_BIN} "${ETH_DEV}" | ${GREP_BIN} "^0\." | ${AWK_BIN} '{ print $2 }' )

	disk_space=$( getDiskSpace )
	disk_space_root_size=$(  echo "${disk_space}" | ${AWK_BIN} '{ print $1 }' )
	disk_space_root_used=$(  echo "${disk_space}" | ${AWK_BIN} '{ print $2 }' )
	disk_space_root_avail=$( echo "${disk_space}" | ${AWK_BIN} '{ print $3 }' )
	disk_space_disk_size=$(  echo "${disk_space}" | ${AWK_BIN} '{ print $4 }' )
	disk_space_disk_used=$(  echo "${disk_space}" | ${AWK_BIN} '{ print $5 }' )
	disk_space_disk_avail=$( echo "${disk_space}" | ${AWK_BIN} '{ print $6 }' )

	no_processes=$( ${PS_BIN} -e | ${WC_BIN} -l )

	temp=$( getTemperature )

	mmc_id=$( getMMCId )
	cpu_id=$( getCPUId )

	etchash=$(  ${SHA_BIN} /etc/* 2>/dev/null | ${SHA_BIN} | ${AWK_BIN} '{ print $1 }' )
	confhash=$( ${SHA_BIN} ${CONFIG_FILE}     | ${AWK_BIN} '{ print $1 }' )

	uptime=$( getUptime )

	retr_date=$( ${DATE_BIN} +"%s.%N" )

	host_name=$( hostname -s )
	if [ -f ${RNDV_FILE} ]; then
		var_exp=$( ${CAT_BIN} ${RNDV_FILE} )
		eval "${var_exp:-WP_FAIL_COUNTER=-3}"
	fi
	# WP_START
	# STATUS are global var that are inaccesible in the background
	# loop of status

	echo "{ \"status\": {
		\"date\": \"${retr_date}\",
		\"wp_stats\": {
			\"start\": ${WP_START_COUNTER:--1},
			\"comp\": ${WP_COMPL_COUNTER:--1},
			\"fail\": ${WP_FAIL_COUNTER:--1},
			\"succ\": ${WP_SUCC_COUNTER:--1}
		},
		\"prun\": \"${PRINTRUN_VERS:-N/A}\",
		\"it\": ${STAT_COUNTER:--1},
		\"pid\": ${MAIN_PID:--1},
		\"procs\": ${no_processes:--1},
		\"vers\": \"${version:-N/A}\",
		\"uptime\": ${uptime:--1},
		\"etchash\": \"${etchash:0:32}\",
		\"confhash\": \"${confhash:0:32}\",
		\"clienthash\": \"${MAIN_SCRIPT_HASH:-N/A}\",
		\"load\": {
			\"1m\": ${load_1m:--1.0},
			\"5m\": ${load_5m:--1.0},
			\"15m\": ${load_5m:--1.0}
		},
		\"mem\": {
			\"total\": ${mem_total:--1},
			\"free\": ${mem_free:--1},
			\"avail\": ${mem_avail:--1},
			\"unit\": \"KiB\"
		},
		\"disk\": {
			\"root\": {
				\"size\": ${disk_space_root_size:--1},
				\"used\": ${disk_space_root_used:--1},
				\"avail\": ${disk_space_root_avail:--1},
				\"unit\": \"bytes\"
			},
			\"part\": {
				\"size\": ${disk_space_disk_size:--1},
				\"used\": ${disk_space_disk_used:--1},
				\"avail\": ${disk_space_disk_avail:--1},
				\"unit\": \"bytes\"
			}
		},
		\"net\": {
			\"mac\": \"${mac}\",
			\"ip\": {
				\"int\": \"${int_ip:-N/A}\",
				\"defgw\": \"${default_gw:-N/A}\",
				\"ext\": {
					\"v4\": \"${ext_ip_v4:-N/A}\",
					\"v6\": \"${ext_ip_v6:-N/A}\"
				}
			},
			\"rx\": {
				\"b\": ${net_rx_bytes:--1},
				\"pcks\": ${net_rx_packets:--1}
			},
			\"tx\": {
				\"b\": ${net_tx_bytes:--1},
				\"pcks\": ${net_tx_packets:--1}
			}
		},
		\"temp\": ${temp:--99.99},
		\"mmc_id\": \"${mmc_id:-N/A}\",
		\"cpu_id\": \"${cpu_id:-N/A}\",
		\"hostname\": \"${host_name:-N/A}\"	} }" | ${TR_BIN} -d "\r\n\t" | ${SED_BIN} -e "s/: /:/g"

	if ${DEBUG}; then
		output "end getAdaptorInfo, STATUS_COUNTER=${STATUS_COUNTER}" 1>&2
	fi
}

function statusLoop()
{
	if ${DEBUG}; then
		output "start statusLoop" 1>&2
	fi
	# sleep 15 seconds for offline check etc. in main loop
	# to complete
	${SLEEP_BIN} 15s

	# re-read config as we are in a separate shell
	BASE_URL=""
	BASE_SCHEMA=""
	CLIENT_UA=""
	CLIENT_SECRET=""
	CLIENT_ID=""
	MAIN_PID=""
	STAT_COUNTER=0

	readConfig

	while true; do
		#echo "status loop - vars: id=${CLIENT_ID} base=${BASE_URL}"
		if [ -f ${OFFLINE_INDICATOR_FILE} ] && $( ${CAT_BIN} ${OFFLINE_INDICATOR_FILE} ); then
			if ${DEBUG}; then
				echo "Offline mode, not going to update adaptor stats, trying again in ${STATUS_INTERVAL}s" 1>&2
			fi
		else
			adaptorInfo=$( getAdaptorInfo )
			# submit adaptorInfo to service

			server_response=$( ${TIMEOUT_BIN} ${TO_VAL} ${CURL_BIN} ${CURL_OPTS} -X POST \
				--data "status=${adaptorInfo}" \
				--data "adaptor_key=${CLIENT_SECRET}" \
				--user-agent "${CLIENT_UA}" \
				"${BASE_SCHEMA}://${BASE_URL}:${SERVICE_PORT}/${SUBMIT_WP_STAT_ENDPOINT}/${CLIENT_ID}" 2>/dev/null )
			# server_response
			# 0 -> communication and storage ok
			# else -> error
			#output "server response: ${server_response}"
			if [ ${server_response:-1} -eq 0 ]; then
				if ${DEBUG}; then
					output "statusLoop, upload and storage of adaptor stats succesful" 1>&2
				fi
			else
				if ${DEBUG}; then
					output "statusLoop, upload and storage of adaptor stats failed" 1>&2
				fi
			fi
			let STAT_COUNTER+=1
		fi
		${SLEEP_BIN} ${STATUS_INTERVAL:-30}s
	done

	if ${DEBUG}; then
		output "end statusLoop, server_response=${server_response:-1}" 1>&2
	fi
}

function mainLoop()
{
	if ${DEBUG}; then
		output "start mainLoop" 1>&2
	fi
	output "Client started" >> ${LOG_FILE}

	checkBinaries
	readConfig
	if ${DEBUG}; then
		output "Creating chroot template dir" 1>&2
	fi
	${CHROOT_SH} "preCreate"

	# Create initial rendezvous file that
	# contains the main PID that is
	# send by the status package
	echo "WP_START_COUNTER=${WP_START_COUNTER:-0} WP_COMP_COUNTER=${WP_COMP_COUNTER:-0} WP_SUCC_COUNTER=${WP_SUCC_COUNTER:-0} WP_FAIL_COUNTER=${WP_FAIL_COUNTER:-0} MAIN_PID=$$" > ${RNDV_FILE}

	while true; do
		checkDaemon
		checkConnectivity
		checkDiskSpace

		if ${EXIT_SIGNAL}; then
			cleanup
			break
		fi

		if ${OFFLINE_MODE}; then
			output "Offline mode, not going to query server" 1>&2
		else
			server_response=$( queryServer )
			case ${server_response:-0} in
				0)	if ${DEBUG}; then
						output "No response or error from service" 1>&2
					fi
					;;
				1)	if ${DEBUG}; then
						output "No workpackage available" 1>&2
					fi
					;;
				2)	output "One workpackage available" 1>&2
					( preprocessWP ) &
					;;
				3)	output "Multiple workpackages available" 1>&2
					( preprocessWP ) &
					;;
				4)	output "Processing service request" 1>&2
					( processServiceRequest ) &
					;;
				*)	output "QueryServer - Unknown response code -> \"${server_response}\"" 1>&2
					;;
			esac
		fi
		${SLEEP_BIN} ${GRACE_PERIOD:-20}s
	done

	output "Client stopped" >> ${LOG_FILE}

	if ${DEBUG}; then
		output "end mainLoop" 1>&2
	fi
}

function harden()
{
	if ${DEBUG}; then
		output "start harden" 1>&2
	fi

	if [ ! "${WP_FOLDER}" == "" ] && [ -d ${WP_FOLDER} ]; then
		${CHMOD_BIN} -R g-rwx,o-rwx ${WP_FOLDER}
	fi
	${CHMOD_BIN} g-rwx,o-rwx ${MAIN_SCRIPT_NAME}

	if ${DEBUG}; then
		output "end harden" 1>&2
	fi
}

function welcomeMsg()
{
	output "Service client for 3D printing service, 2016 v${VERS} by F. Baumann"
	output "Licensed under CC-BY"
	output "Executing ${MAIN_SCRIPT_NAME}"
}

harden
welcomeMsg
( sleep 20s && statusLoop ) &
mainLoop

# TODO webcam handling / pi-cam?
