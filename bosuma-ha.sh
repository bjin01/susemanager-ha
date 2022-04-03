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

# ensure correct java version is being used (bsc#1049575)
echo "Asserting correct java version..."
update-alternatives --set java ${JVM}
if [ ! $? -eq 0 ]; then
    echo "Failed to set ${JVM} as default java version!"
    exit 1
fi

TMPDIR="/var/spacewalk/tmp"
DO_MIGRATION=0
DO_SETUP=0
LOGFILE="0"
WAIT_BETWEEN_STEPS=0
MANAGER_FORCE_INSTALL=0
PROGRAM="/usr/lib/susemanager/bin/bosuma-ha.sh"

MIGRATION_ENV="/root/migration_env.sh"
SETUP_ENV="/root/setup_env.sh"
MANAGER_COMPLETE="/root/.MANAGER_SETUP_COMPLETE"
MANAGER_COMPLETE_HOOK="/usr/lib/susemanager/hooks/suma_completehook.sh"
RSYNC_LOG="/var/log/rhn/bosuma-ha-rsync.log"

SATELLITE_HOST=""
SATELLITE_DOMAIN=""
SATELLITE_DB_USER=""
SATELLITE_DB_PASS=""
SATELLITE_DB_SID=""

SATELLITE_FQDN=""
SATELLITE_IP=""

FROMVERSION="4.2"
KEYFILE="/root/migration-key"
DBDUMPFILE="susemanager.dmp.gz"
SERVER_CRT="/etc/pki/tls/certs/spacewalk.crt"
[ -z "$SERVER_KEY" ] && { SERVER_KEY="/etc/pki/tls/private/spacewalk.key"; }

RSYNC_PASSWORD=""

LOCAL_DB=1
DB_BACKEND="postgresql"

# setup_hostname()
# setup_spacewalk()
# dump_remote_db()
# import_db()
# upgrade_schema()
# copy_remote_files()

