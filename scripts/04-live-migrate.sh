#!/usr/bin/env bash
# EC2 側で実行：ping を流したままライブマイグレーションし、結果をまとめて表示
# 使い方: ./04-live-migrate.sh pve02   （戻すときは pve01）
set -euo pipefail
TARGET=${1:-pve02}
case "$TARGET" in
  pve02) SRC=192.168.100.21 ;;
  pve01) SRC=192.168.100.22 ;;
  *) echo "移行先は pve01 か pve02 を指定してください"; exit 1 ;;
esac
LOG=/tmp/mig-ping.log

ping -D 192.168.100.50 > "$LOG" 2>&1 &
PID=$!
# 途中で失敗しても ping を必ず止めて統計を表示する
trap 'kill -INT $PID 2>/dev/null || true; sleep 1; echo "--- ping ---"; tail -3 "$LOG"' EXIT

sleep 5
ssh root@$SRC "qm migrate 100 $TARGET --online" | grep -E "dedicated|downtime|finished" || true
sleep 5
