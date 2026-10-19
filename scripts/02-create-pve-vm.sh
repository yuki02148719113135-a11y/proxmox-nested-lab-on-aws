#!/usr/bin/env bash
# Proxmox VE 用の VM を作成（作り直し可）。使い方: ./02-create-pve-vm.sh 1   または 2
set -euo pipefail
N=${1:?ノード番号(1または2)を指定}
ISO=$(ls /srv/iso/proxmox-ve_*.iso | sort -V | tail -1)
[ -f "$ISO" ] || { echo "ISOが見つかりません"; ls -lh /srv/iso; exit 1; }
IMG=/var/lib/libvirt/images
echo "ISO=$ISO"

sudo virsh destroy pve0$N 2>/dev/null || true
sudo virsh undefine pve0$N 2>/dev/null || true
sudo rm -f $IMG/pve0$N.qcow2
sudo qemu-img create -f qcow2 $IMG/pve0$N.qcow2 64G

sudo virt-install --name pve0$N --memory 16384 --vcpus 8 \
  --cpu host-passthrough --machine q35 --osinfo generic \
  --disk path=$IMG/pve0$N.qcow2,bus=virtio \
  --network network=labnet,model=virtio \
  --network network=vmnet,model=virtio \
  --cdrom "$ISO" --boot cdrom,hd \
  --graphics vnc,listen=127.0.0.1,port=590$N --noautoconsole

sudo virsh domblklist pve0$N --details
echo "VNC: localhost:$N  （インストール後は: sudo virsh change-media pve0$N sda --eject --config && sudo virsh start pve0$N）"
