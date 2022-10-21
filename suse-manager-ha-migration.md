# Migration of SUSE Manager HA from 4.2 to 4.3 

Migrate SUSE Manager primary and secondary server in the HA scenario follow below steps:

Step 1 - primary node: 
Migrate SUSE Manager primary node according to SUSE Manager Upgrade Documentation first.
Update primary node and run zypper migration to upgrade to SLES15SP4
```
zypper up -y
zypper migration
```
reboot primary node

Execute ```/usr/lib/susemanager/bin/pg-migrate-x-to-y.sh``` on primary node

> The db upgrade step must be completed and SUSE Manager services started successfully.
```spacewalk-service status``` shows services status.

Step 2 - secondary node:


After secondary node reboot we stop postgresql replication by promoting postgresql database from standby mode to normal mode.

> Cautions: The DNS server must be configured correctly to return IP of primary node and no SUSE Manager proxy nor any salt-minion is connecting to the secondary node.

```
su - postgres
pg_ctl promote
```
Once postgresql is started we update secondary node and run zypper migration to upgrade the OS to SLES15SP4 and SUSE Manager 4.3
```
zypper up -y
zypper migration
```
reboot secondary node

Execute ```/usr/lib/susemanager/bin/pg-migrate-x-to-y.sh``` on secondary node

> The db upgrade step must be completed and SUSE Manager services started successfully.
```spacewalk-service status``` shows services status.

Now stop SUSE Manager services as this node is actually a secondary node and should not be running.
```
spacewalk-service stop
```

Also stop postgresql which is operating in normal mode:
```
systemctl stop postgresql.service
```

Now we configure the secondary node's postgresql as standby node again:
```
rm -rf /var/lib/pgsql/data

su - postgres
pg_basebackup -h 172.28.0.10 -D /var/lib/pgsql/data -U borep -v -Fp --checkpoint=fast -R --slot=boslot2 -C -Xs
exit

systemctl start postgresql.service
```
After pg_basebackup and postgresql.service is started the replication has been started and postgresql is running in standby mode.

Verify:
Run below command and should get similar output.
```
# ps aux | grep -i walreceive
root      8214  0.0  0.0   7680   848 pts/1    S+   19:48   0:00 grep --color=auto -i walreceive
postgres 25928  0.0  0.0 8179824 12336 ?       Ss   15:03   0:13 postgres: walreceiver streaming 44/BAF86710
```

> Don't forget to delete previous used replication slot.
Get the replication slots in postgresql on primary node:
```
postgres=# select * from pg_replication_slots;
```

Delete unused replication slots:
```
postgres=# select pg_drop_replication_slot(‘boslot1’);
```
