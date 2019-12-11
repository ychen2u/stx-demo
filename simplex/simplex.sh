#!/bin/bash

set -e

NICS=`ip addr | grep -e "^[0-9]*: " | awk -F ":" '{print $2}' | grep -v lo | tr -d '[ ]'`
OAM_IF_PRE=`ip route | grep src | awk '{print $3}' | tr -d '[ ]'`
OAM_SUB_PRE=`ip route | grep src | awk '{print $1}' | tr -d '[ ]'`
OAM_IP_PRE=`ip route | grep src | awk '{print $NF}' | tr -d '[ ]'`
OAM_GW_PRE=`route | grep default | awk '{print $2}' | tr -d '[ ]'`
for NIC in $NICS; do
    ALLNICS="$ALLNICS|$NIC"
done

read -e -p "sysadmin passwd: " -i "sysadmin" sysadmin_passwd
read -e -p "OAM network name ($ALLNICS): " -i $OAM_IF_PRE OAM_IF
read -e -p "OAM subnet: " -i $OAM_SUB_PRE oam_subnet
read -e -p "OAM gateway: " -i $OAM_GW_PRE oam_gateway
read -e -p "OAM floating ip: " -i $OAM_IP_PRE oam_float_ip

#read -e -p "MGMT network name ($ALLNICS): " -i "ens7" mgmt_if

read -e -p "StarlingX admin passwd: " -i "Local.123" stx_passwd

read -e -p "DNS: " -i "8.8.8.8" dns_server
read -e -p "Local Registry?: " -i "yes" need_local_registry
if [ "$need_local_registry" = "yes" ]; then
    read -e -p "Local Registry: " -i "your.registry.server" local_registry
fi
read -e -p "Need proxy?: " -i "no" need_docker_proxy
if [ "$need_docker_proxy" = "yes" ]; then
    read -e -p "Docker http proxy: " -i "http://<>" http_proxy
    read -e -p "Docker https proxy: " -i "http://<>" https_proxy
fi
read -e -p "Local NTP server?: " -i "yes" need_local_ntp
if [ "$need_local_ntp" = "yes" ]; then
    read -e -p "NTP Server: " -i "your.ntp.server" ntp_server
fi

read -e -p "DATA network interface number: " -i "1" NUM_OF_DATA
read -e -p "DATA0 network name ($ALLNICS): " -i "eth1000" DATA0IF
if [ "$NUM_OF_DATA" = "2" ]; then
    read -e -p "DATA1 network name ($ALLNICS): " -i "eth1001" DATA1IF
fi

read -e -p "Need DPDK?: " -i "no" need_dpdk

echo "===================================================="
read -e -p "Confirm to run the simplex deployment? (y|N): " confirmed
confirmed=${confirmed:-n}
confirmed=`echo $confirmed | tr '[:upper:]' '[:lower:]'`

if [ "$confirmed" != "y" ]; then
    exit 1
fi

########################
## ansible

###############
#### Create ansible override

cat > ~/localhost.yml << EOF
---
system_mode: simplex

external_oam_subnet: $oam_subnet
external_oam_gateway_address: $oam_gateway
external_oam_floating_address: $oam_float_ip

admin_username: admin
admin_password: $stx_passwd

dns_servers:
  - $dns_server
EOF

if [ "$need_local_registry" = "yes" ]; then
    cat >> ~/localhost.yml << EOF
docker_registries:
  defaults:
    url: $local_registry
    secure: False

EOF
fi

if [ "$need_docker_proxy" = "yes" ]; then
    cat >> ~/localhost.yml << EOF
docker_http_proxy: $http_proxy
docker_https_proxy: $https_proxy
EOF

    if [ "$need_local_registry" = "yes" ]; then
        local_registry_ip=`echo $local_registry | awk -F ":" '{print $1}'`
        cat >> ~/localhost.yml << EOF
docker_no_proxy:
  - $local_registry_ip
EOF
    fi
fi

echo "=============================================="
echo "==== ansible override file as below:"
echo "=============================================="
cat ~/localhost.yml
echo "=============================================="

read -e -p "Confirm to run the simplex deployment? (y|N): " confirmed
confirmed=${confirmed:-n}
confirmed=`echo $confirmed | tr '[:upper:]' '[:lower:]'`

if [ "$confirmed" != "y" ]; then
    exit 1
fi

set -x

###############
#### Run ansible playbook
BOOTSTRAP_YML=`find /usr/share/ansible/stx-ansible/playbooks -name bootstrap.yml`
ansible-playbook ${BOOTSTRAP_YML} -e "ansible_become_pass=$sysadmin_passwd"
sleep 5

########################
## after ansible

source /etc/platform/openrc
export COMPUTE=controller-0

###############
#### Config NTP server
if [ "$need_local_ntp" = "yes" ]; then
    system ntp-modify ntpservers=$ntp_server
