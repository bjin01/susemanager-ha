# Postgresql High Availability Option for SUSE Manager 4.2

## Primary Server configuration:
On primary suse manager create a user for replication:
borep is my chosen user name.

```
sudo -u postgres psql
CREATE ROLE borep WITH REPLICATION PASSWORD 'testpassword' LOGIN;
```

In __postgresql.conf__ make sure you put below entries into it, after edit restart postgresql.service on the postgresql primary server.
Make sure the ip address used in the restore_command is the ip of the primary server's ip because when the restore happens it will use scp to copy the archive files over to the standby server.
```
listen_addresses = '*'
wal_level = replica
hot_standby = on
max_wal_senders = 10

archive_command = 'test ! -f /var/lib/pgsql/data/suma_archive/%f && cp %p /var/lib/pgsql/data/suma_archive/%f'
restore_command = 'scp 172.28.0.5:/var/lib/pgsql/data/suma_archive/%f %p'
```

Or, if you switch the replication direction make sure you changed the ip of the new primary server in the postgresql.conf:
```
restore_command = 'rsync -avz postgres@172.28.0.10:/var/lib/pgsql/data/suma_archive/%f %p'
```

### Client authentication for replication
https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION-SLOTS

In pg_hba.conf you want to make sure that the postgresql on the SUSE Manager host allow the replication user from peer standby suse manager server to connect via port 5432.
```
host    replication     borep   172.28.0.10/24   trust
host    all     all     172.28.0.1/24 md5
```

### Now we start or restart postgresql on the primary SUSE Manager server.
```systemctl restart postgresql.service```

## Secondary Server configuration:
After the primary site is configured for the replication we are ready to start configure standby server:
Login on the standby server as postgres user:
su - postgres

Create ssh key pair for postgres user and copy the public key to the authorized_keys file of postgres home directory on primary server.
```ssh-keygen``` without passphrase please.

As the postgres user does not have a password set and or even passworth authentication is not allowed in your sshd you will not be able to use ssh-copy-id to add the e.g. id_rsa.pub content to the authorized_keys file.
So simply copy paste the content to the authorized_keys file.

The next step is to use postgresql command pg_basebackup to make a so called base backup. This means we copy the /var/lib/pgsql/data from primary to the secondary server.
As you can see from the command below we create a replication slot "boslot1" that will be used for replication.

Basebackup command, must be run as postgres user:
pg_basebackup -h 172.28.0.5 -D /var/lib/pgsql/data -U borep -v -Fp --checkpoint=fast -R --slot=boslot1 -C -Xs

__Verify: in /var/lib/pgsql/data/ a file named standby.signal has been created by the pg_basebackup. This file indicates that this postgresql is in standby mode.__
After pg_basebackup and hopefully it went successful we have to edit the auto-created file /var/lib/pgsql/data/postgresql.auto.conf on secondary server.
Make sure the slot name is correct. 
Make sure the primary_conninfo is correct.

suma1:/var/lib/pgsql/data # vim postgresql.auto.conf
```
primary_conninfo = 'user=borep passfile=''/var/lib/pgsql/.pgpass'' channel_binding=prefer host=172.28.0.5 port=5432 sslmode=prefer sslcompression=0 sslsni=1 ssl_min_protocol_version=TLSv1.2 gssencmode=prefer krbsrvname=postgres target_session_attrs=any'
primary_slot_name = 'boslot1'

```
The final step is to start postgresql on standby server.
```systemctl start postgresql.service```

Verify that the walreceiver is running. If you see below output then it seems postgres walreceiver is working.
```
ps aux | grep walreceiver
postgres 30442  0.1  0.0 4166668 11120 ?       Ss   05:12   0:36 postgres: walreceiver streaming 5A/C7D66A38
```

## Failover - manually:
On standby server, postgresql is running in standby mode, primary server is broken and down.
run below command, must be run as postgres user:

```pg_ctl promote```

then start suse manager as root user:
```spacewalk-service start```


## Monitor and verifying if replication is working:
```
sudo -u postgres psql
SELECT client_addr, state FROM pg_stat_replication;
```

source: https://www.digitalocean.com/community/tutorials/how-to-set-up-physical-streaming-replication-with-postgresql-12-on-ubuntu-20-04
