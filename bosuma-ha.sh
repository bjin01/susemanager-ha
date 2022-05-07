#!/bin/bash

# get product name, default: SUSE Manager
IFS=" = "
DEFAULT_RHN_CONF="/usr/share/rhn/config-defaults/rhn.conf"

if [ -f "$DEFAULT_RHN_CONF" ]; then
    while read -r name value
    do
        if [ "$name" == "product_name" ]; then
            PRODUCT_NAME=$value
        fi
    done < $DEFAULT_RHN_CONF
fi
if [ ! -n "$PRODUCT_NAME" ]; then
    PRODUCT_NAME="SUSE Manager"
fi

DISTRIBUTION_ID="$(source /etc/os-release && echo ${ID})"
case ${DISTRIBUTION_ID} in
    sles|suse-manager-server) JVM='/usr/lib64/jvm/jre-11-openjdk/bin/java';;
    opensuse|opensuse-leap)   JVM='/usr/lib64/jvm/jre-11-openjdk/bin/java';;
    centos|rhel)              JVM='java-11-openjdk.x86_64';; 
    *)                        echo 'Unknown distribution!'
                              exit 1;;
esac

if [ ! $UID -eq 0 ]; then
    echo "You need to be superuser (root) to run this script!"
    exit 1
fi

# check for uppercase chars in hostname
HOSTNAME=`hostname -f`
if [ "$HOSTNAME" != "$(echo $HOSTNAME | tr '[:upper:]' '[:lower:]')" ]
then
    echo "Uppercase characters are not allowed for $PRODUCT_NAME hostname."
    exit 1
fi


TMPDIR="/var/spacewalk/tmp"
LOGFILE="0"
WAIT_BETWEEN_STEPS=0
MANAGER_FORCE_INSTALL=0
PROGRAM="/usr/lib/susemanager/bin/bosuma-ha.sh"

SETUP_ENV="/root/sumaha_env.sh"
RSYNC_LOG="/var/log/rhn/bosuma-ha-rsync.log"

PRIMARY_FQDN=""
PRIMARY_IP=""
STANDBY_SIGNAL="/var/lib/pgsql/data/standby.signal"
FROMVERSION="4.2"
KEYFILE="/root/.ssh/id_rsa"
DBDUMPFILE="susemanager.dmp.gz"
SERVER_CRT="/etc/pki/tls/certs/spacewalk.crt"
[ -z "$SERVER_KEY" ] && { SERVER_KEY="/etc/pki/tls/private/spacewalk.key"; }

RSYNC_PASSWORD=""

LOCAL_DB=1
DB_BACKEND="postgresql"

function help() {
    echo "
Usage: $0 [OPTION]
helper script to do migration or setup of $PRODUCT_NAME

  -r             only sync remote files
  -l LOGFILE     write a log to LOGFILE
  -h             this help screen


"
}

wait_step() {
    if [ $? -ne 0 ]; then
        echo "Something didn't work. Syncing failed. Please check logs ($LOGFILE)"
        exit 1
    fi

    if [ "$WAIT_BETWEEN_STEPS" = "1" ];then
        echo "Press Return to continue"
        read
    fi;
}

