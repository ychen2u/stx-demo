#!/bin/sh

#install libvirt/qemu
sudo apt-get install virt-manager libvirt-bin qemu-system -y
sudo virsh net-destroy default
sudo virsh net-undefine default
sudo rm -rf /etc/libvirt/qemu/networks/autostart/default.xml
cat << EOF | sudo tee /etc/libvirt/qemu.conf
user = "root"
group = "root"
EOF

sudo service libvirt-bin restart
