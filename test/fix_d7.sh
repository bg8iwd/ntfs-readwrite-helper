#!/bin/bash
# 杀掉可能持有 disk7s1 内核 claim 的遗留进程，然后重试挂载
echo "=== kill leftovers ==="
killall -9 fskit_helper 2>/dev/null && echo "fskit_helper killed"
killall -9 com.apple.fskit.exfat 2>/dev/null
killall -9 com.apple.fskit.msdos 2>/dev/null
killall -9 diskutil 2>/dev/null
echo "=== wait 3s ==="
sleep 3
echo "=== retry ntfs-3g ==="
rmdir /Volumes/Untitled 2>/dev/null
mkdir -p /Volumes/Untitled
/usr/local/lib/ntfs-rw-helper/bin/ntfs-3g /dev/disk7s1 /Volumes/Untitled -o volname=Untitled,local,noowners,noatime </dev/null >/tmp/ntfs3g_mount.log 2>&1 &
MPID=$!
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  sleep 2
  if mount | grep -Fq "on /Volumes/Untitled (" ; then echo "MOUNTED after $((i*2))s (pid $MPID)"; break; fi
  if ! kill -0 $MPID 2>/dev/null; then echo "ntfs-3g exited rc=?" ; break; fi
done
mount | grep -i untitled
echo "=== ntfs3g log ==="
head -5 /tmp/ntfs3g_mount.log
echo "=== sample if still stuck ==="
if ! mount | grep -Fq "on /Volumes/Untitled ("; then
  if kill -0 $MPID 2>/dev/null; then
    sample $MPID 2 2>/dev/null | grep -A 12 "Call graph" | head -16
  fi
fi
echo "=== DONE ==="
