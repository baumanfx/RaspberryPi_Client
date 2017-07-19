#!/bin/bash

########################################################################
# Darkhattpd startup script for the client-server system to
# execute workpackges on a Raspberry Pi
# Felix W. Baumann
# 2017-07-19
# CC-BY
########################################################################
HTTP_USER=nobody
HTML_DIR=$( sudo -u ${HTTP_USER} mktemp -d --tmpdir=/tmp )
HTML_FILE=${HTML_DIR}/index.html
CONF_FILE=/mount_rw/.printing-client/client.conf

if [ ! -d ${HTML_DIR} ]; then
	echo "Could not create temporary file at ${HTML_DIR}, abort"
	exit 5
fi

if [ -f ${CONF_FILE} ]; then
	ID_SECRET=$( grep "^ADAPT_SEC" ${CONF_FILE} | awk -F"=" '{ print $2 }' )
	CLIENT_ID=$( grep "^CLIENT_ID" ${CONF_FILE} | awk -F"=" '{ print $2 }' )
	#USER=p_client
	HTTP_PORT=8080

	echo "<!DOCTYPE html>
<html lang=\"en\">
	<head>
		<meta charset=\"utf-8\">
		<title>Identification of Adaptor Ownership</title>
	</head>
	<body>
		<h1>Adaptor Ownership - Secret</h1>
		The adaptor ID is: <b>${CLIENT_ID:-N/A}</b><br />
		Please enter <b>${ID_SECRET:-N/A}</b> as identification in the service<br />

	</body>
</html>
<!--" | sudo -u ${HTTP_USER} tee ${HTML_FILE}

	#sudo chown -R ${USER} ${HTML_DIR}
	#sudo chmod o+r ${HTML_FILE}

	nobody_uid=$( id -u ${HTTP_USER} )
	nobody_gid=$( id -g ${HTTP_USER} )

	/usr/bin/darkhttpd ${HTML_DIR} --no-listing --no-server-id --no-keepalive --uid ${nobody_uid} --gid ${nobody_gid} --chroot --port ${HTTP_PORT}
else
	echo "Could not start darkhttp as config file does not exist, abort"
	echo "Config file must be at ${CONF_FILE}"
	exit 4
fi
