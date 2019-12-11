#!/bin/bash

set -ex

for br in virbr1 virbr2 virbr3 virbr4; do
    sudo ifconfig $br down || true
    sudo brctl delbr $br || true
    sudo brctl addbr $br
done

#OAM
sudo ifconfig virbr1 10.10.10.1/24 up
#MGMT
sudo ifconfig virbr2 192.178.204.1/24 up
#DATA
sudo ifconfig virbr3 up
sudo ifconfig virbr4 up

if ! sudo iptables -t nat -L | grep -q 10.10.10.0/24; then
    sudo iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -j MASQUERADE
fi

