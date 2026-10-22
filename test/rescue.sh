#!/bin/bash
# 清理僵尸挂载并让 App 重新挂载（一次性救援）
LOG=/tmp/rescue.out
: > "$LOG"
echo "=== STEP1 kill zombie ntfs-3g ===" >> "$LOG"
ps aux | grep "ntfs-3g" | grep -v grep | awk '{print $2, $11, $12}' >> "$LOG"
for p in $(ps aux | grep "ntfs-3g /dev/disk5" | grep -v grep | awk '{print $2}'); do
  kill -9 "$p" 2>>"$LOG" && echo "killed $p" >> "$LOG"
done
sleep 2
echo "=== STEP2 unmount zombie (watchdog 10s) ===" >> "$LOG"
( /usr/sbin/diskutil unmount force /Volumes/Untitled >> "$LOG" 2>&1 ) &
DU=$!
for i in $(seq 1 10); do
  sleep 1
  if ! kill -0 $DU 2>/dev/null; then break; fi
done
if kill -0 $DU 2>/dev/null; then
  echo "diskutil stuck -> kill it, fallback umount -f" >> "$LOG"
  kill -9 $DU 2>/dev/null
  /sbin/umount -f /Volumes/Untitled >> "$LOG" 2>&1
fi
sleep 1
echo "--- mount after cleanup ---" >> "$LOG"
/sbin/mount | grep -i untitled >> "$LOG" 2>&1 || echo "no untitled mount (good)" >> "$LOG"
echo "=== STEP3 check path access ===" >> "$LOG"
/bin/ls /Volumes/Untitled > /dev/null 2>>"$LOG" && echo "PATH_ACCESSIBLE" >> "$LOG" || echo "PATH_NOT_ACCESSIBLE" >> "$LOG"
echo "=== STEP4 done, wait for app ===" >> "$LOG"
echo FINISHED >> "$LOG"
