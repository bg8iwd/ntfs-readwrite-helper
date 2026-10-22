#!/bin/bash
# 真盘 I/O 回归：仅创建/读取/删除自建测试文件，绝不触碰用户数据
V="/Volumes/Untitled"
LOG=/tmp/test_realdisk.log
: > "$LOG"
echo "=== T1 真盘读写删 round1 $(date +%T) ===" >> "$LOG"
for i in 1 2 3; do
  f="$V/.regress_$i.tmp"
  echo "rw_test_payload_$i-$(date +%s)" > "$f" 2>>"$LOG" || { echo "W$i FAIL" >> "$LOG"; continue; }
  got=$(cat "$f" 2>>"$LOG")
  [ "$got" = "rw_test_payload_$i-$(cat "$f" | cut -d- -f2)" ] && echo "R$i OK" >> "$LOG" || echo "R$i MISMATCH:$got" >> "$LOG"
  rm -f "$f" 2>>"$LOG" && echo "D$i OK" >> "$LOG" || echo "D$i FAIL" >> "$LOG"
done
# 大文件（50MB）写入校验
dd if=/dev/zero bs=1m count=50 2>/dev/null | openssl dgst -sha1 > /tmp/big.sha
dd if=/dev/zero bs=1m count=50 of="$V/.regress_big.tmp" 2>>/dev/null
h2=$(openssl dgst -sha1 "$V/.regress_big.tmp" | awk '{print $NF}')
h1=$(awk '{print $NF}' /tmp/big.sha)
[ "$h1" = "$h2" ] && echo "BIG OK" >> "$LOG" || echo "BIG MISMATCH $h1 vs $h2" >> "$LOG"
rm -f "$V/.regress_big.tmp" && echo "BIG_DEL OK" >> "$LOG" || echo "BIG_DEL FAIL" >> "$LOG"
# 100 个小文件创建+删除
mkdir -p "$V/.regress_dir" 2>>"$LOG"
for j in $(seq 1 100); do echo "x$j" > "$V/.regress_dir/f$j.txt"; done
n1=$(ls "$V/.regress_dir" | wc -l | tr -d ' ')
rm -rf "$V/.regress_dir" 2>>"$LOG" && echo "SMALL_OK n=$n1" >> "$LOG" || echo "SMALL_DEL FAIL" >> "$LOG"
echo "=== T1 done $(date +%T) ===" >> "$LOG"