copy_remote_files() {
    SUMAFILES="/etc/salt
               /root/ssl-build
               /srv/www/cobbler/images
               /srv/www/cobbler/ks_mirror
               /srv/www/cobbler/links
               /srv/www/cobbler/localmirror
               /srv/www/cobbler/pub
               /srv/www/cobbler/rendered
               /srv/www/cobbler/repo_mirror
               /srv/www/cobbler/svc
               /srv/www/cobbler/misc
               /srv/formula_metadata
               /srv/pillar
               /srv/salt
               /usr/share/salt-formulas
               /srv/susemanager
               /srv/tftpboot
               /srv/www/htdocs/pub
               /srv/www/os-images
               /var/cache/rhn
               /var/cache/salt
               /var/lib/cobbler/config
               /var/lib/Kiwi
               /var/lib/rhn
               /var/lib/salt
               /var/lib/spacewalk
               /var/log/rhn
               /var/spacewalk/rhn
               /var/spacewalk/suse
               /var/spacewalk/systems
               /var/spacewalk/packages"

    echo "Copy files from primary $PRODUCT_NAME..."

    for DIR in $SUMAFILES; do
        DEST=`dirname "$DIR"`
        ssh -i $KEYFILE root@$PRIMARY_IP "test -d $DIR"
        if [ $? -eq 0 ]; then
            echo "`date +"%H:%M:%S"`   Copy $DIR ..."
            rsync -e "ssh -i $KEYFILE -l root" -avz root@$PRIMARY_IP:$DIR $DEST >> $RSYNC_LOG
        else
            echo "`date +"%H:%M:%S"`   Skipping non-existing $DIR ..."
        fi
    done

    echo "`date +"%H:%M:%S"`   Copy /root/.ssh ..."
    rsync -e "ssh -i $KEYFILE -l root" -avz root@$PRIMARY_IP:/root/.ssh/ /root/.ssh.new >> $RSYNC_LOG

    echo "`date +"%H:%M:%S"`   Copy /etc/cobbler/settings ..."
    rsync -e "ssh -i $KEYFILE -l root" -avz root@$PRIMARY_IP:/etc/cobbler/settings /etc/cobbler/settings.old >> $RSYNC_LOG

    echo "`date +"%H:%M:%S"`   Copy certificates ..."
    scp -i $KEYFILE -p root@$PRIMARY_IP:/etc/pki/trust/anchors/salt-api.crt /etc/pki/trust/anchors/salt-api.crt
    scp -i $KEYFILE -p root@$PRIMARY_IP:/etc/pki/spacewalk/jabberd/server.pem /etc/pki/spacewalk/jabberd/server.pem
    scp -i $KEYFILE -p root@$PRIMARY_IP:$SERVER_CRT /etc/apache2/ssl.crt/server.crt
    scp -i $KEYFILE -p root@$PRIMARY_IP:$SERVER_KEY /etc/apache2/ssl.key/server.key
    ln -sf ../../../apache2/ssl.crt/server.crt /etc/pki/tls/certs/spacewalk.crt
    ln -sf ../../../apache2/ssl.key/server.key /etc/pki/tls/private/spacewalk.key
    scp -i $KEYFILE -p root@$PRIMARY_IP:/etc/rhn/rhn.conf /etc/rhn/rhn.conf-$FROMVERSION

    # assert correct ownership and permissions
    chmod 600 /etc/pki/spacewalk/jabberd/server.pem
    chown jabber:jabber /etc/pki/spacewalk/jabberd/server.pem
    chown wwwrun:tftp /srv/tftpboot
    chmod 750 /srv/tftpboot
    chown -R wwwrun.www /var/spacewalk/packages
    chown -R wwwrun.www /var/spacewalk/rhn
    chown -R wwwrun.www /var/spacewalk/suse
    chown -R wwwrun.www /var/spacewalk/systems
    ln -sf /srv/www/htdocs/pub/RHN-ORG-TRUSTED-SSL-CERT /etc/pki/trust/anchors
    update-ca-certificates
}

compare_suma_version () {
    echo "we get to compare..."
    ssh -i $KEYFILE -o "StrictHostKeyChecking no" root@$PRIMARY_IP "test -e /usr/share/doc/packages/patterns-suma-server/suma_server.txt"
    if [ $? -eq 0 ]; then
       SRC_SUMA_VERSION=$(ssh -i $KEYFILE -o "StrictHostKeyChecking no" root@$PRIMARY_IP "rpm -q  patterns-suma_server")
       echo $SRC_SUMA_VERSION
    fi
    test -e /usr/share/doc/packages/patterns-suma-server/suma_server.txt
    if [ $? -eq 0 ]; then
        DST_SUMA_VERSION=$(rpm -q  patterns-suma_server)
        echo $DST_SUMA_VERSION
    fi
    if [[ $SRC_SUMA_VERSION =~ ^patterns-suma_server.* ]] && [[ $DST_SUMA_VERSION =~ ^patterns-suma_server.* ]]; then
        if [[ $SRC_SUMA_VERSION == $DST_SUMA_VERSION ]]; then
	    echo "Wow, it looks both SUMA are in same version. Great Job. We continue!"
            sleep 2
	else
            echo "$SRC_SUMA_VERSION $DST_SUMA_VERSION are not in same major and minior version. \
		bring both SUSE Manager in the exact same version please. we exit here!"
            exit 2
       fi
    fi
}

