#!/bin/bash
# 特权安装脚本：由 App 首次启动经 osascript（管理员授权弹窗一次）调起。
# 作用：把 helper 三件套装入 /usr/local/lib/ntfs-rw-helper/bin，
#       并为当前登录用户写入 sudoers 免密规则（仅限 helper 这一个可执行文件）。
# 之后 App 挂载/卸载/清理全部走免密通道，不再弹任何密码框。
set -e
MACOS_DIR="$1"   # App bundle Contents/MacOS（含 ntfs-3g / ntfsfix）
RES_DIR="$2"     # App bundle Contents/Resources（含 ntfs-rw-mount.sh）
DST=/usr/local/lib/ntfs-rw-helper/bin
FW_SRC="$MACOS_DIR/../Frameworks"
FW_DST="$DST/../Frameworks"

[ -x "$MACOS_DIR/ntfs-3g" ] || { echo "MISSING ntfs-3g" >&2; exit 10; }
[ -x "$MACOS_DIR/ntfsfix" ] || { echo "MISSING ntfsfix" >&2; exit 11; }
[ -f "$RES_DIR/ntfs-rw-mount.sh" ] || { echo "MISSING ntfs-rw-mount.sh" >&2; exit 12; }
[ -f "$FW_SRC/libfuse-t.dylib" ] || { echo "MISSING libfuse-t" >&2; exit 14; }

/bin/mkdir -p "$DST" "$FW_DST"
# 运行库必须放在 bin/../Frameworks：App 内二进制是 @executable_path/../Frameworks 引用
/bin/cp "$FW_SRC/libfuse-t.dylib" "$DST/../Frameworks/libfuse-t.dylib"
/bin/cp "$FW_SRC/libntfs-3g.89.dylib" "$DST/../Frameworks/libntfs-3g.89.dylib"
/usr/sbin/chown root:wheel "$FW_DST" "$FW_DST/libfuse-t.dylib" "$FW_DST/libntfs-3g.89.dylib"
/bin/chmod 755 "$FW_DST" "$FW_DST/libfuse-t.dylib" "$FW_DST/libntfs-3g.89.dylib"
/bin/cp "$MACOS_DIR/ntfs-3g" "$DST/ntfs-3g"
/bin/cp "$MACOS_DIR/ntfsfix" "$DST/ntfsfix"
/bin/cp "$RES_DIR/ntfs-rw-mount.sh" "$DST/ntfs-rw-mount"
/usr/sbin/chown root:wheel "$DST" "$DST/ntfs-3g" "$DST/ntfsfix" "$DST/ntfs-rw-mount"
/bin/chmod 755 "$DST" "$DST/ntfs-3g" "$DST/ntfsfix" "$DST/ntfs-rw-mount"

# 装完立刻验证引擎能否真正加载运行（dyld 依赖缺失会在这里暴露）
if ! "$DST/ntfs-3g" --version >/dev/null 2>&1; then
  echo "ENGINE_BROKEN" >&2
  exit 15
fi

# sudoers 免密规则：精确到 helper 单个可执行文件，不放大权限
U=$(/usr/bin/stat -f %Su /dev/console)
S=/etc/sudoers.d/ntfs-rw-helper
printf '%s ALL=(ALL) NOPASSWD: %s\n' "$U" "$DST/ntfs-rw-mount" > "$S"
/usr/sbin/chown root:wheel "$S"
/bin/chmod 440 "$S"
# 语法校验失败则回滚，绝不能把系统 sudo 弄坏
if ! /usr/sbin/visudo -c -f "$S" >/dev/null 2>&1; then
  /bin/rm -f "$S"
  echo "SUDOERS_INVALID" >&2
  exit 13
fi
echo HELPER_INSTALL_OK
