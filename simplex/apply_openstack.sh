#!/bin/bash


OPENSTACK_ROOT="openstack_helm"

read -e -p "Link of helm charts: " helm_charts
read -e -p "Openstack admin password: " -i "Local.123" PASSWORD

echo "===================================================="
read -e -p "Confirm to apply the stx-openstack? (y|N): " confirmed
confirmed=${confirmed:-n}
confirmed=`echo $confirmed | tr '[:upper:]' '[:lower:]'`

if [ "$confirmed" != "y" ]; then
    exit 1
fi

########################
## apply stx-openstack application
user=`whoami`
cat << EOF | sudo tee /etc/sudoers.d/${user}
${user} ALL = (root) NOPASSWD:ALL
EOF

set -ex

#### get helm_charts ready
if [ ! -e $helm_charts ]; then
    ## download helm charts from website
    wget $helm_charts
    helm_file=`echo $helm_charts | awk -F "/" '{print $NF}'`
else
    ## local file
    helm_file=$helm_charts
fi
ls $helm_file

####### Sub script running under StarlingX environment
PHYS_NETS_INCLUDE="$HOME/physical_nets"
(
source /etc/platform/openrc

CHECK_APP_STATUS() {
    appname=$1
    expected=$2

    while true; do
        if [ system application-list | grep $appname | grep $expected ]; then
            echo "$appname successfully $expected."
            break
        else
            # workaround: found issue that platform-integ-apps always at uploaded status.
            #  force it to be applied.
            if [ system application-list | grep $appname | grep uploaded ]; then
                system application-apply $appname
            fi

            if [ system application-list | grep $appname | grep failed ]; then
                curr_stat=`system application-list | grep $appname | awk '{print $10}'`
                echo "ERROR: $appname status $curr_stat."
                exit 1
            fi
        fi
        sleep 60
    done
}
#### wait until platform-integ-apps applied
CHECK_APP_STATUS "platform-integ-apps" "applied"

#### upload stx-openstack
app_name="stx-openstack"
system application-upload -n $app_name $helm_file
CHECK_APP_STATUS "$app_name" "uploaded"

system application-apply $app_name
CHECK_APP_STATUS "$app_name" "applied"

#### Get physical networks
PHYSNETS=`system datanetwork-list | grep vlan | awk '{print $4}' | tr -d '[ ]'`
id=0
for physnet in $PHYSNETS; do
    cat >> $PHYS_NETS_INCLUDE << EOF
PHYSNET$id='$physnet'
EOF
done
)

########################
## Config Openstack

#### Setup openstack admin role
sudo mkdir -p /etc/openstack
sudo tee /etc/openstack/clouds.yaml << EOF
clouds:
  $OPENSTACK_ROOT:
    region_name: RegionOne
    identity_api_version: 3
    auth:
      username: 'admin'
      password: '$PASSWORD'
      project_name: 'admin'
      project_domain_name: 'default'
      user_domain_name: 'default'
      auth_url: 'http://keystone.openstack.svc.cluster.local/v3'
EOF

export OS_CLOUD=$OPENSTACK_ROOT
openstack endpoint list
