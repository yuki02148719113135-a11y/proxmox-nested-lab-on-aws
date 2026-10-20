# 実際にハマったエラーと解決方法

今回の構築で実際に遭遇したエラーを、起きた順にまとめました。
**半分以上が「どのターミナルで打っているか」と「SSHトンネル」の問題**で、Proxmox自体の問題は少なかったです。

## 早見表

| # | 症状 | 原因 | 解決 |
|---|---|---|---|
| 1 | VCSAが入手できない | Broadcomのエンタイトルメントが必要 | Proxmox VE に切り替え |
| 2 | `Identity file ... not accessible` | トンネルのコマンドを**EC2側**で打った | **Mac側**で打つ |
| 3 | 急に全部つながらなくなる | SSHが無通信／スリープで切断 | `ServerAliveInterval=30`、`-f -N`、`tmux` |
| 4 | VNC 5901は見えるが5902がつながらない | Mac側にトンネルが残っていない／古いものが掴んでいた | 古いトンネルを止めて張り直し |
| 5 | VNCで `No bootable device` | ISOのパスが仮の名前のまま | ISO名を自動取得して作り直し |
| 6 | インストール後に ping も 8006 も応答なし | 初回再起動で VM が `shut off` | CDを外して `virsh start` |
| 7 | `bind [::1]:5902: Address already in use` | 古い5902専用トンネルが生きていた | `pkill` で止めてから張り直し |
| 8 | Firefox「サーバーが見つかりませんでした」 | SOCKS DNS 設定／名前解決 | DNSもプロキシ経由にチェック、IPで開く |
| 9 | Firefox「プロキシーサーバーへの接続を拒否されました」 | Mac側の 1080 トンネルが落ちていた | `ssh -f -N ... -D 1080` で張り直し |
| 10 | pve02 にログインできない | VNC入力でキー配列がずれ、パスワードが別物に | `virt-customize` で英数字パスワードにリセット |
| 11 | 「Join情報」が押せない | pve01 でクラスタ未作成 | 先に「クラスタを作成」 |
| 12 | 参加ログが `Request addition of this node` で止まる | 証明書再生成でUIのログが途切れるだけ | `pvecm status` で確認（実は成功） |
| 13 | 手順書の NIC 名と違う | Proxmox 9 は `nic0` / `nic1` | 実名を確認して設定 |
| 14 | 「移行」ボタンがない | UI表記が「マイグレート」 | 同じ機能。モードは自動で「オンライン」 |
| 15 | ボリュームが削除できない | インスタンスにアタッチ中 | インスタンスを「終了」すると自動削除 |
| 16 | `Package 'qemu-kvm' has no installation candidate` | Ubuntu 26.04 では `qemu-kvm` が仮想パッケージ | `qemu-system-x86` を指定 |

---

## 1. vCenter（VCSA）が入手できない

当初はVMware（vCenter＋vMotion）で組む予定でした。

- VCSAは Broadcom のエンタイトルメントがないとダウンロードできない（無料版なし）
- 無料版 ESXi は vCenter に登録できず、評価モードにも切り替えられない

**対応**：無料で「クラスタ一元管理＋ライブマイグレーション」まで同じ構成で試せる Proxmox VE に変更。EC2・KVM・NFSの部分はそのまま流用できました。

## 2. `Identity file /home/ubuntu/.ssh/... not accessible`

```
ubuntu@ip-172-31-20-91:~$ ssh ... -L 5901:... -D 1080 ubuntu@<パブリックIP>
Warning: Identity file /home/ubuntu/.ssh/test-ec2-key.pem not accessible: No such file or directory.
```

**原因**：トンネル用のコマンドを、EC2にログインしたウィンドウで打っていた。鍵はMacにしかない。**2回やりました。**

**対応**：ターミナルを役割で分ける。プロンプトで見分ける。

| ウィンドウ | プロンプト | 用途 |
|---|---|---|
| Mac | `user@MacBook-Pro ~ %` | トンネル（`-L` / `-D` 付きの ssh） |
| EC2 | `ubuntu@ip-...:~$` | virsh / qm / pvecm などの作業 |

## 3. SSH が突然切れて全部つながらなくなる

SSHが切れると、作業ウィンドウ・VNC・Firefox（SOCKS）が全部同時に落ちます。

**対応**
- `-o ServerAliveInterval=30` を付ける
- トンネルは `ssh -f -N` でバックグラウンド化（ウィンドウを閉じても切れない）
- EC2 の作業は `tmux new -A -s lab` の中で行い、再接続後に同じコマンドで復帰
- Mac をスリープさせない

## 4. VNC 5901 はつながるのに 5902 がつながらない

EC2 側は正常でした。

```
$ sudo virsh vncdisplay pve02
127.0.0.1:2
$ sudo ss -lntp | grep 590
LISTEN ... 127.0.0.1:5901 ... qemu-system-x86
LISTEN ... 127.0.0.1:5902 ... qemu-system-x86
```

Mac 側を調べると、トンネルが1本もありませんでした。

```
% lsof -nP -iTCP:5902 -sTCP:LISTEN
（何も出ない）
% nc -vz 127.0.0.1 5902
nc: connectx to 127.0.0.1 port 5902 (tcp) failed: Connection refused
```

**切り分けのコツ**：まず素の SSH が通るかを確認 → 転送だけを `-v` 付きで張る。

```bash
ssh -i ~/.ssh/<key>.pem -o ConnectTimeout=10 ubuntu@<パブリックIP> "echo SSH_OK"; echo "exit=$?"
ssh -N -v -o ExitOnForwardFailure=yes -i ~/.ssh/<key>.pem -L 5902:127.0.0.1:5902 ubuntu@<パブリックIP>
# → "Local forwarding listening on 127.0.0.1 port 5902." が出れば成功
```

TigerVNC は `localhost:5902` を「ディスプレイ5902」と解釈することがあるので、**`localhost:2`** と入力するのが確実です。

## 5. VNC で `No bootable device`

**原因**：`virt-install` の `ISO=` に手順書の仮のファイル名を入れたまま実行し、CDが空だった。

**対応**：実ファイル名を自動取得し、ブート順も明示して作り直し。

```bash
ISO=$(ls /srv/iso/proxmox-ve_*.iso | sort -V | tail -1); echo "ISO=$ISO"
sudo virsh destroy pve02; sudo virsh undefine pve02
sudo rm -f /var/lib/libvirt/images/pve02.qcow2
# ... virt-install に --cdrom "$ISO" --boot cdrom,hd
sudo virsh domblklist pve02 --details   # cdrom 行に ISO が出ることを確認
```

## 6. インストール後に応答しない

```
$ sudo virsh domstate pve02
shut off
disk size: 4.91 GiB
From 192.168.100.1 icmp_seq=1 Destination Host Unreachable
8006応答=000
```

**原因**：インストール自体は完了（ディスク 4.91GiB）。`virt-install` で作った VM は初回の再起動で電源オフになる。

**対応**

```bash
sudo virsh change-media pve02 sda --eject --config
sudo virsh start pve02
```

90秒後に `8006応答=200`。

## 7. `bind [::1]:5902: Address already in use`

```
bind [::1]:5902: Address already in use
channel_setup_fwd_listener_tcpip: cannot listen to port: 5902
Could not request local forwarding.
```

**原因**：切り分けで張った「5902専用トンネル」が別ウィンドウで生きていた。

**対応**：古いトンネルを全部止めてから張り直す。

```bash
pkill -f "ssh .*<パブリックIP>"; sleep 1
lsof -nP -iTCP:5902 -sTCP:LISTEN   # 空ならOK
```

## 8. Firefox「サーバーが見つかりませんでした」

`pve01.lab.local` を引けていない時のエラー。

**対応**
- Firefox の「SOCKS v5 を使用するときは DNS もプロキシーを使用する」にチェック
- EC2 の `/etc/hosts` に `pve01.lab.local` を登録
- 切り分けとして `https://192.168.100.21:8006` で開く

## 9. Firefox「プロキシーサーバーへの接続を拒否されました」

Firefox のプロキシ設定は効いているが、Mac 側の 1080 番に誰もいない状態。

**対応**

```bash
pkill -f "ssh -f -N.*<パブリックIP>"; sleep 1   # トンネルだけを止める
ssh -f -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -i ~/.ssh/<key>.pem \
  -L 5901:127.0.0.1:5901 -L 5902:127.0.0.1:5902 -D 1080 ubuntu@<パブリックIP>
lsof -nP -iTCP:1080 -sTCP:LISTEN
# ssh ... 127.0.0.1:1080 (LISTEN) が出ればOK
```

Mac から直接確認する方法：

```bash
curl -sk --socks5-hostname 127.0.0.1:1080 -o /dev/null -w "%{http_code}\n" https://pve01.lab.local:8006/
```

設定でよくある間違いは、**HTTPプロキシ欄に localhost:1080 を入れてしまう**こと。入れるのは SOCKS ホスト欄。

## 10. pve02 にログインできない

**原因（推定）**：VNC 経由でインストーラにパスワードを入力した際、キー配列のずれで記号が別の文字として登録された。

**確認**：ブラウザを使わず API で直接確かめる。

```bash
curl -sk -o /dev/null -w "%{http_code}\n" -d 'username=root@pam' \
  --data-urlencode 'password=<パスワード>' https://192.168.100.22:8006/api2/json/access/ticket
# 200 = 正しい / 401 = 違う
```

**対応**：VM を止めて、ディスクのパスワードを直接書き換える（クラスタ参加前なら安全）。

```bash
sudo apt install -y libguestfs-tools
sudo virsh shutdown pve02; sleep 40; sudo virsh destroy pve02 2>/dev/null
sudo virt-customize -a /var/lib/libvirt/images/pve02.qcow2 --root-password password:<英数字のパスワード>
sudo virsh start pve02
```

レルムが「Proxmox VE authentication server」のままだと正しいパスワードでも入れないので、**Linux PAM** を選ぶ。

## 11. 「Join情報」が押せない

pve01 でクラスタを作る前は、ボタンがグレーアウトしている。先に「クラスタを作成」。

## 12. クラスタ参加ログが止まって見える

```
Establishing API connection with host '192.168.100.21'
Login succeeded.
check cluster join API version
No cluster network links passed explicitly, fallback to local node IP '192.168.100.22'
Request addition of this node
```

ここで数分止まり、その間に EC2 の SSH も切れました。

**原因**：参加処理中に pve02 の証明書と Web サービスが再起動するため、ブラウザのログ表示が更新されなくなるだけ。

**対応**：再実行やノードの作り直しはせず、状態を確認。

```
$ ssh root@192.168.100.21 "pvecm status | grep -E 'Nodes|Quorate'; pvecm nodes"
Nodes:            2
Quorate:          Yes
         1          1 pve01 (local)
         2          1 pve02
```

→ 実は成功していました。

## 13. NIC 名が手順書と違う

手順書では `enp1s0` / `enp2s0` を想定していましたが、Proxmox VE 9 では次のようになっていました。

```
nic0  UP    52:54:00:...
nic1  DOWN  52:54:00:...
```

`nic1` に `10.10.10.2x/24` を設定して解決。

## 14. 「移行」ボタンが見つからない

日本語 UI では「**マイグレート**」と表記されていました。起動中の VM では、モードは自動で「オンライン」になり、変更できない（灰色）のが正常。

## 15. EBS ボリュームが削除できない

インスタンスにアタッチされている（使用中）ボリュームは削除できない。インスタンスを「**終了**」すれば、ルートボリュームは自動で削除される。ベアメタルは終了完了まで5〜10分かかる。

## 16. `qemu-kvm` がインストールできない

```
Package qemu-kvm is a virtual package provided by:
  qemu-system-x86-hwe ...
  qemu-system-x86 ...
Error: Package 'qemu-kvm' has no installation candidate
```

**原因**：AMI が Ubuntu 26.04 で、`qemu-kvm` が実体のない仮想パッケージになっていた。エラーで `apt install` 全体が止まり、libvirt なども入っていなかった。

**対応**：`qemu-system-x86` を明示して入れ直す。

```bash
sudo apt install -y qemu-system-x86 libvirt-daemon-system virtinst nfs-kernel-server chrony tmux
sudo virsh list --all   # エラーなく空の表が出ればOK
```

---

## 教訓

1. **ターミナルはプロンプトで見分ける**。Mac で打つか EC2 で打つかで結果が全く違う
2. **トンネルは1本だけ**。張り直す前に `pkill` で古いものを止め、`lsof` で確認
3. **「つながらない」は層ごとに切り分ける**：SSH → ポート転送 → アプリ（VNC / Firefox）→ 名前解決
4. **画面の表示を信じすぎない**。止まって見えても、CLI（`pvecm status`、`virsh domstate`、`curl`）で実際の状態を確認
5. **VNC 経由のパスワードは英数字のみ**にする
