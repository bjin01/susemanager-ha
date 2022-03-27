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
PROGRAM="/usr/lib/susemanager/bin/bomgr-setup"

MIGRATION_ENV="/root/migration_env.sh"
SETUP_ENV="/root/setup_env.sh"
MANAGER_COMPLETE="/root/.MANAGER_SETUP_COMPLETE"
MANAGER_COMPLETE_HOOK="/usr/lib/susemanager/hooks/suma_completehook.sh"
RSYNC_LOG="/var/log/rhn/migration-rsync.log"

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

  -m             full migration of an existing $PRODUCT_NAME
  -r             only sync remote files (useful for migration only)
  -f             version of $PRODUCT_NAME to migrate from.
                 Must be one of: 3.1 or 3.2
                 NOTE: Needs to be specified before '-r' or '-m'
  -s             fresh setup of the $PRODUCT_NAME installation
  -w             wait between steps (in case you do -r -m)
  -l LOGFILE     write a log to LOGFILE
  -h             this help screen


"
}

wait_step() {
    if [ $? -ne 0 ]; then
        echo "Something didn't work. Migration failed. Please check logs ($LOGFILE)"
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

setup_mail () {

# fix hostname for postfix
REALHOSTNAME=`hostname -f`
if [ -z "$REALHOSTNAME" ]; then
        for i in `ip -f inet -o addr show scope global | awk '{print $4}' | awk -F \/ '{print $1}'`; do
                for j in `dig +noall +answer +time=2 +tries=1 -x $i | awk '{print $5}' | sed 's/\.$//'`; do
                        if [ -n "$j" ]; then
                                REALHOSTNAME=$j
                                break 2
                        fi
                done
        done
fi
if [ -n "$REALHOSTNAME" ]; then
        echo "$REALHOSTNAME" > /etc/hostname
fi
# bsc#979664 - SUSE Manager requires a working mail system
systemctl --quiet enable postfix 2>&1
systemctl restart postfix
}

setup_hostname() {
    # The SUSE Manager server needs to have the same hostname as the�
    # old satellite server.�

    cp /etc/hosts /etc/hosts.backup.suse.manager

    # change the hostname to the satellite hostname
    hostname $SATELLITE_HOST

    # modify /etc/hosts to fake the own hostname
    #
    # add line�
    # <ip>  <fqdn> <shortname>
    #
    echo -e "\n$MANAGER_IP $SATELLITE_FQDN $SATELLITE_HOST" >> /etc/hosts

    # test if the output of "hostname -f" is equal to $SATELLITE_FQDN
    # test if "ping $SATELLITE_HOST" ping the own host
}

cleanup_hostname() {
    if [ -f /etc/hosts.backup.suse.manager ]; then
        mv /etc/hosts.backup.suse.manager /etc/hosts
    fi;
}

setup_db_postgres() {
    DATADIR="/var/lib/pgsql/data" 
    systemctl --quiet enable postgresql 2>&1
    if [[ "echo $(source /etc/os-release && echo ${ID_LIKE})" != *"suse"* ]]; then
        # Create the PostgreSQL data folder, should it not exist.
        if [ ! -f $DATADIR/PG_VERSION ]; then
            rm -Rf ${DATADIR}
            echo "Initializing PostgreSQL $VERSION at location ${DATADIR}"
            runuser -l postgres -c "/usr/bin/initdb --auth=ident $DATADIR" &> initlog || {
                echo "Initialisation failed. See $PWD/initlog ."
                exit 1
            }
        fi
    fi
    systemctl start postgresql
    su - postgres -c "createdb -E UTF8 $MANAGER_DB_NAME ; echo \"CREATE ROLE $MANAGER_USER PASSWORD '$MANAGER_PASS' SUPERUSER NOCREATEDB NOCREATEROLE INHERIT LOGIN;\" | psql"
    # su - postgres -c "createlang pltclu '$MANAGER_DB_NAME'"   SUMA3 drops upstream auditing
    # "createlang plpgsql $MANAGER_DB_NAME" not needed on SUSE. plpgsql is already enabled

    echo "local $MANAGER_DB_NAME $MANAGER_USER md5
host $MANAGER_DB_NAME $MANAGER_USER 127.0.0.1/8 md5
host $MANAGER_DB_NAME $MANAGER_USER ::1/128 md5
" > /tmp/pg_hba.conf
    cat /var/lib/pgsql/data/pg_hba.conf >> /tmp/pg_hba.conf
    mv /var/lib/pgsql/data/pg_hba.conf /var/lib/pgsql/data/pg_hba.conf.bak
    mv /tmp/pg_hba.conf /var/lib/pgsql/data/pg_hba.conf
    chmod 600 /var/lib/pgsql/data/pg_hba.conf
    chown postgres:postgres /var/lib/pgsql/data/pg_hba.conf
    systemctl restart postgresql
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
     if [ $MANAGER_FORCE_INSTALL == "1" ]; then
        echo "Performing forced re-installation!"
        /usr/sbin/spacewalk-service stop
        rm -f /etc/rhn/rhn.conf
        touch /etc/rhn/rhn.conf
        if [ $LOCAL_DB != "0" ]; then
            echo "Delete existing database..."
            su - postgres -c "dropdb $MANAGER_DB_NAME" 2> /dev/null
            su - postgres -c "dropuser $MANAGER_USER" 2> /dev/null
        fi
        echo "Delete existing salt minion keys"
        salt-key -D -y > /dev/null
    else
        echo "$PRODUCT_NAME is already set up. Exit." >&2
        exit 1
    fi
fi
}

setup_spacewalk() {
    CERT_COUNTRY=`echo -n $CERT_COUNTRY|tr '[:lower:]' '[:upper:]'`

    echo "admin-email = $MANAGER_ADMIN_EMAIL
ssl-set-org = $CERT_O
ssl-set-org-unit = $CERT_OU
ssl-set-city = $CERT_CITY
ssl-set-state = $CERT_STATE
ssl-set-country = $CERT_COUNTRY
ssl-set-cnames = $CERT_CNAMES
ssl-password = $CERT_PASS
ssl-set-email = $CERT_EMAIL
ssl-config-sslvhost = Y
ssl-ca-cert-expiration = 10
ssl-server-cert-expiration = 10
db-backend=$DB_BACKEND
db-user=$MANAGER_USER
db-password=$MANAGER_PASS
db-name=$MANAGER_DB_NAME
db-host=$MANAGER_DB_HOST
db-port=$MANAGER_DB_PORT
db-protocol=$MANAGER_DB_PROTOCOL
enable-tftp=$MANAGER_ENABLE_TFTP
" > /root/spacewalk-answers
    if [ -n "$SCC_USER" ]; then
        echo "scc-user = $SCC_USER
scc-pass = $SCC_PASS
" >> /root/spacewalk-answers
        PARAM_CC="--scc"
    elif [ -n "$ISS_PARENT" ]; then
        PARAM_CC="--disconnected"
    fi
    if [ -n "$CA_CERT" -a -n "$SERVER_CERT" -a -n "$SERVER_KEY" ]; then
        echo "ssl-use-existing-certs = Y
ssl-ca-cert = $CA_CERT
ssl-server-cert = $SERVER_CERT
ssl-server-key = $SERVER_KEY" >> /root/spacewalk-answers
    else
        echo "ssl-use-existing-certs = N" >> /root/spacewalk-answers
    fi

    PARAM_DB="--external-postgresql"

    if [ "$DO_MIGRATION" = "1" ]; then
        /usr/bin/spacewalk-setup --disconnected --skip-db-population --skip-services-restart --skip-ssl-cert-generation --answer-file=/root/spacewalk-answers $PARAM_DB
        SWRET=$?
    else
        /usr/bin/spacewalk-setup --non-interactive --clear-db $PARAM_CC --answer-file=/root/spacewalk-answers $PARAM_DB
        SWRET=$?
    fi
    if [ "x" = "x$MANAGER_MAIL_FROM" ]; then
        MY_DOMAIN=`hostname -d`
        MANAGER_MAIL_FROM="$PRODUCT_NAME ($REALHOSTNAME) <root@$MY_DOMAIN>"
    fi
    if ! grep "^web.default_mail_from" /etc/rhn/rhn.conf > /dev/null; then
        echo "web.default_mail_from = $MANAGER_MAIL_FROM" >> /etc/rhn/rhn.conf
    fi

    rm /root/spacewalk-answers
    if [ "$SWRET" != "0" ]; then
        echo "ERROR: spacewalk-setup failed" >&2
        exit 1
    fi
}

dump_remote_db() {
    echo "`date +"%H:%M:%S"`   Dumping remote database to $TMPDIR/$DBDUMPFILE on target system. Please wait..."
    ssh -i $KEYFILE root@$SATELLITE_IP "su -s /bin/bash - postgres -c \"pg_dump $MANAGER_DB_NAME | gzip\"" > $TMPDIR/$DBDUMPFILE
    if [ $? -eq 0 ]; then
        echo -n "`date +"%H:%M:%S"`   Database successfully dumped. Size is: "
        du -h $TMPDIR/$DBDUMPFILE | cut -f 1
    else
        echo "`date +"%H:%M:%S"`   FAILURE!"
        exit 1
    fi
}

import_db() {
    # Integrity check is no longer necessary since we ensure remote commands
    # can be executed silently; so no motd should corrupt the dump any more
    # echo "`date +"%H:%M:%S"`   Checking the integrity of the database dump archive."
    # gzip -t $TMPDIR/$DBDUMPFILE || { echo "`date +"%H:%M:%S"`   FAILURE!"; exit 1; }

    echo "`date +"%H:%M:%S"`   Importing database dump. Please wait..."
    su -s /bin/bash - postgres -c "zcat $TMPDIR/$DBDUMPFILE | psql $MANAGER_DB_NAME > /dev/null"
    if [ $? -eq 0 ]; then
        echo "`date +"%H:%M:%S"`   Database dump successfully imported."
        rm -f $TMPDIR/$DBDUMPFILE
    else
        echo "`date +"%H:%M:%S"`   FAILURE!"
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
               /srv/formula_metadata
               /srv/pillar
               /srv/salt
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
               /var/spacewalk"

    echo "Copy files from old $PRODUCT_NAME..."

    for DIR in $SUMAFILES; do
        DEST=`dirname "$DIR"`
        ssh -i $KEYFILE root@$SATELLITE_IP "test -d $DIR"
        if [ $? -eq 0 ]; then
            echo "`date +"%H:%M:%S"`   Copy $DIR ..."
            rsync -e "ssh -i $KEYFILE -l root" -avz --ignore-existing root@$SATELLITE_IP:$DIR $DEST >> $RSYNC_LOG
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
    chown -R tomcat:tomcat /var/lib/rhn/kickstarts
    chmod 600 /etc/pki/spacewalk/jabberd/server.pem
    chown jabber:jabber /etc/pki/spacewalk/jabberd/server.pem
    chown wwwrun:tftp /srv/tftpboot
    chmod 750 /srv/tftpboot
    chown -R wwwrun.www /var/spacewalk
    ln -sf /srv/www/htdocs/pub/RHN-ORG-TRUSTED-SSL-CERT /etc/pki/trust/anchors
    update-ca-certificates
    /usr/lib/susemanager/bin/migrate-cobbler.sh
}

create_ssh_key() {
    rm -f $KEYFILE
    rm -f $KEYFILE.pub
    cleanup_hostname
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

postgres_fast() {
    cp -a /var/lib/pgsql/data/postgresql.conf /var/lib/pgsql/data/postgresql.conf.migrate
    echo "fsync = off" >> /var/lib/pgsql/data/postgresql.conf
    echo "full_page_writes = off" >> /var/lib/pgsql/data/postgresql.conf
    echo "checkpoint_completion_target = 0.9" >> /var/lib/pgsql/data/postgresql.conf
    systemctl restart postgresql
}

postgres_safe() {
    if [ -f /var/lib/pgsql/data/postgresql.conf.migrate ]; then
        mv /var/lib/pgsql/data/postgresql.conf.migrate /var/lib/pgsql/data/postgresql.conf
        systemctl restart postgresql
    fi
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

    setup_hostname

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

    cleanup_hostname
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

do_setup() {
    if [ -f $SETUP_ENV ]; then
        . $SETUP_ENV
    else
        # ask for the needed values if the setup_env file does not exist
        echo -n "MANAGER_USER=";        read MANAGER_USER
        echo -n "MANAGER_PASS=";        read MANAGER_PASS
        echo -n "MANAGER_ADMIN_EMAIL="; read MANAGER_ADMIN_EMAIL
        echo -n "CERT_CNAMES="        ; read CERT_CNAMES
        echo -n "CERT_O="             ; read CERT_O
        echo -n "CERT_OU="            ; read CERT_OU
        echo -n "CERT_CITY="          ; read CERT_CITY
        echo -n "CERT_STATE="         ; read CERT_STATE
        echo -n "CERT_COUNTRY="       ; read CERT_COUNTRY
        echo -n "CERT_EMAIL="         ; read CERT_EMAIL
        echo -n "CERT_PASS="          ; read CERT_PASS
        echo -n "LOCAL_DB="           ; read LOCAL_DB
        echo -n "DB_BACKEND="         ; read DB_BACKEND
        echo -n "MANAGER_DB_NAME="    ; read MANAGER_DB_NAME
        echo -n "MANAGER_DB_HOST="    ; read MANAGER_DB_HOST
        echo -n "MANAGER_DB_PORT="    ; read MANAGER_DB_PORT
        echo -n "MANAGER_DB_PROTOCOL="; read MANAGER_DB_PROTOCOL
        echo -n "MANAGER_ENABLE_TFTP="; read MANAGER_ENABLE_TFTP
        echo -n "SCC_USER="           ; read SCC_USER
        echo -n "SCC_PASS="           ; read SCC_PASS
        echo -n "ISS_PARENT="         ; read ISS_PARENT
        echo -n "ACTIVATE_SLP="       ; read ACTIVATE_SLP
    fi;
    if [ -z "$SYS_DB_PASS" ]; then
        SYS_DB_PASS=`dd if=/dev/urandom bs=16 count=4 2> /dev/null | md5sum | cut -b 1-8`
    fi
    if [ -z "$MANAGER_DB_NAME" ]; then
        MANAGER_DB_NAME="susemanager"
    fi
    if [ -z "$DB_BACKEND" ]; then
        DB_BACKEND="postgresql"
    fi
    check_re_install
    echo "Do not delete this file unless you know what you are doing!" > $MANAGER_COMPLETE
    setup_swap
    setup_mail
    if [ "$DB_BACKEND" = "postgresql" ]; then
        setup_db_postgres
    fi

    setup_spacewalk

    if [ -n "$ISS_PARENT" ]; then
        local certname=`echo "MASTER-$ISS_PARENT-TRUSTED-SSL-CERT" | sed 's/\./_/g'`
        curl -s -S -o /usr/share/rhn/$certname "http://$ISS_PARENT/pub/RHN-ORG-TRUSTED-SSL-CERT"
        if [ -e /usr/share/rhn/RHN-ORG-TRUSTED-SSL-CERT ] && \
           cmp -s /usr/share/rhn/RHN-ORG-TRUSTED-SSL-CERT /usr/share/rhn/$certname ; then
            # equal - use it
            rm -f /usr/share/rhn/$certname
            certname=RHN-ORG-TRUSTED-SSL-CERT
        else
            ln -s /usr/share/rhn/$certname /etc/pki/trust/anchors
            update-ca-certificates
        fi
        echo "
        INSERT INTO rhnISSMaster (id, label, is_current_master, ca_cert)
        VALUES (sequence_nextval('rhn_issmaster_seq'), '$ISS_PARENT', 'Y', '/usr/share/rhn/$certname');
        " | spacewalk-sql -
    fi
}

####################################################
# Start
####################################################

PROGRAM="$0"

# clean up fake hostname in /etc/hosts in case of previous error
cleanup_hostname

while [ -n "$1" ]
do
    p="$1"

    case "$p" in
    -m)
        DO_MIGRATION=1
        . $MIGRATION_ENV 2> /dev/null
        . $SETUP_ENV
        SATELLITE_FQDN="$SATELLITE_HOST.$SATELLITE_DOMAIN"
        echo "Migrating from $SATELLITE_FQDN"
        SATELLITE_IP=`getent hosts $SATELLITE_FQDN | cut -f 1 -d " "`
        if [ -z "$SATELLITE_IP" ]; then
            echo "Something went wrong. IP address of remote host can not be found."
            exit 1
        fi
        if [ "$LOGFILE" = "0" ]; then
            LOGFILE=/var/log/rhn/migration.log
        fi
       ;;
    -f)
        shift
        FROMVERSION="$1"
       ;;
    -s)
        DO_SETUP=1
       ;;
    -r)
        . $MIGRATION_ENV 2> /dev/null
        . $SETUP_ENV
        SATELLITE_FQDN="$SATELLITE_HOST.$SATELLITE_DOMAIN"
        SATELLITE_IP=`getent hosts $SATELLITE_FQDN | cut -f 1 -d " "`
        check_btrfs_dirs
        create_ssh_key
        check_remote_type
        copy_remote_files
        remove_ssh_key
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

