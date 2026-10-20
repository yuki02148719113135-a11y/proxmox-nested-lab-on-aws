#!/usr/bin/env bash
# EC2（Ubuntu 26.04）側：KVM・ネットワーク・NFS・NTPを構築
set -euo pipefail

sudo apt update
sudo apt install -y qemu-system-x86 libvirt-daemon-system virtinst nfs-kernel-server chrony tmux libguestfs-tools

echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
sudo modprobe -r kvm_intel && sudo modprobe kvm_intel
echo "nested=$(cat /sys/module/kvm_intel/parameters/nested)"

cat <<'XML' > /tmp/labnet.xml
<network>
  <name>labnet</name>
  <forward mode='nat'/>
  <bridge name='virbr10' stp='on' delay='0'/>
  <domain name='lab.local' localOnly='yes'/>
  <dns>
    <host ip='192.168.100.1'><hostname>kvm-host.lab.local</hostname></host>
    <host ip='192.168.100.21'><hostname>pve01.lab.local</hostname></host>
    <host ip='192.168.100.22'><hostname>pve02.lab.local</hostname></host>
  </dns>
  <ip address='192.168.100.1' netmask='255.255.255.0'/>
</network>
XML
cat <<'XML' > /tmp/vmnet.xml
<network>
  <name>vmnet</name>
  <bridge name='virbr11' stp='on' delay='0'/>
  <ip address='10.10.10.1' netmask='255.255.255.0'/>
</network>
XML
for NET in labnet vmnet; do
  sudo virsh net-info $NET >/dev/null 2>&1 || sudo virsh net-define /tmp/$NET.xml
  sudo virsh net-start $NET 2>/dev/null || true
  sudo virsh net-autostart $NET
done

grep -q pve01.lab.local /etc/hosts || printf "192.168.100.21 pve01.lab.local pve01\n192.168.100.22 pve02.lab.local pve02\n" | sudo tee -a /etc/hosts
grep -q "allow 192.168.100.0/24" /etc/chrony/chrony.conf || echo "allow 192.168.100.0/24" | sudo tee -a /etc/chrony/chrony.conf
sudo systemctl restart chrony

sudo mkdir -p /srv/nfs/pve && sudo chmod 777 /srv/nfs/pve
grep -q /srv/nfs/pve /etc/exports || echo "/srv/nfs/pve 192.168.100.0/24(rw,sync,no_root_squash,no_subtree_check)" | sudo tee -a /etc/exports
sudo exportfs -ra && sudo exportfs -v
