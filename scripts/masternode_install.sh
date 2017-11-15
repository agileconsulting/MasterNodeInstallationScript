#!/bin/bash
#                   
# version 	0.4-alpha
# date    	2017-09-26
#
# function	masternode setup script
#			This scripts needs to be run as root
# 			to make services start persistent
#
# Twitter 	@marsmensch
#

# Useful variables
DATE_STAMP="$(date +%y-%m-%d-%s)"
# im an not very proud of this
IPV6_INT_BASE="$(ip -6 addr show dev ${ETH_INTERFACE} | grep inet6 | awk -F '[ \t]+|/' '{print $3}' | grep -v ^fe80 | grep -v ^::1 | cut -f1-4 -d':' | head -1)"

function check_distro() {
	# currently only for Ubuntu 16.04
	if [[ -r /etc/os-release ]]; then
		. /etc/os-release
		if [[ "${VERSION_ID}" != "16.04" ]]; then
			echo "This script only supports ubuntu 16.04 LTS, exiting."
			exit 1
		fi
	else
		# no, thats not ok!
		echo "This script only supports ubuntu 16.04 LTS, exiting."	
		exit 1
	fi
}

function install_packages() {
	# development and build packages
	# these are common on all cryptos
	echo "Package installation!"
	apt-get -qq update
	apt-get -qqy -o=Dpkg::Use-Pty=0 install build-essential g++ \
	protobuf-compiler libboost-all-dev autotools-dev \
    automake libcurl4-openssl-dev libboost-all-dev libssl-dev libdb++-dev \
    make autoconf automake libtool git apt-utils libprotobuf-dev pkg-config \
    libcurl3-dev libudev-dev libqrencode-dev bsdmainutils pkg-config libssl-dev \
    libgmp3-dev libevent-dev jp2a
}

function swaphack() { 
#check if swap is available
if [ $(free | awk '/^Swap:/ {exit !$2}') ] || [ ! -f "/var/mnode_swap.img" ];then
	echo "No proper swap, creating it"
	# needed because ant servers are ants
	rm -f /var/mnode_swap.img
	dd if=/dev/zero of=/var/mnode_swap.img bs=1024k count=${MNODE_SWAPSIZE}
	chmod 0600 /var/mnode_swap.img
	mkswap /var/mnode_swap.img
	swapon /var/mnode_swap.img
	echo '/var/mnode_swap.img none swap sw 0 0' | tee -a /etc/fstab
	echo 'vm.swappiness=10' | tee -a /etc/sysctl.conf
	echo 'vm.vfs_cache_pressure=50' | tee -a /etc/sysctl.conf		
else
	echo "All good, we have a swap"	
fi
}

function build_mn_from_source() {
        # daemon not found compile it
        if [ ! -f ${MNODE_DAEMON} ]; then
            #go to user home
			cd /home/${CODENAME}
			pwd
			
			git clone ${GIT_URL} 
            cd ${GIT_PROJECT}
            echo "Checkout desired tag: ${SCVERSION}"
			
			
			# Download & Install Berkley DB
            # -----------------------------
			mkdir db4
			wget 'http://download.oracle.com/berkeley-db/db-4.8.30.NC.tar.gz'
			tar -xzvf db-4.8.30.NC.tar.gz
			cd db-4.8.30.NC/build_unix/
			../dist/configure --enable-cxx --disable-shared --with-pic --prefix=/home/${CODENAME}/${GIT_PROJECT}/db4/
			make install
			
                # print ascii banner if a logo exists
                echo -e "Starting the compilation process for ${CODENAME}, stay tuned"
                # compilation starts here
                   cd ..
               ./autogen.sh
			  ./configure LDFLAGS="-L/home/${CODENAME}/${GIT_PROJECT}/db4/lib/" CPPFLAGS="-I/home/${CODENAME}/${GIT_PROJECT}/db4/include/"
               make
               
			   make install
			   
        else
                echo "daemon already in place at ${MNODE_DAEMON}, not compiling"
        fi
}



