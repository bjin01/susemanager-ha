# Compose the setup_env.sh for syncing files 

The bosuma-ha.sh is a shell script that I took over from the original /usr/lib/susemanager/bin/mgr-setup 
This mgr-setup has an option "-r" for migrating old SUSE Manager server 3.x to new SUSE Manager 4.x. And the migration part inside the script has the steps which will use scp and rsync to copy the files from old-server to the new-server.
I took this file and adapted the steps in order to allow "copy" the files from an SUSE Manager 4.2 to another SUSE Manager 4.2. 
The old part for pg_dump and pg_restore has been removed as we use postgres streaming applications instead.

So now when we want to execute the ```bosuma-ha.sh -r``` to start copy the files from primary to secondary server we need ```setup_env.sh``` file what holds the information about hostname and IP address of the primary and secondary server.

The setup_env.sh is written by ```yast2 susemanager_setup```. But we can also create the content by using an editor.

Below we see an example of setup_env.sh where parameters ```SATELLITE_IP``` is the IP address of the SUSE Manager primary server and ```MANAGER_IP``` is the IP address of the standby SUSE Manager server. In different words the SATELLITE_IP is from where we copy the files to, to MANAGER_IP.

Below example SATELLITE_IP='192.168.100.10' is the primary SUSE Manager server and MANAGER_IP='10.10.10.10' is the standby SUSE Manager server.


```
export MANAGER_FORCE_INSTALL='1'
export SATELLITE_DB_PASS='mydbpass'
export SATELLITE_DB_SID='susemanager'
export SATELLITE_DB_USER='susemanager'
export SATELLITE_DOMAIN='mydomain.eu'
export SATELLITE_HOST='mysuma02'
export SATELLITE_IP='192.168.100.10'
export ACTIVATE_SLP='n'
export MANAGER_ADMIN_EMAIL='root@mysuma02.mydomain.eu'
export MANAGER_IP='10.10.10.10'
```