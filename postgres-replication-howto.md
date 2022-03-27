# Postgresql High Availability Option for SUSE Manager 4.2

On primary suse manager create a user for replication:
```
sudo -u postgres psql
CREATE ROLE borep WITH REPLICATION PASSWORD 'testpassword' LOGIN;
```

In __postgres.conf__, after edit restart postgres on primary site.
```
listen_addresses = '*'
wal_level = replica
hot_standby = on
max_wal_senders = 10

archive_command = 'test ! -f /var/lib/pgsql/data/suma_archive/%f && cp %p /var/lib/pgsql/data/suma_archive/%f'
restore_command = 'scp 172.28.0.5:/var/lib/pgsql/data/suma_archive/%f %p'
```

Or, in other direction:
```
restore_command = 'rsync -avz postgres@172.28.0.10:/var/lib/pgsql/data/suma_archive/%f %p'
```

In pg_hba.conf, allow peer suse manager host to connect via port 5432.
```
host    replication     borep   172.28.0.10/24   trust
host    all     all     172.28.0.1/24 md5
```

Basebackup command, must be run as postgres user:
pg_basebackup -h 172.28.0.5 -D /var/lib/pgsql/data -U borep -v -Fp --checkpoint=fast -R --slot=boslot1 -C -Xs

Edit postgresql.auto.conf
Make sure the slot name is correct. 
Make sure the restore_command is correct.
Make sure the primary_conninfo is correct.

suma1:/var/lib/pgsql/data # cat postgresql.auto.conf
```
primary_conninfo = 'user=borep passfile=''/var/lib/pgsql/.pgpass'' channel_binding=prefer host=172.28.0.5 port=5432 sslmode=prefer sslcompression=0 sslsni=1 ssl_min_protocol_version=TLSv1.2 gssencmode=prefer krbsrvname=postgres target_session_attrs=any'
primary_slot_name = 'boslot1'

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