function create_mn_user() {

    # our new mnode unpriv user acc is added 
    if id "${CODENAME}" >/dev/null 2>&1; then
        echo "user exists already, do nothing"
    else
        echo "Adding new system user ${CODENAME}"
        adduser --disabled-password --gecos "" ${CODENAME}
        sudo adduser ${CODENAME}  sudo
    fi
    
}



function configure_firewall() {
    echo "Configuring firewall rules"
	# disallow everything except ssh and masternode inbound ports
	ufw default deny
	ufw logging on
	ufw allow ${SSH_INBOUND_PORT}/tcp
	# KISS, its always the same port for all interfaces
	ufw allow ${MNODE_INBOUND_PORT}/tcp
	# This will only allow 6 connections every 30 seconds from the same IP address.
	ufw limit OpenSSH	
	ufw --force enable 
}

function create_mn_configuration() {
	# create one config file per masternode
	for NUM in $(seq 1 ${SETUP_MNODES_COUNT}); do
	PASS=$(date | md5sum | cut -c1-24)
		echo "writing config file ${MNODE_CONF_BASE}/${GIT_PROJECT}_n${NUM}.conf"
		cat > ${MNODE_CONF_BASE}/${GIT_PROJECT}_n${NUM}.conf <<-EOF
			rpcuser=${GIT_PROJECT}rpc
			rpcpassword=${PASS}
			rpcallowip=127.0.0.1
			rpcport=555${NUM}
			server=1
			listen=1
			daemon=1
			bind=[${IPV6_INT_BASE}:${NETWORK_BASE_TAG}::${NUM}]:${MNODE_INBOUND_PORT}
			logtimestamps=1
			mnconflock=0
			maxconnections=256
			gen=0
			masternode=1
			masternodeprivkey=HERE_GOES_YOUR_MASTERNODE_KEY_FOR_MASTERNODE_${GIT_PROJECT}_${NUM}	
		EOF
	done
}

function create_control_configuration() {
    rm /tmp/${GIT_PROJECT}_masternode.conf
	# create one line per masternode with the data we have
	for NUM in $(seq 1 ${SETUP_MNODES_COUNT}); do
		cat >> /tmp/${GIT_PROJECT}_masternode.conf <<-EOF
			${GIT_PROJECT}MN${NUM} [${IPV6_INT_BASE}:${NETWORK_BASE_TAG}::${NUM}]:${MNODE_INBOUND_PORT} MASTERNODE_PRIVKEY_FOR_${GIT_PROJECT}MN${NUM} COLLATERAL_TX_FOR_${GIT_PROJECT}MN${NUM} OUTPUT_NO_FOR_${GIT_PROJECT}MN${NUM}	
		EOF
	done
}

function create_systemd_configuration() {
	# create one config file per masternode
	for NUM in $(seq 1 ${SETUP_MNODES_COUNT}); do
	PASS=$(date | md5sum | cut -c1-24)
		echo "writing config file ${SYSTEMD_CONF}/${GIT_PROJECT}_n${NUM}.service"
		cat > ${SYSTEMD_CONF}/${GIT_PROJECT}_n${NUM}.service <<-EOF
			[Unit]
			Description=${GIT_PROJECT} distributed currency daemon
			After=network.target
                 
			[Service]
			User=${MNODE_USER}
			Group=${MNODE_USER}
         	
			Type=forking
			PIDFile=${MNODE_DATA_BASE}/${GIT_PROJECT}${NUM}/${GIT_PROJECT}.pid
			ExecStart=${MNODE_DAEMON} -daemon -pid=${MNODE_DATA_BASE}/${GIT_PROJECT}${NUM}/${GIT_PROJECT}.pid \
			-conf=${MNODE_CONF_BASE}/${GIT_PROJECT}_n${NUM}.conf -datadir=${MNODE_DATA_BASE}/${GIT_PROJECT}${NUM}
       		 
			Restart=always
			RestartSec=5
			PrivateTmp=true
			TimeoutStopSec=60s
			TimeoutStartSec=5s
			StartLimitInterval=120s
			StartLimitBurst=15
         	
			[Install]
			WantedBy=multi-user.target			
		EOF
	done
}

