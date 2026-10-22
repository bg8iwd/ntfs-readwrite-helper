#!/bin/bash
# 检查 sudoers 白名单 + 清理僵尸挂载
echo "=== sudoers ==="
ls -la /etc/sudoers.d/ 2>&1
cat /etc/sudoers.d/ntfs-rw-helper 2>&1
echo "=== 清理僵尸 NFS 挂载 ==="
/usr/sbin/diskutil unmount force "/Volumes/Untitled"
echo "untitled exit=$?"
/usr/sbin/diskutil unmount force "/Volumes/Untitled 1"
echo "untitled1 exit=$?"
echo "=== 尝试删除挂载点目录 ==="
/bin/rmdir "/Volumes/Untitled" 2>&1; echo "rmdir1=$?"
/bin/rmdir "/Volumes/Untitled 1" 2>&1; echo "rmdir2=$?"
echo "=== 测试 sudo -n 通道（root 下自测）==="
sudo -n /usr/local/lib/ntfs-rw-helper/bin/ntfs-rw-mount 2>&1; echo "sudoexit=$?"
