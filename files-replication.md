# How to use bosuma-ha.sh to copy from primary to standby server

The bosuma-ha.sh is a shell script that I took over originally from ```/usr/lib/susemanager/bin/mgr-setup```
This mgr-setup has an option "-r" for migrating old SUSE Manager server 3.x to new SUSE Manager 4.x. And the migration part inside of this script has the steps which  uses scp and rsync to copy the files from old-server to the new-server.

I took this file and adapted the steps to allow "copy" the files from an SUSE Manager 4.2 to another SUSE Manager 4.2 by using scp and rsync.

So now when we want to execute the ```bosuma-ha.sh -r``` to copy the files from primary to secondary server we need ```/root/sumaha_env.sh``` file what holds the information about IP address of the primary and secondary server.

## Prerequisites:
* The bosuma-ha.sh must be executed on the standby server.
* both server (primary and standby) must allow root login via ssh using ssh keys. So __passwordless login__ for ssh is required.
* the sumaha_env.sh is pre-set in the bosuma-ha.sh. Of course you are allow to change this parameter in the bosuma-ha.sh file.
* To avoid overwritting files from wrong SUSE Manager server we precheck in the bosuma-ha.sh if the host is:
    * postgresql on the host must be already in standby mode
    * host IP is found as standby server IP given in sumaha_env.sh
    * host IP of primary server must not be found on the host
* configure [sumaha_env.sh](../blob/master/setup_env_readme.md)

## Run it:

Login as root on the standby server.

Download the git repo

copy the bash script to the target directory.
```
cd ~/
git clone https://github.com/bjin01/susemanager-ha.git
cp susemanager-ha
cp bosuma-ha.sh /usr/lib/susemanager/bin/
chmod +x /usr/lib/susemanager/bin/bosuma-ha.sh
/usr/lib/susemanager/bin/bosuma-ha.sh -r
```
