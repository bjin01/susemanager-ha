# How to re-configure the promted server back as standby server

Let's assume you have a primary and a standby server. The primary server has failed and you have promoted the standby server to be the new primary server. After the primary server is repaired and you want to re-configure it as a standby server, you can follow the steps below.

Another situation you need to make standby server as primary server is when you want to perform a SUSE Manager minion or major version upgrade after you upgraded the primary server. In this case you have to promote the standby server to be a primary server, perform ```zypper up```. After the upgrade is done you can re-configure the primary server as standby server.

## Promote the standby server to be a primary server:
```
su - postgres
rm /var/lib/pgsql/data/standby.signal
pg_ctl promote
```

then start suse manager as root user:
```spacewalk-service start```

## Re-configure the promoted server back as standby server
## __Primary Server configuration:__
On primary suse manager create a user for replication if it does not exist yet.:
### Create replication user:
__borep__ is my chosen user name.

```
sudo -u postgres psql
CREATE ROLE borep WITH REPLICATION PASSWORD 'testpassword' LOGIN;
```

### postgresql.conf
In __postgresql.conf__ make sure you put below entries into it, afterwards restart postgresql.service on the postgresql primary server.

```
listen_addresses = '*'
wal_level = replica
hot_standby = on
max_wal_senders = 10
```

### Client authentication for replication
https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION-SLOTS

In pg_hba.conf on primary you have to make sure that the postgresql on the primary SUSE Manager host allows the replication user from standby server to connect via port 5432.
```
host    replication     borep   172.28.0.10/24   trust
```

### Now we start or restart postgresql on the primary SUSE Manager server.
```systemctl restart postgresql.service```

Now let's configure the standby server.
## __Secondary Server configuration:__
After the primary site is configured for the replication we are ready to start configure standby server:
### Use ssh-keys
Login on the standby server as postgres user:
```
su - postgres
```

Create ssh key pair for postgres user and copy the public key to the authorized_keys file of postgres home directory on primary server.
```ssh-keygen``` without passphrase please.

As the postgres user does not have a password set and or even password authentication is not allowed in your sshd you will not be able to use ssh-copy-id to add the e.g. id_rsa.pub content to the authorized_keys file.
So simply copy paste the content of /var/lib/pgsql/.ssh/id_rsa.pub to the /var/lib/pgsql/.ssh/authorized_keys file on primary server.

### configure /var/lib/pgsql/.pgpass for passwordless login while using pgsql and pg_basebackup commands.
It is necessary to greate a .pgpass file for the replication user. You could create the file similar like below:
/var/lib/pgsql/.pgpass

```
*:*:*:borep:testpassword
```
Make sure to use __chmod 600__ for this .pgpass file.
__All files and directories must have owner postgres and group postgres.__

### __pg_basebackup__
The next step is to use postgresql command ```pg_basebackup``` to make a so-called base-backup from the primary to standby. This means we copy the /var/lib/pgsql/data from primary to the secondary server by using command pg_basebackup.

__Before executing pg_basebackup you have to delete the /var/lib/pgsql/data directory.__
You could do it with:
```rm -rf /var/lib/pgsql/data```

If you have a subdirectory in /var/lib/pgsql/data for instance a NFS mount point then unmount the NFS before hand.

```umount /var/lib/pgsql/data/sumaarchive```

```find /var/lib/pgsql/data -mindepth 1 -delete```

If the /var/lib/pgsql/data is not empty you will get error message from pg_basebackup.

Use the command below to create a replication slot e.g. "boslot1" that will be used for replication. Of course you could give other name for the slot.

__Get existing replication slots on primary postgresql:__
```
SELECT * FROM pg_replication_slots;
```

__Delete existing replication slot on primary postgresql if it exists:__
```
SELECT pg_drop_replication_slot('myslot1');
```


__Basebackup command, must be run as postgres user:__
```
su - postgres
pg_basebackup -h 172.28.0.5 -D /var/lib/pgsql/data -U borep -v -Fp --checkpoint=fast -R --slot=boslot1 -C -Xs
```
The base backup command can run for a while. It depends on the size of the database and the network speed.

__Verify: after pg_basebackup in /var/lib/pgsql/data/ a file named standby.signal has been created by the pg_basebackup. This file indicates that this postgresql is in standby mode.__
After pg_basebackup and hopefully the task went successful we have to double check the auto-created file /var/lib/pgsql/data/postgresql.auto.conf on secondary server.
* Make sure the slot name is correct. 
* Make sure the primary_conninfo is correct.

```vim /var/lib/pgsql/data/postgresql.auto.conf```
```
primary_conninfo = 'user=borep passfile=''/var/lib/pgsql/.pgpass'' channel_binding=prefer host=172.28.0.5 port=5432 sslmode=prefer sslcompression=0 sslsni=1 ssl_min_protocol_version=TLSv1.2 gssencmode=prefer krbsrvname=postgres target_session_attrs=any'
primary_slot_name = 'boslot1'

```
The final step is to start postgresql on standby server.
```systemctl start postgresql.service```

__Verify that the walreceiver is running. If you see below output then it seems postgres walreceiver is working.__
```
ps aux | grep walreceiver
postgres 30442  0.1  0.0 4166668 11120 ?       Ss   05:12   0:36 postgres: walreceiver streaming 5A/C7D66A38
```