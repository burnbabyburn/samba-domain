#!/bin/bash

#set -e
set -x

appSetup () {

	# Set variables
	DOMAIN=${DOMAIN:-SAMDOM.LOCAL}
	DOMAINUSER=${DOMAINUSER:-Administrator}
	DOMAINPASS=${DOMAINPASS:-youshouldsetapassword}
	JOIN=${JOIN:-false}
	JOINSITE=${JOINSITE:-NONE}
	MULTISITE=${MULTISITE:-false}
	NOCOMPLEXITY=${NOCOMPLEXITY:-false}
	INSECURELDAP=${INSECURELDAP:-false}
	DNSFORWARDER=${DNSFORWARDER:-NONE}
	HOSTIP=${HOSTIP:-NONE}
	TLS=${TLS:-true}
	LOGS=${LOGS:-false}
	ADLOGINONUNIX=${ADLOGINONUNIX:-false}
	FREERADIUS=${FREERADIUS:-false}
	
	DEBUG=${DEBUG:-true}
	
	LDOMAIN=${DOMAIN,,} #alllowercase
	UDOMAIN=${DOMAIN^^} #ALLUPPERCASE
	URDOMAIN=${UDOMAIN%%.*} #trim

	# If multi-site, we need to connect to the VPN before joining the domain
	if [[ ${MULTISITE,,} == "true" ]]; then
		/usr/sbin/openvpn --config /docker.ovpn &
		VPNPID=$!
		echo "Sleeping 30s to ensure VPN connects ($VPNPID)";
		sleep 30
	fi

        # Set host ip option
        if [[ "$HOSTIP" != "NONE" ]]; then
		HOSTIP_OPTION="--host-ip=$HOSTIP"
        else
		HOSTIP_OPTION=""
        fi
		if [[ "$DEBUG" == "true" ]]; then
		DEBUG_OPTION="-d 1"
        else
		DEBUG_OPTION=""
        fi
		
	if [[ ! -d /etc/samba/external/ ]]; then
		mkdir /etc/samba/external
	fi
	
	# Set up samba
	mv /etc/krb5.conf /etc/krb5.conf.orig
	{
	echo "[libdefaults]" > /etc/krb5.conf
	echo "    dns_lookup_realm = false"
	echo "    dns_lookup_kdc = true"
	echo "    default_realm = ${UDOMAIN}"
	} >> /etc/krb5.conf
	if [[ ${LOGS,,} == "true" ]]; then
	{
	echo "[logging]"  >> /etc/krb5.conf
	echo "    default = FILE:/var/log/samba/krb5libs.log"
	echo "    kdc = FILE:/var/log/samba/krb5kdc.log"
	echo "    admin_server = FILE:/var/log/samba/kadmind.log"
	} >> /etc/krb5.conf
	fi
	# If the finished file isn't there, this is brand new, we're not just moving to a new container
	if [[ ! -f /etc/samba/external/smb.conf ]]; then
		if [[ -f /etc/samba/smb.conf ]]; then
			mv /etc/samba/smb.conf /etc/samba/smb.conf.orig
		fi
		
		net ads keytab create
		if [[ ${JOIN,,} == "true" ]]; then
			if [[ ${JOINSITE} == "NONE" ]]; then
				samba-tool domain join ${LDOMAIN} DC -U${URDOMAIN}\\${DOMAINUSER} --password=${DOMAINPASS} --dns-backend=SAMBA_INTERNAL ${DEBUG_OPTION}
			else
				samba-tool domain join ${LDOMAIN} DC -U${URDOMAIN}\\${DOMAINUSER} --password=${DOMAINPASS} --dns-backend=SAMBA_INTERNAL --site=${JOINSITE} ${DEBUG_OPTION}
			fi
		else
			samba-tool domain provision --use-rfc2307 --domain=${URDOMAIN} --realm=${UDOMAIN} --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass=${DOMAINPASS} ${HOSTIP_OPTION} ${DEBUG_OPTION}
			
			if [[ ! -d /var/lib/samba/sysvol/"$LDOMAIN"/Policies/PolicyDefinitions/ ]]; then
				mkdir -p /var/lib/samba/sysvol/"$LDOMAIN"/Policies/PolicyDefinitions/en-US
				mkdir /var/lib/samba/sysvol/"$LDOMAIN"/Policies/PolicyDefinitions/de-DE
			fi
		fi
		
		if [[ ${NOCOMPLEXITY,,} == "true" ]]; then
			samba-tool domain passwordsettings set --complexity=off ${DEBUG_OPTION}
			samba-tool domain passwordsettings set --history-length=0 ${DEBUG_OPTION}
			samba-tool domain passwordsettings set --min-pwd-age=0 ${DEBUG_OPTION}
			samba-tool domain passwordsettings set --max-pwd-age=0 ${DEBUG_OPTION}
		fi
		#Prevent https://wiki.samba.org/index.php/Samba_Member_Server_Troubleshooting => SeDiskOperatorPrivilege can't be set
		if [[ ! -f /etc/samba/user.map ]]; then
		echo '!'"root = ${DOMAIN}\\Administrator" > /etc/samba/user.map
		sed -i "/\[global\]/a \
username map = /etc/samba/user.map\
		" /etc/samba/smb.conf
		#net ads keytab create ${DEBUG_OPTION}
		fi


		if [[ $DNSFORWARDER != "NONE" ]]; then
			sed -i "/\[global\]/a \
				\\\tdns forwarder = ${DNSFORWARDER}\
				" /etc/samba/smb.conf
		fi
		
		if [[ ${TLS,,} == "true" ]]; then
#		openssl dhparam -out /var/lib/samba/private/tls/dh.key 2048 
		sed -i "/\[global\]/a \
tls enabled  = yes\\n\
tls keyfile  = /var/lib/samba/private/tls/key.pem\\n\
tls certfile = /var/lib/samba/private/tls/cert.pem\\n\
#tls cafile   = /var/lib/samba/private/tls/chain.pem\\n\
tls cafile   = /var/lib/samba/private/tls/ca.pem\\n\
#tls dh params file = /var/lib/samba/private/tls/dh.key\\n\
#tls crlfile   = /etc/samba/tls/crl.pem\\n\
#tls verify peer = ca_and_name\
		" /etc/samba/smb.conf

		fi
		if [[ ${FREERADIUS,,} == "true" ]]; then
		sed -i "/\[global\]/a \
ntlm auth = mschapv2-and-ntlmv2-only\
lanman auth = no\
client lanman auth = no\
		" /etc/samba/smb.conf
		fi
		sed -i "/\[global\]/a \
wins support = yes\\n\
# Template settings for login shell and home directory\\n\
template shell = /bin/bash\\n\
template homedir = /home/%U\\n\
load printers = no\\n\
printing = bsd\\n\
printcap name = /dev/null\\n\
disable spoolss = yes\
		" /etc/samba/smb.conf
		
		if [[ ${LOGS,,} == "true" ]]; then
			sed -i "/\[global\]/a \
log file = /var/log/samba/%m.log\\n\
max log size = 10000\\n\
log level = 3\
			" /etc/samba/smb.conf
		fi
		if [[ ${INSECURELDAP,,} == "true" ]]; then
			sed -i "/\[global\]/a \
ldap server require strong auth = no\
			" /etc/samba/smb.conf
		fi
		if [[ ${ADLOGINONUNIX,,} == "true" ]]; then
			sed -i "/\[global\]/a \
winbind enum users = yes\\n\
winbind enum groups = yes\\n\
			" /etc/samba/smb.conf
		# nsswitch anpassen
		sed -i "s,passwd:.*,passwd:         files winbind,g" "/etc/nsswitch.conf"
		sed -i "s,group:.*,group:          files winbind,g" "/etc/nsswitch.conf"
		sed -i "s,hosts:.*,hosts:          files dns,g" "/etc/nsswitch.conf"
		sed -i "s,networks:.*,networks:      files dns,g" "/etc/nsswitch.conf"
		fi

        #Drop privileges
		#https://medium.com/@mccode/processes-in-containers-should-not-run-as-root-2feae3f0df3b
         
         
		# Once we are set up, we'll make a file so that we know to use it if we ever spin this up again
		cp -f /etc/samba/smb.conf /etc/samba/external/smb.conf
	else
		cp -f /etc/samba/external/smb.conf /etc/samba/smb.conf
	fi
  
	# Set up supervisor
	touch /etc/supervisor/conf.d/supervisord.conf
	{
	echo "[supervisord]"
	echo "nodaemon=true"
	#Suppress CRIT Supervisor is running as root.  Privileges were not dropped because no user is specified in the config file.  If you intend to run as root, you can set user=root in the config file to avoid this message.
	echo "user=root"
	echo ""
	echo "[program:samba]"
	echo "command=/usr/sbin/samba -F ${DEBUG_OPTION}"
	echo "stdout_logfile=/dev/fd/1"
	echo "stdout_logfile_maxbytes=0"
	echo "stdout_logfile_backups=0"
	echo ""
	echo "[program:ntpd]"
	echo "command=/usr/sbin/ntpd -c /etc/ntpd.conf -n ${DEBUG_OPTION}"
	echo "stdout_logfile=/dev/fd/1"
	echo "stdout_logfile_maxbytes=0"
	echo "stdout_logfile_backups=0"
	} >> /etc/supervisor/conf.d/supervisord.conf
	
	#Suppress CRIT Server 'unix_http_server' running without any HTTP authentication checking
	#https://github.com/Supervisor/supervisor/issues/717
	sed -i "/\[unix_http_server\]/a \
username=dummy\\n\
password=dummy\
	" /etc/supervisor/supervisord.conf
	sed -i "/\[supervisorctl\]/a \
username = dummy\\n\
password = dummy\
	" /etc/supervisor/supervisord.conf

	if [[ ${MULTISITE,,} == "true" ]]; then
	  if [[ -n $VPNPID ]]; then
	    kill $VPNPID	
	  fi
	{
      echo ""
	  echo "[program:openvpn]"
	  echo "command=/usr/sbin/openvpn --config /docker.ovpn"		        
	} >> /etc/supervisor/conf.d/supervisord.conf
	fi

	if [[ ${JOINDC,,} == "true" ]]; then
	  # Set up ntpd
	  touch /etc/ntpd.conf
	  {
	  echo "# Local clock. Note that is not the localhost address!"
	  echo "server 127.127.1.0"
	  echo "fudge  127.127.1.0 stratum 10"
 
	  echo "# Where to retrieve the time from"
	  echo "server DC01.${LDOMAIN}    iburst prefer"
	  echo "server DC02.${LDOMAIN}    iburst"

	  echo "driftfile /var/lib/ntp/ntp.drift"
	  echo "logfile   /var/log/ntp"

	  echo "# Access control"
	  echo "# Default restriction: Disallow everything"
	  echo "restrict default ignore"

	  echo "# No restrictions for localhost"
	  echo "restrict 127.0.0.1"

	  echo "# Enable the time sources only to only provide time to this host"
	  echo "restrict DC01.${LDOMAIN}  mask 255.255.255.255    nomodify notrap nopeer noquery"
	  echo "restrict DC02.${LDOMAIN}  mask 255.255.255.255    nomodify notrap nopeer noquery"
	  echo ""
	  echo "tinker panic 0"
	  } >> /etc/ntpd.conf
	else
	  {
	  echo "server 127.127.1.0"
	  echo "fudge  127.127.1.0 stratum 10"
	  echo "server 0.pool.ntp.org     iburst prefer"
	  echo "server 1.pool.ntp.org     iburst prefer"
	  echo "server 2.pool.ntp.org     iburst prefer"
	  echo "driftfile       /var/lib/ntp/ntp.drift"
	  echo "logfile         /var/log/ntp"
	  echo "ntpsigndsocket  /var/lib/samba/ntp_signd/"
	  echo "restrict default kod nomodify notrap nopeer mssntp"
	  echo "restrict 127.0.0.1"
	  echo "restrict 0.pool.ntp.org   mask 255.255.255.255    nomodify notrap nopeer noquery"
	  echo "restrict 1.pool.ntp.org   mask 255.255.255.255    nomodify notrap nopeer noquery"
	  echo "restrict 2.pool.ntp.org   mask 255.255.255.255    nomodify notrap nopeer noquery"	        
	  }  >> /etc/ntpd.conf

	  # Own socket
	  mkdir -p /var/lib/samba/ntp_signd/
	  chown root:ntp /var/lib/samba/ntp_signd/
	  chmod 750 /var/lib/samba/ntp_signd/
    fi

	if [[ ! -d /var/lib/samba/winbindd_privileged/ ]]; then
	  mkdir /var/lib/samba/winbindd_privileged/
	  chown root:winbindd_priv /var/lib/samba/winbindd_privileged/
	  chmod 0750 /var/lib/samba/winbindd_privileged
	else
	  chown root:winbindd_priv /var/lib/samba/winbindd_privileged/
	  chmod 0750 /var/lib/samba/winbindd_privileged
	fi

	# Let Domain Admins administrate shares
	#net rpc rights grant "$UDOMAIN\Domain Admins" SeDiskOperatorPrivilege -U"$UDOMAIN\administrator" ${DEBUG_OPTION}

	appStart
}

appStart () {
	/usr/bin/supervisord
}

case "$1" in
	start)
		if [[ -f /etc/samba/external/smb.conf ]]; then
			cp /etc/samba/external/smb.conf /etc/samba/smb.conf
			appStart
		else
			echo "Config file is missing."
		fi
		;;
	setup)
		# If the supervisor conf isn't there, we're spinning up a new container
		if [[ -f /etc/supervisor/conf.d/supervisord.conf ]]; then
			appStart
		else
			appSetup
		fi
		;;
esac

exit 0