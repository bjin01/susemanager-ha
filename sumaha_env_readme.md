# Compose the sumaha_env.sh for syncing files 

This configuration file has 3 parameters. The usage is obvious and easy to understand.
Remember you have to run bosuma-ha.sh on the standby server. The script will source this file in 
```/root/sumaha_env.sh ```
The IP address for standby server will be verified if the current host has this ip configured.
The primary server IP will also be verified if this is found on the current host. If yes, then the script will exit with error.


```
export PRIMARY_FQDN="suma1.bo2go.home"
export PRIMARY_IP="172.28.0.5"
export STANDBY_IP="172.28.0.10"
```