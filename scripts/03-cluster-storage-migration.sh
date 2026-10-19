#!/usr/bin/env bash
# EC2 側で実行：クラスタ作成・NFS登録・移行ネットワーク・テストVM作成
set -euo pipefail
P1=192.168.100.21; P2=192.168.100.22

ssh root@$P1 "pvecm status >/dev/null 2>&1 || pvecm create lab-cluster --link0 $P1"
ssh root@$P2 "pvecm status >/dev/null 2>&1 || pvecm add $P1 --link0 $P2"
ssh root@$P1 "pvecm status | grep -E 'Nodes|Quorate'"

ssh root@$P1 "pvesm status | grep -q nfs-shared || pvesm add nfs nfs-shared --server 192.168.100.1 --export /srv/nfs/pve --content images,iso"
sudo mkdir -p /srv/nfs/pve/template/iso
sudo cp -n /srv/iso/alpine-virt-*.iso /srv/nfs/pve/template/iso/

for N in 1 2; do
  ssh root@192.168.100.2$N "grep -q 'address 10.10.10' /etc/network/interfaces || { sed -i '/^iface nic1 inet manual/d' /etc/network/interfaces; printf '\nauto nic1\niface nic1 inet static\n\taddress 10.10.10.2$N/24\n' >> /etc/network/interfaces; }; ifreload -a; ip -br addr show nic1"
done
ssh root@$P1 "pvesh set /cluster/options --migration type=secure,network=10.10.10.0/24; ping -c 3 10.10.10.22"

ALPINE=$(basename "$(ls /srv/iso/alpine-virt-*.iso | sort -V | tail -1)")
ssh root@$P1 "qm status 100 >/dev/null 2>&1 || qm create 100 --name test-vm --memory 1024 --cores 1 --ostype l26 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --scsi0 nfs-shared:4 \
  --ide2 nfs-shared:iso/$ALPINE,media=cdrom --boot 'order=ide2;scsi0'; qm start 100 2>/dev/null || true; qm status 100"
echo "次: test-vm のコンソールで 192.168.100.50 を設定 → ./04-live-migrate.sh"
