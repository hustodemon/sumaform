#!/bin/bash

if [ ! $UID -eq 0 ]; then
    echo "You need to be superuser (root) to run this script!"
    exit 1
fi

TMPDIR="/var/spacewalk/tmp"
DO_MIGRATION=0
DO_SETUP=0
LOGFILE=0
WAIT_BETWEEN_STEPS=0
MANAGER_FORCE_INSTALL=0

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

SATELLITE_IS_RH=1
KEYFILE="/root/migration-key"
DBDUMPFILE="susemanager.dmp.gz"

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
helper script to do migration or setup of SUSE Manager

  -m             full migration of an existing SUSE Manager
  -s             fresh setup of the SUSE Manager installation
  -r             only sync remote files (useful for migration only)
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
        dd if=/dev/zero of=/SWAPFILE bs=1M count=2000
        sync
        mkswap -f /SWAPFILE
        echo "/SWAPFILE swap swap defaults 0 0" >> /etc/fstab
        swapon -a
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
systemctl try-restart postfix
}

setup_hostname() {
    # The SUSE Manager server needs to have the same hostname as the·
    # old satellite server.·

    cp /etc/hosts /etc/hosts.backup.suse.manager

    # change the hostname to the satellite hostname
    hostname $SATELLITE_HOST

    # modify /etc/hosts to fake the own hostname
    #
    # add line·
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
    if ! chkconfig -c postgresql ; then
        insserv postgresql
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

check_var_spacewalk() {
SPACEWALK_DIR="/var/spacewalk"

if [ ! -d $SPACEWALK_DIR ]; then
    FSTYPE=`df -T \`dirname $SPACEWALK_DIR\` | tail -1 | awk '{print $2}'`
    echo -n "Filesystem type for $SPACEWALK_DIR is $FSTYPE - "
    if [ $FSTYPE == "btrfs" ]; then
        echo "creating nCoW subvolume."
        if [ -x /usr/sbin/mksubvolume ]; then
            /usr/sbin/mksubvolume --nocow $SPACEWALK_DIR
            chown wwwrun $SPACEWALK_DIR
        else
            echo "Cannot execute /usr/sbin/mksubvolume. Package snapper is outdated."
        fi
    else
        echo "ok."
    fi
else
    echo "$SPACEWALK_DIR already exists. Leaving it untouched."
fi
}

open_firewall_ports() {
echo "Open needed firewall ports..."
sysconf_addword /etc/sysconfig/SuSEfirewall2 FW_SERVICES_EXT_TCP "http" > /dev/null 2>&1
sysconf_addword /etc/sysconfig/SuSEfirewall2 FW_SERVICES_EXT_TCP "https" > /dev/null 2>&1
sysconf_addword /etc/sysconfig/SuSEfirewall2 FW_SERVICES_EXT_TCP "xmpp-client" > /dev/null 2>&1
sysconf_addword /etc/sysconfig/SuSEfirewall2 FW_SERVICES_EXT_TCP "xmpp-server" > /dev/null 2>&1
sysconf_addword /etc/sysconfig/SuSEfirewall2 FW_SERVICES_EXT_TCP "tftp" > /dev/null 2>&1
sysconf_addword /etc/sysconfig/SuSEfirewall2 FW_SERVICES_EXT_UDP "tftp" > /dev/null 2>&1

# ports needed for Salt
sysconf_addword /etc/sysconfig/SuSEfirewall2 FW_SERVICES_EXT_TCP "4505" > /dev/null 2>&1
sysconf_addword /etc/sysconfig/SuSEfirewall2 FW_SERVICES_EXT_TCP "4506" > /dev/null 2>&1

systemctl condrestart SuSEfirewall2
}

check_re_install() {
if [ -f $MANAGER_COMPLETE ]; then
     if [ $MANAGER_FORCE_INSTALL == "1" ]; then
        echo "Performing forced re-installation!"
        /usr/sbin/spacewalk-service stop
        rm -f /etc/rhn/rhn.conf
        if [ $LOCAL_DB != "0" ]; then
            echo "Delete existing database..."
            su - postgres -c "dropdb $MANAGER_DB_NAME" 2> /dev/null
            su - postgres -c "dropuser $MANAGER_USER" 2> /dev/null
        fi
        echo "Delete existing salt minion keys"
        salt-key -D > /dev/null
    else
        echo "SUSE Manager is already set up. Exit." >&2
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
        /usr/bin/spacewalk-setup --disconnected --skip-db-population --skip-ssl-cert-generation --answer-file=/root/spacewalk-answers $PARAM_DB
        SWRET=$?
    else
        /usr/bin/spacewalk-setup --non-interactive --clear-db $PARAM_CC --answer-file=/root/spacewalk-answers $PARAM_DB
        SWRET=$?
    fi
    if [ "x" = "x$MANAGER_MAIL_FROM" ]; then
        MY_DOMAIN=`hostname -d`
        MANAGER_MAIL_FROM="SUSE Manager ($REALHOSTNAME) <root@$MY_DOMAIN>"
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
    scp -i $KEYFILE /usr/lib/susemanager/bin/tclfilter root@$SATELLITE_IP:/tmp
    ssh -i $KEYFILE root@$SATELLITE_IP "su -s /bin/bash - postgres -c \"pg_dump $MANAGER_DB_NAME | /tmp/tclfilter | gzip\"" > $TMPDIR/$DBDUMPFILE
    if [ $? -eq 0 ]; then
        echo -n "`date +"%H:%M:%S"`   Database successfully dumped. Size is: "
        du -h $TMPDIR/$DBDUMPFILE | cut -f 1
    else
        echo "`date +"%H:%M:%S"`   FAILURE!"
        exit 1
    fi
}

import_db() {
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

copy_remote_files_common() {
    # copy only new files (new kickstart profiles, snippets, trigger, etc.)
    echo "`date +"%H:%M:%S"`   Copy /var/lib/cobbler ..."
    rsync -e "ssh -i $KEYFILE -l root" -avz --ignore-existing root@$SATELLITE_IP:/var/lib/cobbler/ /var/lib/cobbler/ >> $RSYNC_LOG
    echo "`date +"%H:%M:%S"`   Copy /var/lib/rhn/kickstarts ..."
    rsync -e "ssh -i $KEYFILE -l root" -avz root@$SATELLITE_IP:/var/lib/rhn/kickstarts /var/lib/rhn/ >> $RSYNC_LOG
    echo "`date +"%H:%M:%S"`   Copy /srv/tftpboot ..."
    rsync -e "ssh -i $KEYFILE -l root" -avz root@$SATELLITE_IP:/srv/tftpboot /srv >> $RSYNC_LOG
    echo "`date +"%H:%M:%S"`   Copy /root/ssl-build ..."
    rsync -e "ssh -i $KEYFILE -l root" -avz root@$SATELLITE_IP:/root/ssl-build /root/ >> $RSYNC_LOG
    echo "`date +"%H:%M:%S"`   Copy /var/log/rhn ..."
    rsync -e "ssh -i $KEYFILE -l root" -avz root@$SATELLITE_IP:/var/log/rhn /var/log >> $RSYNC_LOG
    echo "`date +"%H:%M:%S"`   Copy /var/cache/rhn ..."
    rsync -e "ssh -i $KEYFILE -l root" -avz root@$SATELLITE_IP:/var/cache/rhn/ /var/cache/rhn >> $RSYNC_LOG

    scp -i $KEYFILE root@$SATELLITE_IP:/etc/pki/spacewalk/jabberd/server.pem /etc/pki/spacewalk/jabberd/server.pem
    scp -i $KEYFILE root@$SATELLITE_IP:/etc/rhn/rhn.conf /etc/rhn/rhn.conf-SUMA21
    chown -R tomcat:tomcat /var/lib/rhn/kickstarts
    chmod 600 /etc/pki/spacewalk/jabberd/server.pem
    chown jabber:jabber /etc/pki/spacewalk/jabberd/server.pem
    chown tftp:tftp /srv/tftpboot
    chmod 750 /srv/tftpboot
}

copy_remote_files_redhat() {
    echo "Copy files from old satellite..."
    # maybe add -H for hardlinks?
    rsync -e "ssh -i $KEYFILE -l root" -av root@$SATELLITE_IP:/var/satellite/ /var/spacewalk/ >> $RSYNC_LOG
    chown -R wwwrun.www /var/spacewalk
    rsync -e "ssh -i $KEYFILE -l root" -av --ignore-existing root@$SATELLITE_IP:/var/www/html/pub/ /srv/www/htdocs/pub/ >> $RSYNC_LOG

    scp -i $KEYFILE root@$SATELLITE_IP:/etc/pki/tls/certs/spacewalk.crt /etc/apache2/ssl.crt/spacewalk.crt
    scp -i $KEYFILE root@$SATELLITE_IP:/etc/pki/tls/private/spacewalk.key /etc/apache2/ssl.key/spacewalk.key
}

copy_remote_files_suse() {
    echo "Copy files from old SUSE Manager..."
    # maybe add -H for hardlinks?
    echo "`date +"%H:%M:%S"`   Copy /var/spacewalk ..."
    rsync -e "ssh -i $KEYFILE -l root" -av root@$SATELLITE_IP:/var/spacewalk/ /var/spacewalk/ >> $RSYNC_LOG
    echo "`date +"%H:%M:%S"`   Copy /srv/www/htdocs/pub ..."
    rsync -e "ssh -i $KEYFILE -l root" -av --ignore-existing root@$SATELLITE_IP:/srv/www/htdocs/pub/ /srv/www/htdocs/pub/ >> $RSYNC_LOG
    echo "`date +"%H:%M:%S"`   Copy /root/.ssh ..."
    rsync -e "ssh -i $KEYFILE -l root" -avz root@$SATELLITE_IP:/root/.ssh/ /root/.ssh.new >> $RSYNC_LOG

    scp -i $KEYFILE root@$SATELLITE_IP:/etc/apache2/ssl.crt/spacewalk.crt /etc/apache2/ssl.crt/spacewalk.crt
    scp -i $KEYFILE root@$SATELLITE_IP:/etc/apache2/ssl.key/spacewalk.key /etc/apache2/ssl.key/spacewalk.key

    chown -R wwwrun.www /var/spacewalk
    ln -sf /srv/www/htdocs/pub/RHN-ORG-TRUSTED-SSL-CERT /etc/pki/trust/anchors
    update-ca-certificates
}

create_ssh_key() {
    rm -f $KEYFILE
    rm -f $KEYFILE.pub
    cleanup_hostname
    echo "Please enter the root password of the remote machine."
    ssh-keygen -q -N "" -C "spacewalk-migration-key" -f $KEYFILE
    ssh-copy-id -i $KEYFILE root@$SATELLITE_IP > /dev/null 2>&1
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
    ssh -i $KEYFILE root@$SATELLITE_IP "test -e /etc/apache2/ssl.crt/spacewalk.crt"
    if [ $? -eq 0 ]; then
        echo "Remote machine is SUSE Manager"
        SATELLITE_IS_RH=0
    else
        echo "Remote machine appears not to be a SUSE Manager. Exit."
        exit 1
    fi

    ssh -i $KEYFILE root@$SATELLITE_IP "test -e /var/lib/spacewalk/scc/migrated"
    if [ $? -eq 0 ]; then
        echo "Remote system is already migrated to SCC. Good."
    else
        echo "Remote system has not yet been migrated to SCC! Exit."
        exit 1
    fi
}

copy_remote_files() {
    if [ $SATELLITE_IS_RH = "1" ];then
        copy_remote_files_redhat
        mv /var/spacewalk/redhat /var/spacewalk/packages
    else
        copy_remote_files_suse
    fi
    copy_remote_files_common
}

postgres_fast() {
    cp -a /var/lib/pgsql/data/postgresql.conf /var/lib/pgsql/data/postgresql.conf.migrate
    echo "fsync = off" >> /var/lib/pgsql/data/postgresql.conf
    echo "checkpoint_segments = 256" >> /var/lib/pgsql/data/postgresql.conf
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
    echo "Ensuring postgresql has read permissions on $TMPDIR for database dump..."
    chmod go+rx $TMPDIR

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
        echo -n "MANAGER_USER";      read MANAGER_USER
        echo -n "MANAGER_PASS";      read MANAGER_PASS
    fi;
    setup_hostname

    # those values will be overwritten by the copied certificate
    CERT_O="dummy"
    CERT_OU="dummy"
    CERT_CITY="dummy"
    CERT_STATE="dummy"
    CERT_COUNTRY="DE"
    CERT_PASS="dummy"
    CERT_EMAIL="dummy@example.net"
    MANAGER_ENABLE_TFTP="n"
    ACTIVATE_SLP="n"

    check_remote_type
    wait_step

    echo "Shutting down remote spacewalk services..."
    ssh -i $KEYFILE root@$SATELLITE_IP "/usr/sbin/spacewalk-service stop"
    wait_step

    do_setup
    wait_step

    dump_remote_db
    wait_step

    echo "Reconfigure postgresql for high performance..."
    postgres_fast
    import_db
    wait_step
    echo "Reconfigure postgresql for normal safe operation..."
    postgres_safe

    upgrade_schema
    wait_step

    copy_remote_files
    wait_step

    cleanup_hostname
    remove_ssh_key
    if [ -d /root/.ssh.new ]; then
        mv /root/.ssh /root/.ssh.orig
        mv /root/.ssh.new /root/.ssh
    fi

    sed -i -e "s/^web\.ssl_available.*$/web.ssl_available = 1/" /etc/rhn/rhn.conf
}

do_setup() {
    if [ -f $SETUP_ENV ]; then
        . $SETUP_ENV
    else
        # ask for the needed values if the setup_env file does not exist
        echo -n "MANAGER_USER=";        read MANAGER_USER
        echo -n "MANAGER_PASS=";        read MANAGER_PASS
        echo -n "MANAGER_ADMIN_EMAIL="; read MANAGER_ADMIN_EMAIL
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
    DB_BACKEND="postgresql"
    check_re_install
    echo "Do not delete this file unless you know what you are doing!" > $MANAGER_COMPLETE
    setup_swap
    setup_mail
    if [ "$LOCAL_DB" != "0" ]; then
      setup_db_postgres
    fi

    # should be done by cobbler with "--sync" but we had a case where those
    # files were missing (bnc#668908)
    cp /usr/share/syslinux/menu.c32 /srv/tftpboot/
    cp /usr/share/syslinux/pxelinux.0 /srv/tftpboot/

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

for p in $@; do
    if [ "$LOGFILE" = "1" ]; then
        LOGFILE=$p
        continue
    fi

    case "$p" in
    -m)
        DO_MIGRATION=1
        . $MIGRATION_ENV 2> /dev/null
        . $SETUP_ENV
        SATELLITE_FQDN="$SATELLITE_HOST.$SATELLITE_DOMAIN"
        SATELLITE_IP=`getent hosts $SATELLITE_FQDN | cut -f 1 -d " "`
        if [ -z "$SATELLITE_IP" ]; then
            echo "Something went wrong. IP address of remote host can not be found."
            exit 1
        fi
        if [ "$LOGFILE" = "0" ]; then
            LOGFILE=/var/log/rhn/migration.log
        fi
       ;;
    -s)
        DO_SETUP=1
       ;;
    -r)
        . $MIGRATION_ENV 2> /dev/null
        . $SETUP_ENV
        SATELLITE_FQDN="$SATELLITE_HOST.$SATELLITE_DOMAIN"
        SATELLITE_IP=`getent hosts $SATELLITE_FQDN | cut -f 1 -d " "`
        check_var_spacewalk
        create_ssh_key
        check_remote_type
        copy_remote_files
        remove_ssh_key
       ;;
    -h)
        help
       ;;
    -l)
        LOGFILE="1"
        ;;
    -w)
        WAIT_BETWEEN_STEPS=1
        ;;
    *)
       echo "That option is not recognized"
       ;;
    esac
