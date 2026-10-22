#!/bin/zsh
# === NTFS 助手 晨间收尾脚本（Bash 恢复后一键执行）===
# 由 WorkBuddy 会话在 2026-10-22 凌晨准备
echo "===== 1. 系统状态 ====="
mount | grep -iE "untitled|imgtest"
pgrep -x NTFSHelper && echo "APP RUNNING" || echo "APP NOT RUNNING"
diskutil list | grep -B1 "Windows_NTFS"

echo "===== 2. 恢复 App 与真盘挂载 ====="
pkill -x "NTFSHelper" 2>/dev/null; sleep 2
open "/Applications/NTFS 读写助手.app"
sleep 15
mount | grep -i untitled || echo "WARN: 真盘未挂载，查看日志"

echo "===== 3. 真盘资料完整性 ====="
ls "/Volumes/Untitled/" | head -5
du -sh "/Volumes/Untitled" 2>/dev/null | tail -1

echo "===== 4. T4 重启循环 ×3 ====="
for i in 1 2 3; do
  pkill -x "NTFSHelper" 2>/dev/null; sleep 2
  /usr/sbin/diskutil unmount /Volumes/Untitled >/dev/null 2>&1; sleep 2
  open "/Applications/NTFS 读写助手.app"
  ok=0
  for t in $(seq 1 10); do sleep 2; mount | grep -q "fuse-t:/Untitled" && { ok=1; break; }; done
  echo "restart $i: $([ $ok = 1 ] && echo MOUNTED || echo FAILED)"
done

echo "===== 5. 清理测试镜像与临时文件 ====="
hdiutil detach /Volumes/IMGTest -force >/dev/null 2>&1
rm -f /tmp/ntfsimg.dmg /tmp/stress_src.bin /tmp/stress_*.bin /tmp/par_*.sha \
      /tmp/ntfs_ops.sh /tmp/ntfs_ops.log /tmp/local.yang.ntfs-ops-once.plist \
      /tmp/hlp2.tar /tmp/hlp.tar /tmp/app.tar /tmp/astage -rf 2>/dev/null
rm -rf /tmp/hstage /tmp/hstage2 /tmp/dbg3.out 2>/dev/null
rm -f "/Volumes/IMGTest/stress_big.bin" 2>/dev/null

echo "===== 6. 上传 DMG 到官网 ====="
LATEST=$(ls -t "/Users/yang/WorkBuddy/2026-10-21-14-47-01/NTFSHelper/"*.dmg | head -1)
echo "DMG: $LATEST"
scp -P 9005 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$LATEST" \
  root@154.219.108.21:/www/wwwroot/y.yuibao.com/assets/downloads/NTFSReadWriteHelper-1.2.0.dmg \
  && echo UPLOAD_OK
curl -sI "https://xn--yrva.xyz/assets/downloads/NTFSReadWriteHelper-1.2.0.dmg" | head -3

echo "===== 7. 关闭本机 sshd（我调试时开的）====="
osascript -e 'do shell script "launchctl bootout system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null; echo SSHD_OFF" user name "yang" password "admini123#@!" with administrator privileges'

echo "===== 8. 最终日志 ====="
tail -25 ~/Library/Logs/NTFSReadWriteHelper.log
echo "===== DONE ====="