else
    system ntp-modify ntpservers=0.pool.ntp.org,1.pool.ntp.org
fi

###############
#### Config OAM
system host-if-modify ${COMPUTE} $OAM_IF -c platform
system interface-network-assign ${COMPUTE} $OAM_IF oam

###############
### Config data interface
SPL=/tmp/tmp-system-port-list
SPIL=/tmp/tmp-system-host-if-list
system host-port-list ${COMPUTE} --nowrap > ${SPL}
system host-if-list -a ${COMPUTE} --nowrap > ${SPIL}

PHYSNET0='physnet0'
DATA0PCIADDR=$(cat $SPL | grep $DATA0IF |awk '{print $8}')
DATA0PORTUUID=$(cat $SPL | grep ${DATA0PCIADDR} | awk '{print $2}')
DATA0PORTNAME=$(cat $SPL | grep ${DATA0PCIADDR} | awk '{print $4}')
DATA0IFUUID=$(cat $SPIL | awk -v DATA0PORTNAME=$DATA0PORTNAME '($12 ~ DATA0PORTNAME) {print $2}')
# configure the datanetworks in sysinv, prior to referencing it in the 'system host-if-modify command'
system datanetwork-add ${PHYSNET0} vlan
# the host-if-modify '-p' flag is deprecated in favor of  the '-d' flag for assignment of datanetworks.
system host-if-modify -m 1500 -n data0 -c data ${COMPUTE} ${DATA0IFUUID}
system interface-datanetwork-assign ${COMPUTE} ${DATA0IFUUID} ${PHYSNET0}

if [ "$NUM_OF_DATA" = "2" ]; then
    PHYSNET1='physnet1'
    DATA1PCIADDR=$(cat $SPL | grep $DATA1IF |awk '{print $8}')
    DATA1PORTUUID=$(cat $SPL | grep ${DATA1PCIADDR} | awk '{print $2}')
    DATA1PORTNAME=$(cat  $SPL | grep ${DATA1PCIADDR} | awk '{print $4}')
    DATA1IFUUID=$(cat $SPIL | awk -v DATA1PORTNAME=$DATA1PORTNAME '($12 ~ DATA1PORTNAME) {print $2}')
    system datanetwork-add ${PHYSNET1} vlan
    system host-if-modify -m 1500 -n data1 -c data ${COMPUTE} ${DATA1IFUUID}
    system interface-datanetwork-assign ${COMPUTE} ${DATA1IFUUID} ${PHYSNET1}
fi

###############
#### Add Labels
system host-label-assign ${COMPUTE} openstack-control-plane=enabled
system host-label-assign ${COMPUTE} openstack-compute-node=enabled
system host-label-assign ${COMPUTE} openvswitch=enabled
system host-label-assign ${COMPUTE} sriov=enabled
sleep 5

###############
#### Setup Partitions
echo ">>> Getting root disk info"
ROOT_DISK=$(system host-show ${COMPUTE} | grep rootfs | awk '{print $4}')
ROOT_DISK_UUID=$(system host-disk-list ${COMPUTE} --nowrap | grep ${ROOT_DISK} | awk '{print $2}')
echo "Root disk: $ROOT_DISK, UUID: $ROOT_DISK_UUID"

echo ">>>> Configuring nova-local"
NOVA_SIZE=24
NOVA_PARTITION=$(system host-disk-partition-add -t lvm_phys_vol ${COMPUTE} ${ROOT_DISK_UUID} ${NOVA_SIZE})
NOVA_PARTITION_UUID=$(echo ${NOVA_PARTITION} | grep -ow "| uuid | [a-z0-9\-]* |" | awk '{print $4}')
system host-lvg-add ${COMPUTE} nova-local
system host-pv-add ${COMPUTE} nova-local ${NOVA_PARTITION_UUID}
sleep 2

echo ">>> Wait for partition $NOVA_PARTITION_UUID to be ready."
while true; do
    if system host-disk-partition-list $COMPUTE --nowrap | grep $NOVA_PARTITION_UUID | grep Ready; then
        break
    fi
    sleep 1
done

system host-pv-list ${COMPUTE} 


###############
#### Config Ceph
echo ">>> Add OSDs to primary tier"
system host-disk-list ${COMPUTE}
system host-disk-list ${COMPUTE} --nowrap | grep "/dev" | grep -v $ROOT_DISK_UUID | awk '{print $2}' | xargs -i system host-stor-add controller-0 {}
system host-stor-list ${COMPUTE}

if [ "$need_dpdk" = "yes" ]; then
    system modify --vswitch_type ovs-dpdk
    system host-memory-modify -f vswitch -1G 1 ${COMPUTE} 0
fi


###############
#### unlock controller-0
system host-unlock ${COMPUTE}

