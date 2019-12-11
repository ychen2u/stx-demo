#!/bin/bash
set -ex

name=$1
iso=$2

PWD=`pwd`
imgloc="$PWD/vmimgs"

echo "Createing VM for $name"

mkdir -p $imgloc
mkdir -p vms
## Create disk images.
sudo qemu-img create -f qcow2 $imgloc/$name-0.img 400G
sudo qemu-img create -f qcow2 $imgloc/$name-1.img 30G

## modify domain description xml and define vms accordingly.
cp ctn_controller0.xml vms/$name.xml
sed -i -e "s,NAME,$name," \
       -e "s,ISO,$iso," \
       -e "s,DISK0,$imgloc/$name-0.img," \
       -e "s,DISK1,$imgloc/$name-1.img," \
    vms/$name.xml

sudo virsh define vms/$name.xml
echo "KVM: domain $name defined"

