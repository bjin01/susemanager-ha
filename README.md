# SUSE Manager / Uyuni - High Availability with postgres streaming replication 

Imagine you have a business critical SUSE Manager for patching and configuration management for a large number of salt minions.
The headaches starts with thinking about how to make the SUSE Manager host high available to allow patching and configuration with least downtime for the linux systems you manage.

As we know SUSE Manager is using postgres database to store package meta data and channel meta data. The database can become quite large, several hundred GB depending the number of channels and salt minions you manage will be reached faster than you would expect.
On the disk of SUSE Manager host all rpms will be stored in /var/spacewalk and is likely to grow as you will sync more and more products and repositories over time. A typical volume size of >500GB for /var/spacewalk is often the case.

__Additional obstacles of putting SUSE Manager into a HA are:__
* And having two SUSE Manager in one datacenter is not really DR capable;
* But having SUSE Manager in different geographically distanced Datacenter gives you higher network latency and is hard to run in HA. Async could be a good way.
* what do we do if a customer is using two different public cloud platforms as DR. How can we expect same storage and network backend.
* last but not least we want to achieve HA/DR without the need to buy additional DR tools. 

But HA is not equal HA. For SUSE Manager most of the customers aim to get SUSE Manager up and running "as quick as possible" again in order to allow patching and configuration management, and of course without loosing old data.
__But how quick is quick? Is a downtime of SUSE Manager service for e.g. 5 minutes affordable? If yes then continue reading below.__

My idea of HA/DR is a more disaster recovery alike scenario for SUSE Manager.

## OK, here is the solution I came up and tested with.

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