function set_permissions() {
	# maybe add a sudoers entry later
	chown -R ${MNODE_USER}:${MNODE_USER} ${MNODE_CONF_BASE} ${MNODE_DATA_BASE}
}

function cleanup_after() {
	apt-get -qqy -o=Dpkg::Use-Pty=0 --force-yes autoremove
	apt-get -qqy -o=Dpkg::Use-Pty=0 --force-yes autoclean

	echo "kernel.randomize_va_space=1" > /etc/sysctl.conf
	echo "net.ipv4.conf.all.rp_filter=1" >> /etc/sysctl.conf
	echo "net.ipv4.conf.all.accept_source_route=0" >> /etc/sysctl.conf
	echo "net.ipv4.icmp_echo_ignore_broadcasts=1" >> /etc/sysctl.conf
	echo "net.ipv4.conf.all.log_martians=1" >> /etc/sysctl.conf
	echo "net.ipv4.conf.default.log_martians=1" >> /etc/sysctl.conf
	echo "net.ipv4.conf.all.accept_redirects=0" >> /etc/sysctl.conf
	echo "net.ipv6.conf.all.accept_redirects=0" >> /etc/sysctl.conf
	echo "net.ipv4.conf.all.send_redirects=0" >> /etc/sysctl.conf
	echo "kernel.sysrq=0" >> /etc/sysctl.conf
	echo "net.ipv4.tcp_timestamps=0" >> /etc/sysctl.conf
	echo "net.ipv4.tcp_syncookies=1" >> /etc/sysctl.conf
	echo "net.ipv4.icmp_ignore_bogus_error_responses=1" >> /etc/sysctl.conf
	sysctl -p
	
}

function showbanner() {
cat << "EOF"
 ███╗   ██╗ ██████╗ ██████╗ ███████╗███╗   ███╗ █████╗ ███████╗████████╗███████╗██████╗ 
 ████╗  ██║██╔═══██╗██╔══██╗██╔════╝████╗ ████║██╔══██╗██╔════╝╚══██╔══╝██╔════╝██╔══██╗
 ██╔██╗ ██║██║   ██║██║  ██║█████╗  ██╔████╔██║███████║███████╗   ██║   █████╗  ██████╔╝
 ██║╚██╗██║██║   ██║██║  ██║██╔══╝  ██║╚██╔╝██║██╔══██║╚════██║   ██║   ██╔══╝  ██╔══██╗
 ██║ ╚████║╚██████╔╝██████╔╝███████╗██║ ╚═╝ ██║██║  ██║███████║   ██║   ███████╗██║  ██║
 ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝     ╚═╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝
                                                             ╚╗ @marsmensch 2016-2017 ╔╝                   				
EOF
}

function final_call() {
	# note outstanding tasks that need manual work
    echo "************! ALMOST DONE !******************************"	
	echo "There is still work to do in the configuration templates."
	echo "These are located at ${MNODE_CONF_BASE}, one per masternode."
	echo "Add your masternode private keys now."
	echo "eg in /etc/masternodes/${GIT_PROJECT}_n1.conf"	
	# systemctl command to work with mnodes here 
	echo "#!/bin/bash" > ${MNODE_HELPER}
	for NUM in $(seq 1 ${SETUP_MNODES_COUNT}); do
		echo "systemctl enable ${GIT_PROJECT}_n${NUM}" >> ${MNODE_HELPER}
		echo "systemctl restart ${GIT_PROJECT}_n${NUM}" >> ${MNODE_HELPER}
	done
	chmod u+x ${MNODE_HELPER}
	tput sgr0
}

main() {

    create_mn_user
    build_mn_from_source 
    configure_firewall      
         
}

main "$@"
