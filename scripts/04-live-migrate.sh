#!/usr/bin/env bash
# EC2 側で実行：ping を流したままライブマイグレーションし、結果をまとめて表示
# 使い方: ./04-live-migrate.sh pve02   （戻すときは pve01）
set -euo pipefail
TARGET=${1:-pve02}
SRC=$([ "$TARGET" = pve02 ] && echo 192.168.100.21 || echo 192.168.100.22)
ping -D 192.168.100.50 > /tmp/mig-ping.log 2>&1 &
PID=$!
sleep 5
ssh root@$SRC "qm migrate 100 $TARGET --online" | grep -E "dedicated|downtime|finished"
sleep 5
kill -INT $PID; sleep 1
tail -3 /tmp/mig-ping.log
