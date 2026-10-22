#!/bin/bash
# 诊断 disk7s1 的内核层打开阻塞问题
echo "=== diskutil info (8s timeout) ==="
perl -e 'alarm 8; exec @ARGV or die' /usr/sbin/diskutil info disk7s1 > /tmp/di.txt 2>&1
echo "rc=$?"
grep -E "Mounted|Read-Only|Device /|Writable" /tmp/di.txt | head -5
echo "=== diskutil activity (8s timeout) ==="
perl -e 'alarm 8; exec @ARGV or die' /usr/sbin/diskutil activity > /tmp/da.txt 2>&1
echo "rc=$?"
head -10 /tmp/da.txt
echo "=== unmountDisk force (12s timeout) ==="
perl -e 'alarm 12; exec @ARGV or die' /usr/sbin/diskutil unmountDisk force disk7 > /tmp/ud.txt 2>&1
echo "rc=$?"
tail -2 /tmp/ud.txt
echo "=== retry ntfs-3g mount with 20s wait ==="
rmdir /Volumes/Untitled 2>/dev/null
mkdir -p /Volumes/Untitled
/usr/local/lib/ntfs-rw-helper/bin/ntfs-3g /dev/disk7s1 /Volumes/Untitled -o volname=Untitled,local,noowners,noatime </dev/null >/tmp/ntfs3g_mount.log 2>&1 &
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 2
  if mount | grep -Fq "on /Volumes/Untitled ("; then echo "MOUNTED after $((i*2))s"; break; fi
done
mount | grep -i untitled
echo "=== ntfs3g log ==="
head -5 /tmp/ntfs3g_mount.log
echo "=== DONE ==="
