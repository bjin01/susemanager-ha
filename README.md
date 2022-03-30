# SUSE Manager / Uyuni - High Availability with postgres replication streaming

Imagine you have a business critical SUSE Manager for patch and configuration management for a large number of salt minions.
The headaches starts with thinking about how to make the SUSE Manager host high available to allow patching and configuration with least downtime for the linux systems you manage.

As we know SUSE Manager is using postgres database to store package meta data and channel meta data. The database can become quite large, several hundred GB depending the number of channels and salt minions you manage will be reached faster than you would expect.
On the disk of SUSE Manager host all rpms will be stored in /var/spacewalk and is likely to grow as you will sync more and more products and repositories over time. A typical volume size of >500GB for /var/spacewalk is often the case.

Now what options do we have to put the SUSE Manager host into a kind of HA scenario but without using any additional tools except those what comes with SUSE Manager ISO.
But HA is not equal HA. With SUSE Manager I and most of the customers aim to get SUSE Manager up and running again in order to continue allow patching and configuration management, and of course without loosing old data.

My idea of HA/DR is a more disaster recovery alike scenario for SUSE Manager.

Below architecture shows the DR architecture:
<p align="center">
<img src="architecture-DR-SUMA.svg">
</p>

Once a disaster occured we switch over to the standby server.
The DNS entry needs to be adapted to the IP of the standby SUSE Manager server.
<p align="center">
<img src="architecture-DR-SUMA-switch.svg">
</p>

All minions and SUSE Manager proxy systems don't need to make any configuration changes. 
But it is a good idea to run a highstate from the newly promoted SUSE Manager server.

Once the old primary SUSE Manager is back online again we can also re-establish the replication from new primary to new standby server.
<p align="center">
<img src="architecture-DR-SUMA-re-establish-replication-after-dr.svg">
</p>