if [ "$DO_SETUP" = "1" -o "$DO_MIGRATION" = "1" ]; then
    wait_step
    check_btrfs_dirs
    open_firewall_ports
fi

if [ "$DO_SETUP" = "1" ]; then
    do_setup

    if [ -f $MANAGER_COMPLETE_HOOK ]; then
        $MANAGER_COMPLETE_HOOK
    else
        echo "You can access $PRODUCT_NAME via https://`hostname -f`" > /etc/motd
    fi
fi
wait_step

if [ "$DO_MIGRATION" = "1" ]; then
    if [ "$DB_BACKEND" != "postgresql" ]; then
        echo "Unknown DB Backend!" >&2
        exit 1
    fi
    do_migration
fi

if [ "$DO_SETUP" = "1" -o "$DO_MIGRATION" = "1" ]; then
    if [ "$LOCAL_DB" != "0" ]; then
        /usr/bin/smdba system-check autotuning
        if [ "$DO_SETUP" = "1" ]; then
            /usr/sbin/spacewalk-service stop

            # explicitly enable OSA dispatcher as it's no longer part of spacewalk.target
            echo "Enable osa-dispatcher..."
            systemctl --quiet enable jabberd 2>&1
            systemctl --quiet enable osa-dispatcher 2>&1

            systemctl restart postgresql
            /usr/sbin/spacewalk-service start
            systemctl --quiet enable spacewalk-diskcheck.timer 2>&1
            systemctl start spacewalk-diskcheck.timer
        fi
    fi
fi

if [ "$DO_SETUP" = "1" -o "$DO_MIGRATION" = "1" ]; then
    if [ "$ACTIVATE_SLP" = "y" ]; then
        if [ -x /usr/bin/firewall-cmd ]; then
            firewall-cmd --state 2> /dev/null
            if [ $? -eq 0 ]; then
              firewall-cmd --permanent --zone=public --add-service=slp
              firewall-cmd --reload
            else
              firewall-offline-cmd --zone=public --add-service=slp
            fi
        else
            echo "firewalld not installed" >&2
        fi
        systemctl --quiet enable slpd 2>&1
        systemctl start slpd
    fi
fi

if [ "$DO_MIGRATION" = "1" ]; then
    echo
    echo
    echo "============================================================================"
    echo "Migration complete."
    echo "Please shut down the old $PRODUCT_NAME server now."
    echo "Reboot the new server and make sure it uses the same IP address and hostname"
    echo "as the old $PRODUCT_NAME server!"
    echo
    echo "IMPORTANT: Make sure, if applicable, that your external storage is mounted"
    echo "in the new server as well as the ISO images needed for distributions before"
    echo "rebooting the new server!"
    echo "============================================================================"
fi

# vim: set expandtab:
