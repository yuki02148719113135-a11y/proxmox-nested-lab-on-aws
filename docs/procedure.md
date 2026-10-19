# 構築手順書

AWSベアメタルEC2 1台の上にKVMでProxmox VEを2台立ててクラスタにし、テストVMを止めずに隣のノードへライブマイグレーションするまでの手順です。
元の手順書に、**実際の作業で詰まった箇所の修正を反映**しています（変更点は「⚠ 実作業での修正」と表記）。

- ゴール：Web UIで2ノードのクラスタが見え、pingを打ち続けたままテストVMが pve01 → pve02 へ移動すること
- 所要時間の目安：2〜3時間
- コスト：ベアメタルは1時間あたり数ドル。終わったら必ず「後片付け」まで実施

## 事前準備

- [ ] EC2用キーペア（以下 `<key>.pem`、Macの `~/.ssh/` に置き `chmod 600`）
- [ ] 自宅IPからのSSH(22)だけを許可するセキュリティグループ
- [ ] Mac に VNCビューア（TigerVNC など）と Firefox

## パラメータ

| 名前 | 役割 | 管理IP | 移行用IP | vCPU / メモリ / ディスク |
|---|---|---|---|---|
| kvm-host | Ubuntu（KVM・NFS・DNS・NTP） | 192.168.100.1 | 10.10.10.1 | ベアメタル全体 |
| pve01 | Proxmox VEノード | 192.168.100.21 | 10.10.10.21 | 8 / 16GB / 64GB |
| pve02 | Proxmox VEノード | 192.168.100.22 | 10.10.10.22 | 8 / 16GB / 64GB |
| test-vm | 移行させるテストVM | 192.168.100.50 | ― | 1 / 1GB / 4GB |

- ドメイン：`lab.local` ／ クラスタ名：`lab-cluster` ／ NFS：`192.168.100.1:/srv/nfs/pve`（ストレージ名 `nfs-shared`）
- rootパスワードは2台で揃える。⚠ **記号なしの英数字にする**（VNC経由の入力でキー配列がずれ、記号が別の文字で登録されるため）

---

## 手順1：ベアメタルEC2を起動

- AMI：Ubuntu Server 24.04 LTS（x86_64）
- インスタンスタイプ：`m5zn.metal`（48 vCPU / 192GiB）
- ストレージ：ルートを gp3 200GB
- 起動に5〜10分かかる

```bash
ssh -i ~/.ssh/<key>.pem ubuntu@<パブリックIP>
ls -l /dev/kvm
lscpu | grep -i vmx
```

ISOのダウンロード：

```bash
sudo mkdir -p /srv/iso && cd /srv/iso
curl -s https://enterprise.proxmox.com/iso/ | grep -o 'proxmox-ve_[0-9.]*-[0-9]*\.iso' | sort -u
sudo wget https://enterprise.proxmox.com/iso/<上で確認したファイル名>   # 今回は proxmox-ve_9.2-1.iso
sudo wget <Alpine virt x86_64 ISOのURL>                                 # 今回は alpine-virt-3.24.2-x86_64.iso
ls -lh /srv/iso
```

## 手順2：KVM・ネットワーク・NFS

```bash
sudo apt update
sudo apt install -y qemu-system-x86 libvirt-daemon-system virtinst nfs-kernel-server chrony tmux libguestfs-tools

echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
sudo modprobe -r kvm_intel && sudo modprobe kvm_intel
cat /sys/module/kvm_intel/parameters/nested   # Y
```

⚠ 実作業での修正：SSHが切れても作業が消えないよう、EC2では最初に `tmux new -A -s lab` で入ってから作業する。

### 管理ネットワーク labnet（NAT＋DNS）

```bash
cat <<'XML' > labnet.xml
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
sudo virsh net-define labnet.xml && sudo virsh net-start labnet && sudo virsh net-autostart labnet
```

### 移行用ネットワーク vmnet（閉域）

```bash
cat <<'XML' > vmnet.xml
<network>
  <name>vmnet</name>
  <bridge name='virbr11' stp='on' delay='0'/>
  <ip address='10.10.10.1' netmask='255.255.255.0'/>
</network>
XML
sudo virsh net-define vmnet.xml && sudo virsh net-start vmnet && sudo virsh net-autostart vmnet
```

### 名前解決・NTP・NFS

```bash
grep -q pve01.lab.local /etc/hosts || printf "192.168.100.21 pve01.lab.local pve01\n192.168.100.22 pve02.lab.local pve02\n" | sudo tee -a /etc/hosts

echo "allow 192.168.100.0/24" | sudo tee -a /etc/chrony/chrony.conf
sudo systemctl restart chrony

sudo mkdir -p /srv/nfs/pve && sudo chmod 777 /srv/nfs/pve
echo "/srv/nfs/pve 192.168.100.0/24(rw,sync,no_root_squash,no_subtree_check)" | sudo tee -a /etc/exports
sudo exportfs -ra && sudo exportfs -v
```

## 手順3：Proxmox VE 2台をインストール

⚠ 実作業での修正：ISOのファイル名は**自動で拾う**（仮の名前のまま実行して `No bootable device` になったため）。`--boot cdrom,hd` を明示する。

```bash
ISO=$(ls /srv/iso/proxmox-ve_*.iso | sort -V | tail -1); echo "ISO=$ISO"
IMG=/var/lib/libvirt/images

for N in 1 2; do
  sudo qemu-img create -f qcow2 $IMG/pve0$N.qcow2 64G
  sudo virt-install --name pve0$N --memory 16384 --vcpus 8 \
    --cpu host-passthrough --machine q35 --osinfo generic \
    --disk path=$IMG/pve0$N.qcow2,bus=virtio \
    --network network=labnet,model=virtio \
    --network network=vmnet,model=virtio \
    --cdrom "$ISO" --boot cdrom,hd \
    --graphics vnc,listen=127.0.0.1,port=590$N --noautoconsole
done

sudo virsh domblklist pve01 --details   # cdrom に ISO が入っていること
sudo virsh vncdisplay pve02             # 127.0.0.1:2
```

### Mac からトンネルを張る（**Macのターミナル**で実行）

⚠ 実作業での修正：`-f -N` でバックグラウンド化、`ExitOnForwardFailure` で失敗を即検知。張り直す前に古いトンネルを必ず止める。

```bash
pkill -f "ssh .*<パブリックIP>"; sleep 1
ssh -f -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes \
  -i ~/.ssh/<key>.pem \
  -L 5901:127.0.0.1:5901 -L 5902:127.0.0.1:5902 -D 1080 \
  ubuntu@<パブリックIP>
lsof -nP -iTCP:1080 -sTCP:LISTEN    # ssh が LISTEN していればOK
```

- VNC：TigerVNC で `localhost:1`（pve01）／`localhost:2`（pve02）
- Firefox：設定 → ネットワーク設定 → 手動 → **SOCKSホスト** `127.0.0.1` / `1080` / SOCKS v5、HTTPプロキシ欄は空、「SOCKS v5 を使用するときは DNS もプロキシーを使用する」にチェック

### インストーラ（2台とも）

| 項目 | pve01 | pve02 |
|---|---|---|
| Management Interface | 1本目のNIC（`nic0`） | 1本目のNIC（`nic0`） |
| Hostname (FQDN) | pve01.lab.local | pve02.lab.local |
| IP Address (CIDR) | 192.168.100.21/24 | 192.168.100.22/24 |
| Gateway / DNS | 192.168.100.1 | 192.168.100.1 |

⚠ 実作業での修正：インストール後の再起動で VM は `shut off` になる。CD を外してから起動する。

```bash
sudo virsh change-media pve02 sda --eject --config
sudo virsh start pve02
sleep 90
curl -sk -o /dev/null -w "8006応答=%{http_code}\n" https://192.168.100.22:8006/   # 200
```

Web UI：`https://pve01.lab.local:8006`（開けなければ `https://192.168.100.21:8006`）、ユーザー `root`、レルム **Linux PAM**。

## 手順4：クラスタ作成

Web UI：pve01 で「データセンター」→「クラスタ」→「クラスタを作成」（`lab-cluster`、リンク0 `192.168.100.21`）→「Join情報」→ コピー。
pve02 で「クラスタに参加」→ 貼り付け・**pve01のrootパスワード**・リンク0 `192.168.100.22`。

CLI でやる場合（EC2から）：

```bash
ssh root@192.168.100.21 "pvecm create lab-cluster --link0 192.168.100.21"
ssh -t root@192.168.100.22 "pvecm add 192.168.100.21 --link0 192.168.100.22"
ssh root@192.168.100.21 "pvecm status | grep -E 'Nodes|Quorate'; pvecm nodes"   # Nodes: 2 / Quorate: Yes
```

⚠ 実作業での修正：Web UI の参加ログは `Request addition of this node` で止まって見えるが、裏では完了していることがある。**再実行せず** `pvecm status` で確認する。

## 手順5：共有ストレージと移行用ネットワーク

```bash
# パスワード入力を省略（任意）
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id root@192.168.100.21; ssh-copy-id root@192.168.100.22

# NFS をクラスタ共通ストレージとして登録（pve01 で1回でOK）
ssh root@192.168.100.21 "pvesm add nfs nfs-shared --server 192.168.100.1 --export /srv/nfs/pve --content images,iso; pvesm status"

# Alpine ISO を NFS に置く
sudo mkdir -p /srv/nfs/pve/template/iso
sudo cp /srv/iso/alpine-virt-*.iso /srv/nfs/pve/template/iso/
```

⚠ 実作業での修正：Proxmox 9 では NIC 名が `enp2s0` ではなく **`nic0` / `nic1`** だった。

```bash
for N in 1 2; do
  ssh root@192.168.100.2$N "grep -q 'address 10.10.10' /etc/network/interfaces || { sed -i '/^iface nic1 inet manual/d' /etc/network/interfaces; printf '\nauto nic1\niface nic1 inet static\n\taddress 10.10.10.2$N/24\n' >> /etc/network/interfaces; }; ifreload -a; ip -br addr show nic1"
done

ssh root@192.168.100.21 "pvesh set /cluster/options --migration type=secure,network=10.10.10.0/24; ping -c 3 10.10.10.22"
```

## 手順6：テストVMでライブマイグレーション

```bash
ssh root@192.168.100.21 "qm create 100 --name test-vm --memory 1024 --cores 1 --ostype l26 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --scsi0 nfs-shared:4 \
  --ide2 nfs-shared:iso/alpine-virt-3.24.2-x86_64.iso,media=cdrom --boot 'order=ide2;scsi0' \
  && qm start 100 && qm status 100"
```

test-vm のコンソール（root・パスワードなし）：

```sh
ip link set eth0 up
ip addr add 192.168.100.50/24 dev eth0
ip route add default via 192.168.100.1
ping 192.168.100.1
```

移行（Web UI：test-vm 右上の「**マイグレート**」→ ターゲット `pve02`。起動中のVMはモードが自動で「オンライン」になり変更不可）。
CLI で、ping を流したまま移行して結果を1画面にまとめる場合：

```bash
ping -D 192.168.100.50 > /tmp/mig-ping.log 2>&1 &
sleep 5
ssh root@192.168.100.21 "qm migrate 100 pve02 --online" | grep -E "dedicated|downtime|finished"
sleep 5; kill -INT %1; sleep 1
tail -3 /tmp/mig-ping.log
```

成功の目安：`use dedicated network address ... (10.10.10.22)`、`downtime` が数十〜数百ms、`migration finished successfully`、ping の packet loss がほぼ0%。

## 後片付け（課金停止）

```bash
# Mac
pkill -f "ssh .*<パブリックIP>"
```

1. EC2 →「インスタンスの状態」→「**インスタンスを終了**」（停止ではない）。ベアメタルは終了完了まで5〜10分
2. 「ボリューム」画面でルートEBSが消えたことを確認（使用中のボリュームは削除できない。インスタンス終了で自動削除される）
3. 翌日、請求ダッシュボードを確認
