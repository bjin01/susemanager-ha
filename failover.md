# Fail over to standby SUSE Manager server

Steps to fail over to the standby SUSE Manager server.

I assume the existing primary SUSE Manager is broken and shutdown. The standby SUSE Manager server is ready to take over.

## Promote the standby server to be a primary server:

```
su - postgres
rm /var/lib/pgsql/data/standby.signal
pg_ctl promote
```

## Rename the standby server to be the hostname of the old primary server
We need to do this step because we copied all relevant files from the primary server to the standby server. We need to rename the standby server to be the hostname of the old primary server but the standby server has an different ip address.

All files must be have been copied from the primary server to the standby server. A cron job was setup and did the job on a regular basis. Without correctly copied files the failover will not work. Review the [files-replication.md](../blob/master/files-replication.md) for more information.

```

then start suse manager as root user:
```
systemctl start postgresql.service

spacewalk-service start
```

## Configure DNS to point to the new primary server
We need to change the DNS record to point to the new primary server. The ip address of the SUSE Manager server record must be changed to the IP of the standby server.