check_if_standby_host() {
    echo "We check if this host is in standby mode. This ensures we are not copying files to a primary server by mistake."
    echo "Does this file exist? /var/lib/pgsql/data/standby.signal"
    if [ -f "$STANDBY_SIGNAL" ]; then
        echo "OK, this host is in standby mode."
    else
        echo "This host is not yet configured as postgres standby server. We exit here"
        exit 2
    fi
    
    echo "Now we check if the host has the IP of standby server you configured."
    ip address show | grep "${STANDBY_IP}\/"
    if [ $? -eq 0 ]; then
        echo "OK, the standby server IP has been found. Continue."
    else
        echo "Not good. The standby server ip is not found on this host. Exit"
        exit 2
    fi

    ip address show | grep "${PRIMARY_IP}\/"
    if [ $? -eq 0 ]; then
        echo "Not good. The primary server ip has been found on this host. The script can only be run on standby server."
        exit 2        
    fi
}

check_remote_type() {
    case "$FROMVERSION" in
        4.2)
            echo "Before we start we will double check if both SUSE Manager hosts have same version which must be 4.2. "
            check_if_standby_host
            compare_suma_version
            ;;
        *)
            echo
            echo "Unknown version to copy from: \"$FROMVERSION\""
            echo "Type \"$PROGRAM -h\" for valid versions."
            echo
            exit 1
            ;;
    esac

    echo -n "Checking for /etc/pki/tls/certs/spacewalk.crt..."
    ssh -i $KEYFILE root@$PRIMARY_IP "test -e /etc/pki/tls/certs/spacewalk.crt"
    if [ $? -eq 0 ]; then
        echo " found"
        SERVER_CRT="/etc/pki/tls/certs/spacewalk.crt"
        SERVER_KEY="/etc/pki/tls/private/spacewalk.key"
    else
        echo " not found"
        echo -n "Checking for /etc/apache2/ssl.crt/spacewalk.crt..."
        ssh -i $KEYFILE root@$PRIMARY_IP "test -e /etc/apache2/ssl.crt/spacewalk.crt"
        if [ $? -eq 0 ]; then
            echo " found"
            SERVER_CRT="/etc/apache2/ssl.crt/spacewalk.crt"
            SERVER_KEY="/etc/apache2/ssl.key/spacewalk.key"
        else
            echo " not found"
            echo
            echo "Cannot find /etc/pki/tls/certs/spacewalk.crt nor /etc/pki/tls/certs/spacewalk.crt"
            echo "on source system. Giving up!"
            echo
            exit 1
        fi
    fi

    echo "Found $SERVER_CRT and $SERVER_KEY on source system."
}


activate_rhn_conf () {
    mv /etc/rhn/rhn.conf /etc/rhn/rhn.conf.bosuma_backup
    cp /etc/rhn/rhn.conf-$FROMVERSION /etc/rhn/rhn.conf
    chmod 640 /etc/rhn/rhn.conf
    # Detect the Apache group name (SUSE/RHEL differences)
    APACHE_GROUP=`cut -d: -f3 < <((getent group www)||(getent group apache))`
    chown root:${APACHE_GROUP} /etc/rhn/rhn.conf
}

####################################################
# Start
####################################################

PROGRAM="$0"

while [ -n "$1" ]
do
    p="$1"

    case "$p" in
    -r)
        . $SETUP_ENV
        PRIMARY_FQDN="$PRIMARY_FQDN"
        PRIMARY_IP="$PRIMARY_IP"
        check_remote_type
        copy_remote_files
        activate_rhn_conf
       ;;
    -h)
        help
       ;;
    -l)
        shift
        LOGFILE="$1"
        ;;
    *)
       echo
       echo "Option \"$p\" is not recognized. Type \"$PROGRAM -h\" for help."
       echo
       exit 1
       ;;
    esac

    shift
done

if [ "$LOGFILE" != "0" ]; then
    #set -x
    exec >> >(tee $LOGFILE | sed 's/^/  /' ) 2>&1
fi

# vim: set expandtab:
