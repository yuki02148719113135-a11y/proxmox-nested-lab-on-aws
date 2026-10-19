#!/usr/bin/env bash
# Mac 側で実行：VNC(5901/5902) と SOCKS(1080) のトンネルを1本だけ張る
# 使い方: ./mac-tunnel.sh <パブリックIP> [鍵ファイル]
set -euo pipefail
HOST=${1:?パブリックIPを指定}
KEY=${2:-$HOME/.ssh/test-ec2-key.pem}
pkill -f "ssh .*$HOST" 2>/dev/null || true
sleep 1
ssh -f -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -i "$KEY" \
  -L 5901:127.0.0.1:5901 -L 5902:127.0.0.1:5902 -D 1080 ubuntu@"$HOST"
sleep 2
lsof -nP -iTCP:1080 -sTCP:LISTEN
echo "OK: VNC localhost:1 / localhost:2、Firefox は SOCKS v5 127.0.0.1:1080"