done

if [ "$LOGFILE" != "0" ]; then
    #set -x
    exec >> >(tee $LOGFILE | sed 's/^/  /' ) 2>&1
fi

if [ "$DO_SETUP" = "1" -o "$DO_MIGRATION" = "1" ]; then
    wait_step
    check_var_spacewalk
    open_firewall_ports
fi

if [ "$DO_SETUP" = "1" ]; then
    do_setup

    if [ -f $MANAGER_COMPLETE_HOOK ]; then
        $MANAGER_COMPLETE_HOOK
    else
        echo "You can access SUSE Manager via https://`hostname -f`" > /etc/motd
    fi
fi
wait_step

if [ "$DO_MIGRATION" = "1" ]; then
    if [ -z "$DB_BACKEND" -o "$DB_BACKEND" != "postgresql" ]; then
        echo "Migration only supported with postgresql DB Backend" >&2
        exit 1
    fi
    do_migration
fi

if [ "$DO_SETUP" = "1" -o "$DO_MIGRATION" = "1" ]; then
    if [ "$LOCAL_DB" != "0" ]; then
        /usr/bin/smdba system-check autotuning
        if [ "$DO_SETUP" = "1" ]; then
            /usr/sbin/spacewalk-service stop
            systemctl restart postgresql
            /usr/sbin/spacewalk-service start
        fi
    fi
fi

if [ "$DO_SETUP" = "1" -o "$DO_MIGRATION" = "1" ]; then
    if [ "$ACTIVATE_SLP" = "y" ]; then
	sysconf_addword /etc/sysconfig/SuSEfirewall2 FW_SERVICES_EXT_TCP "427" > /dev/null 2>&1
	sysconf_addword /etc/sysconfig/SuSEfirewall2 FW_SERVICES_EXT_UDP "427" > /dev/null 2>&1
	systemctl enable -q slpd
	systemctl start slpd
    fi
fi

if [ "$DO_MIGRATION" = "1" ]; then
    echo
    echo
    echo "============================================================================"
    echo "Migration complete."
    echo "Please shut down the old SUSE Manager server now."
    echo "Reboot the new server and make sure it uses the same IP address and hostname"
    echo "as the old SUSE Manager server!"
    echo "============================================================================"
    echo
fi

# vim: set expandtab:
