# SUSE Manager / Uyuni - High Availability with postgres streaming replication 

## UNDER CONSTRUCTION still...
Imagine you have a business critical SUSE Manager for patching and configuration management for a large number of systems.
The headaches starts with thinking about how to make the SUSE Manager server high available in order to allow patching and configuration management with least downtime for the linux systems you manage. *Yes, with least downtime, near zero downtime.*

As we know SUSE Manager is using postgres database to store meta data of packages, channels, organizations and users. Over time the database can become quite large, several hundred GB db size, depending the number of channels and salt minions you manage, will be reached faster than you would expect.
On the disk volumes of SUSE Manager all rpms will be stored in /var/spacewalk and will grow as you will sync more and more products and repositories. A typical volume size of  more than 500GB for /var/spacewalk is often the case.

Now what can we do if the SUSE Manager breaks. Break could mean HW defect of hypervisor server, VM disk corrupt or even the datacenter is down etc..
You have some options to recover:
* revert back the VM snaphsot but is storage expensive.
* install a new SUSE Manager and restore db and data but it will take some time.
* revert to a new blank installed SUSE Manager but without DB data with history and you need to re-register all minions.

__Now we would like to build a HA for SUSE Manager but some concernes must be taken:__
* having two SUSE Manager in same datacenter is not really disaster recovery capable;
* But having SUSE Manager in different distanced Datacenters would cause higher network latency and is hard to keep data in sync.
* what do we do if a customer is using two different public cloud providers. How can we expect same storage and network backend.
* last but not least we want to achieve HA/DR without additional 3rd party tools and skilled people. 

On the other handside HA is not equal HA. How much availability is high enough for us?
Most of the customers aim to get SUSE Manager up and running "as quick as possible" again in order to continue patching and configuration deployment without loosing existing data about minions and channels.

__How about downtime in case of failure? Is a downtime of SUSE Manager for approx. 5 minutes affordable? If yes then continue reading below.__

My approach for HA/DR is to enable a fast standby SUSE Manager recovery that is running in hot-standby mode on different system with different IP. The downtime during fail-over can be kept less than 5 minutes from alert.

## OK, here is the solution I came up and tested with.

The solutions consist of two parts:
* postgres streaming replication to replicate the data to standby server.
* A bash script using rsync to synchronize files to the standby server. [How-to replicate files](files-replication.md)

Below architecture shows the HA/DR architecture using postgres streaming replication:
For more information [configure postgres replication](postgres-replication-howto.md)

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

