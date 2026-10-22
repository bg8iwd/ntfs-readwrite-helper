#!/bin/bash
# 测试3：免密挂载真盘 + 写入验证
sudo -n /usr/local/lib/ntfs-rw-helper/bin/ntfs-rw-mount mount disk6s1 "/Volumes/Untitled 2" "Untitled"
echo "mount_exit=$?"
echo "=== mount 输出 ==="
mount | grep -i untitled
echo "=== 挂载点内容 ==="
ls -la "/Volumes/Untitled 2" 2>&1 | head -15
echo "=== 写入测试（root）==="
echo "rw-test-$(date +%s)" > "/Volumes/Untitled 2/.rw_test_$(date +%s)" && echo "WRITE_OK" || echo "WRITE_FAIL"
ls "/Volumes/Untitled 2" | grep rw_test | tail -2