function help() {
    echo "
Usage: $0 [OPTION]
helper script to do migration or setup of $PRODUCT_NAME

  -r             only sync remote files (useful for migration only)
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

setup_swap() {

SWAP=`LANG=C free | grep Swap: | sed -e "s/ \+/\t/g" | cut -f 2`
FREESPACE=`LANG=C df / | tail -1 | sed -e "s/ \+/\t/g" | cut -f 4`

if [ $SWAP -eq 0 ]; then
    echo "No swap found; trying to setup additional swap space..."
    if [ $FREESPACE -le 3000000 ]; then
        echo "Not enough space on /. Not adding swap space. Good luck..."
    else
        FSTYPE=`df -T / | tail -1 | awk '{print $2}'`
        if [ $FSTYPE == "btrfs" ]; then
            echo "Will *NOT* create swapfile on btrfs. Make sure you have enough RAM!"
        else
            if [ -f /SWAPFILE ]; then
                swapoff /SWAPFILE
            fi
            dd if=/dev/zero of=/SWAPFILE bs=1M count=2000 status=none
            chmod 0600 /SWAPFILE
            sync
            mkswap -f /SWAPFILE
            if [ "$(grep -ir '/SWAPFILE swap swap defaults 0 0' /etc/fstab)" == "" ]; then
                echo "/SWAPFILE swap swap defaults 0 0" >> /etc/fstab
            fi
            swapon -a
            echo "ok."
        fi
    fi
fi
}



check_btrfs_dirs() {
DIR="/var/spacewalk"
if [ ! -d $DIR ]; then
    FSTYPE=`df -T \`dirname $DIR\` | tail -1 | awk '{print $2}'`
    echo -n "Filesystem type for $DIR is $FSTYPE - "
    if [ $FSTYPE == "btrfs" ]; then
        echo "creating nCoW subvolume."
        mksubvolume --nocow $DIR
    else
        echo "ok."
    fi
else
    echo "$DIR already exists. Leaving it untouched."
fi

DIR="/var/cache"
if [ ! -d $DIR ]; then
    mkdir $DIR
fi
FSTYPE=`df -T $DIR | tail -1 | awk '{print $2}'`
echo -n "Filesystem type for $DIR is $FSTYPE - "
if [ $FSTYPE == "btrfs" ]; then
    TESTDIR=`basename $DIR`
    btrfs subvolume list /var | grep "$TESTDIR" > /dev/null
    if [ ! $? -eq 0 ]; then
        echo "creating subvolume."
        mv $DIR ${DIR}.sav
        mksubvolume $DIR
        touch ${DIR}.sav/foobar.dummy
        if [ ! -d $DIR ]; then
            mkdir $DIR
        fi
        mv ${DIR}.sav/* $DIR
        rmdir ${DIR}.sav
        rm -f $DIR/foobar.dummy
    else
        echo "subvolume for $DIR already exists. Fine."
    fi
else
    echo "ok."
fi
}

open_firewall_ports() {
echo "Open needed firewall ports..."
if [ -x /usr/bin/firewall-cmd ]; then
  firewall-cmd --state 2> /dev/null
  if [ $? -eq 0 ]; then
    firewall-cmd --permanent --zone=public --add-service=suse-manager-server
    firewall-cmd --reload
  else
    firewall-offline-cmd --zone=public --add-service=suse-manager-server
  fi
else
  echo "firewalld not installed" >&2
fi
}

check_re_install() {
if [ -f $MANAGER_COMPLETE ]; then
    echo "$PRODUCT_NAME is already set up. Exit." >&2
    exit 1
fi
}

upgrade_schema() {
    spacewalk-schema-upgrade -y
    if [ $? -eq 0 ]; then
        echo "`date +"%H:%M:%S"`   Schema upgrade successful."
    else
        echo "`date +"%H:%M:%S"`   FAILURE!"
        exit 1
    fi
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

    echo "Copy files from old $PRODUCT_NAME..."

    for DIR in $SUMAFILES; do
        DEST=`dirname "$DIR"`
        ssh -i $KEYFILE root@$SATELLITE_IP "test -d $DIR"
        if [ $? -eq 0 ]; then
            echo "`date +"%H:%M:%S"`   Copy $DIR ..."
            rsync -e "ssh -i $KEYFILE -l root" -avz root@$SATELLITE_IP:$DIR $DEST >> $RSYNC_LOG
        else
            echo "`date +"%H:%M:%S"`   Skipping non-existing $DIR ..."
        fi
    done

    echo "`date +"%H:%M:%S"`   Copy /root/.ssh ..."
    rsync -e "ssh -i $KEYFILE -l root" -avz root@$SATELLITE_IP:/root/.ssh/ /root/.ssh.new >> $RSYNC_LOG

    echo "`date +"%H:%M:%S"`   Copy /etc/cobbler/settings ..."
    rsync -e "ssh -i $KEYFILE -l root" -avz root@$SATELLITE_IP:/etc/cobbler/settings /etc/cobbler/settings.old >> $RSYNC_LOG

    echo "`date +"%H:%M:%S"`   Copy certificates ..."
    scp -i $KEYFILE -p root@$SATELLITE_IP:/etc/pki/spacewalk/jabberd/server.pem /etc/pki/spacewalk/jabberd/server.pem
    scp -i $KEYFILE -p root@$SATELLITE_IP:$SERVER_CRT /etc/apache2/ssl.crt/server.crt
    scp -i $KEYFILE -p root@$SATELLITE_IP:$SERVER_KEY /etc/apache2/ssl.key/server.key
    ln -sf ../../../apache2/ssl.crt/server.crt /etc/pki/tls/certs/spacewalk.crt
    ln -sf ../../../apache2/ssl.key/server.key /etc/pki/tls/private/spacewalk.key
    scp -i $KEYFILE -p root@$SATELLITE_IP:/etc/rhn/rhn.conf /etc/rhn/rhn.conf-$FROMVERSION

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

create_ssh_key() {
    rm -f $KEYFILE
    rm -f $KEYFILE.pub
    echo "Please enter the root password of the remote machine."
    ssh-keygen -q -N "" -C "spacewalk-migration-key" -f $KEYFILE
    ssh-copy-id -i $KEYFILE root@$SATELLITE_IP > /dev/null 2>&1

    TMPFILE=`mktemp`
    echo -n "Testing for silent remote command execution... "
    ssh -i $KEYFILE root@$SATELLITE_IP "su -s /bin/bash - postgres -c \"true\"" > $TMPFILE
    if [ -s $TMPFILE ]; then
        echo "FAILED!"
        echo
        echo "************************************************************************************"
        echo
        echo "Disturbing output from remote shell detected!"
        echo "Please make sure remote commands can be executed silently and try again."
        echo
        echo "Check /etc/profile.d/* and .bashrc files of users root and postgres."
        echo
        echo "For testing make sure the following command does *NOT* produce any output:"
        echo
        echo "ssh -i $KEYFILE root@$SATELLITE_IP \"su -s /bin/bash - postgres -c true\""
        echo
        echo "************************************************************************************"
        echo
        rm -f $TMPFILE
        exit 1
    else
        echo "Ok"
        rm -f $TMPFILE
    fi
}

remove_ssh_key() {
    ssh root@$SATELLITE_IP -i $KEYFILE "grep -v spacewalk-migration-key /root/.ssh/authorized_keys > /root/.ssh/authorized_keys.tmp && mv /root/.ssh/authorized_keys.tmp /root/.ssh/authorized_keys"
    rm -f $KEYFILE
    rm -f $KEYFILE.pub

    # migration also copies the ss stuff from the old machine
    # so remove migration key also from local copy
    if [ -f /root/.ssh/authorized_keys ]; then
        grep -v spacewalk-migration-key /root/.ssh/authorized_keys > /root/.ssh/authorized_keys.tmp && mv /root/.ssh/authorized_keys.tmp /root/.ssh/authorized_keys
    fi
}

check_remote_type() {
    case "$FROMVERSION" in
        3.1)
            echo "Migrating from remote system $PRODUCT_NAME 3.1"
            ;;
        4.2)
            echo "Migrating from remote system $PRODUCT_NAME 4.2, ho ho ho"
            ;;
        *)
            echo
            echo "Unknown version to migrate from: \"$FROMVERSION\""
            echo "Type \"$PROGRAM -h\" for valid versions."
            echo
            exit 1
            ;;
    esac

    echo -n "Checking for /etc/pki/tls/certs/spacewalk.crt..."
    ssh -i $KEYFILE root@$SATELLITE_IP "test -e /etc/pki/tls/certs/spacewalk.crt"
    if [ $? -eq 0 ]; then
        echo " found"
        SERVER_CRT="/etc/pki/tls/certs/spacewalk.crt"
        SERVER_KEY="/etc/pki/tls/private/spacewalk.key"
    else
        echo " not found"
        echo -n "Checking for /etc/apache2/ssl.crt/spacewalk.crt..."
        ssh -i $KEYFILE root@$SATELLITE_IP "test -e /etc/apache2/ssl.crt/spacewalk.crt"
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

do_migration() {
    if [ ! -d $TMPDIR ]; then
        echo "$TMPDIR does not exist; creating it..."
        umask 0022
        mkdir -p $TMPDIR
    fi

    if [ "$DB_BACKEND" = "postgresql" ]; then
        echo "Ensuring postgresql has read permissions on $TMPDIR for database dump..."
        chmod go+rx $TMPDIR
    fi

    echo
    echo
    echo "Migration needs to execute several commands on the remote machine."
    create_ssh_key

    if [ "x" = "x$SATELLITE_HOST" ]; then
        echo -n "SATELLITE_HOST:";   read SATELLITE_HOST
        echo -n "SATELLITE_DOMAIN:"; read SATELLITE_DOMAIN
        echo -n "SATELLITE_DB_USER"; read SATELLITE_DB_USER
        echo -n "SATELLITE_DB_PASS"; read SATELLITE_DB_PASS
        echo -n "SATELLITE_DB_SID";  read SATELLITE_DB_SID
        echo -n "MANAGER_IP";        read MANAGER_IP
    fi;

    # re-use database configuration from source system on new one
    DB_BACKEND="postgresql"
    LOCAL_DB="1"
    MANAGER_DB_HOST="localhost"
    MANAGER_DB_PORT="5432"
    MANAGER_DB_PROTOCOL="TCP"
    MANAGER_DB_NAME=$SATELLITE_DB_SID
    MANAGER_USER=$SATELLITE_DB_USER
    MANAGER_PASS=$SATELLITE_DB_PASS
    MANAGER_PASS2=$SATELLITE_DB_PASS


    # those values will be overwritten by the copied certificate
    CERT_CNAMES=""
    CERT_O="dummy"
    CERT_OU="dummy"
    CERT_CITY="dummy"
    CERT_STATE="dummy"
    CERT_COUNTRY="DE"
    CERT_PASS="dummy"
    CERT_EMAIL="dummy@example.net"
    MANAGER_ENABLE_TFTP="y"
    ACTIVATE_SLP="n"

    check_remote_type
    wait_step

    echo "Shutting down remote spacewalk services..."
    ssh -i $KEYFILE root@$SATELLITE_IP "/usr/sbin/spacewalk-service stop"
    wait_step

    do_setup
    wait_step

    if [ "$DB_BACKEND" = "postgresql" ]; then
        dump_remote_db
        wait_step

        echo "Reconfigure postgresql for high performance..."
        postgres_fast
        import_db
        wait_step
        echo "Reconfigure postgresql for normal safe operation..."
        postgres_safe
    fi

    echo "Upgrade database schema..."
    upgrade_schema
    wait_step

# we skip below func and not copying files.
    # copy_remote_files
    wait_step

    ssh -i $KEYFILE root@$SATELLITE_IP "systemctl is-enabled osa-dispatcher > /dev/null 2>&1"
    if [ $? -eq 0 ]; then
        echo "Enable osa-dispatcher..."
        systemctl --quiet enable osa-dispatcher 2>&1
    else
        echo "Disable osa-dispatcher..."
        systemctl --quiet disable osa-dispatcher 2>&1
        systemctl --quiet disable jabberd 2>&1
    fi

    remove_ssh_key
    if [ -d /root/.ssh.new ]; then
        mv /root/.ssh /root/.ssh.orig
        mv /root/.ssh.new /root/.ssh
    fi

    mv /etc/rhn/rhn.conf /etc/rhn/rhn.conf.setup
    cp /etc/rhn/rhn.conf-$FROMVERSION /etc/rhn/rhn.conf
    chmod 640 /etc/rhn/rhn.conf
    # Detect the Apache group name (SUSE/RHEL differences)
    APACHE_GROUP=`cut -d: -f3 < <((getent group www)||(getent group apache))`
    chown root:${APACHE_GROUP} /etc/rhn/rhn.conf
}

activate_rhn_conf () {
    if [ -d /root/.ssh.new ]; then
        mv /root/.ssh /root/.ssh.orig
        mv /root/.ssh.new /root/.ssh
    fi

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
        . $MIGRATION_ENV 2> /dev/null
        . $SETUP_ENV
        SATELLITE_FQDN="$SATELLITE_HOST.$SATELLITE_DOMAIN"
        SATELLITE_IP="$SATELLITE_IP"
        check_btrfs_dirs
        create_ssh_key
        check_remote_type
        copy_remote_files
        remove_ssh_key
        activate_rhn_conf
       ;;
    -h)
        help
       ;;
    -l)
        shift
        LOGFILE="$1"
        ;;
    -w)
        WAIT_BETWEEN_STEPS=1
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
