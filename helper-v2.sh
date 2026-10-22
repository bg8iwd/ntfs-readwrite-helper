#!/bin/bash
# NTFS 读写助手 特权挂载脚本 v4
# 用法:
#   ntfs-rw-mount mount   <diskXsY> <挂载点> <卷名>
#   ntfs-rw-mount unmount <挂载点|diskXsY>
#   ntfs-rw-mount fix     <diskXsY>
BIN="$(cd "$(dirname "$0")" && pwd)"

# 带看门狗的强制卸载：
# diskutil 卸载需要等待全部 DiskArbitration 会话确认，个别会话无响应时会无限挂起。
# 超过 8 秒未完成则杀掉 diskutil，改用 root umount 兜底。
force_unmount() {
  local target="$1"
  /usr/sbin/diskutil unmount force "$target" >/dev/null 2>&1 &
  local dp=$!
  local i=0
  while [ $i -lt 8 ]; do
    kill -0 "$dp" 2>/dev/null || break
    sleep 1; i=$((i+1))
  done
  if kill -0 "$dp" 2>/dev/null; then
    kill -9 "$dp" 2>/dev/null
    /sbin/umount -f "$target" >/dev/null 2>&1
  fi
  if /sbin/mount | grep -Fq "on $target ("; then
    /sbin/umount -f "$target" >/dev/null 2>&1
  fi
}

# 挂载点是否真的可用：僵尸 NFS 记录同样出现在 mount 表里，
# 但访问会返回 "Device not configured"。只有能列出目录才算挂载成功。
mp_reachable() {
  /bin/ls "$1" >/dev/null 2>&1
}

case "$1" in
  mount)
    dev="$2"; mp="$3"; vol="$4"
    for round in 1 2 3; do
      # 清掉设备与目标挂载点上的旧挂载（含系统只读抢占与死掉的 fuse-t 僵尸）
      force_unmount "$dev"
      force_unmount "$mp"
      /bin/rmdir "$mp" >/dev/null 2>&1
      /bin/mkdir -p "$mp"
      # 后台启动并完全脱离管道，防止调用方被守护进程拖死
      : > /tmp/ntfs3g_mount.log; chmod 666 /tmp/ntfs3g_mount.log 2>/dev/null
      "$BIN/ntfs-3g" "/dev/$dev" "$mp" -o "volname=$vol,local,noowners,noatime" </dev/null >/tmp/ntfs3g_mount.log 2>&1 &
      for i in $(seq 1 15); do
        sleep 1
        line=$(/sbin/mount | grep -F "on $mp (")
        if [ -n "$line" ]; then
          case "$line" in
            *nfs*|*fusefs_ntfs*|*ntfs-3g*)
              # 关键：mount 表里有记录不算成功，必须真正能访问
              if mp_reachable "$mp"; then
                exit 0
              fi
              # 僵尸挂载：清掉重来
              force_unmount "$mp"
              break ;;
            *ntfs*)
              # 系统只读驱动抢先占了挂载点 → 强卸后重试
              force_unmount "$mp"
              break ;;
          esac
        fi
      done
      # 清掉没挂成功的残留进程再重试
      pkill -f "ntfs-3g /dev/$dev" 2>/dev/null
      sleep 1
    done
    echo "MOUNT_FAILED_LOG:" >&2
    cat /tmp/ntfs3g_mount.log >&2
    exit 3
    ;;
  unmount)
    force_unmount "$2"
    if /sbin/mount | grep -Fq "on $2 ("; then
      echo "UNMOUNT_FAILED: $2" >&2
      exit 4
    fi
    exit 0
    ;;
  fix)
    "$BIN/ntfsfix" -d "/dev/$2" 2>&1
    ;;
  selftest)
    # 健康自检：引擎能否真正加载运行（dyld 依赖缺失/运行库丢失会在这里失败）。
    # App 首启据此判断免密通道是否可用，不可用则自动重装。
    if ! "$BIN/ntfs-3g" --version >/dev/null 2>&1; then
      echo "ENGINE_BROKEN" >&2
      exit 6
    fi
    if [ ! -x "$BIN/ntfsfix" ]; then
      echo "NTFSFIX_MISSING" >&2
      exit 7
    fi
    exit 0
    ;;
  keepalive)
    # 设备级保活：读 512 字节丢弃。
    # 目的是让 USB 存储栈保持活跃，避免 macOS 对空闲设备做 selective suspend
    # （部分桥接芯片被挂起后唤醒失败 → link change interrupt → 盘「自己消失」）。
    # 文件系统层的 stat/readdir 会命中 ntfs-3g 缓存，产生不了真实设备 I/O，所以必须读裸设备。
    dev="$2"
    if [ ! -e "/dev/r$dev" ] && [ ! -e "/dev/$dev" ]; then
      echo "NO_DEVICE: $dev" >&2
      exit 5
    fi
    if [ -e "/dev/r$dev" ]; then
      /bin/dd if="/dev/r$dev" of=/dev/null bs=512 count=1 2>/dev/null
    else
      /bin/dd if="/dev/$dev" of=/dev/null bs=512 count=1 2>/dev/null
    fi
    exit 0
    ;;
  *)
    exit 2 ;;
esac
