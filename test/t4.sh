#!/bin/bash
# 诊断：前台跑 ntfs-3g 抓报错
/usr/sbin/diskutil unmount force disk6s1 2>&1
/bin/mkdir -p "/Volumes/Untitled 2"
/usr/local/lib/ntfs-rw-helper/bin/ntfs-3g /dev/disk6s1 "/Volumes/Untitled 2" -o "volname=Untitled,local,noowners,noatime" 2>&1 &
NPID=$!
for i in $(seq 1 20); do
  sleep 1
  if mount | grep -qF "on /Volumes/Untitled 2 ("; then
    echo "MOUNTED after ${i}s"
    break
  fi
  # 检查进程是否已退出
  if ! kill -0 $NPID 2>/dev/null; then
    echo "ntfs-3g exited early (after ${i}s)"
    break
  fi
done
echo "=== mount ==="
mount | grep -i untitled
echo "=== fuse-t 相关进程 ==="
/bin/ps aux 2>/dev/null | grep -iE "fuse-t|ntfs" | grep -v grep
wait $NPID 2>/dev/null
echo "ntfs3g_final_exit=$?"
