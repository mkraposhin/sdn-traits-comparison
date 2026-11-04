#!/usr/bin/bash
for i in 2 3 4 5 6 7 8; do
  sudo ovs-vsctl del-port br0 veth-h${i}a
  sudo ovs-vsctl del-port br0 veth-h${i}b
done
sudo ovs-vsctl show
