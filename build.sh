#!/bin/zsh
# NTFS 读写助手 —— 全内置绿色版构建脚本
# 依赖（ntfs-3g / libntfs-3g / libfuse-t）全部打进 App 包内，拖入 Applications 即用。
set -e
cd "$(dirname "$0")"

APP_NAME="NTFS 读写助手"
BUNDLE="$APP_NAME.app"

LIBFUSE="/usr/local/lib/libfuse-t.dylib"
LIBNTFS="/usr/local/lib/libntfs-3g.89.dylib"
NTFS3G="/usr/local/bin/ntfs-3g"
NTFSFIX="/usr/local/bin/ntfsfix"

echo "==> 1/5 编译主程序与图标"
if [ ! -f AppIcon.icns ]; then
  /Users/yang/.workbuddy/binaries/python/envs/default/bin/python make_icon.py
fi
swiftc -O -swift-version 5 -framework AppKit -framework IOKit main.swift -o NTFSHelper

echo "==> 2/5 组装 App 结构"
BUILD_TMP=$(mktemp -d)
BUNDLE_TMP="$BUILD_TMP/$BUNDLE"
mkdir -p "$BUNDLE_TMP/Contents/MacOS" "$BUNDLE_TMP/Contents/Frameworks" "$BUNDLE_TMP/Contents/Resources"
cp Info.plist "$BUNDLE_TMP/Contents/Info.plist"
cp AppIcon.icns "$BUNDLE_TMP/Contents/Resources/AppIcon.icns"
mv NTFSHelper "$BUNDLE_TMP/Contents/MacOS/NTFSHelper"
FW="$BUNDLE_TMP/Contents/Frameworks"
MACOS="$BUNDLE_TMP/Contents/MacOS"

echo "==> 3/5 捆绑 ntfs-3g 引擎与运行库"
cp "$LIBFUSE"  "$FW/libfuse-t.dylib"
cp "$LIBNTFS"  "$FW/libntfs-3g.89.dylib"
cp "$NTFS3G"   "$MACOS/ntfs-3g"
cp "$NTFSFIX"  "$MACOS/ntfsfix"
# 免密通道自安装所需资源
cp helper-v2.sh      "$BUNDLE_TMP/Contents/Resources/ntfs-rw-mount.sh"
cp install_helper.sh "$BUNDLE_TMP/Contents/Resources/install_helper.sh"
chmod 755 "$BUNDLE_TMP/Contents/Resources/ntfs-rw-mount.sh" "$BUNDLE_TMP/Contents/Resources/install_helper.sh"

# 重写库引用：全部指向 App 内部，不依赖 /usr/local
install_name_tool -change "/usr/local/lib/libntfs-3g.89.dylib" \
  "@executable_path/../Frameworks/libntfs-3g.89.dylib" \
  "$MACOS/ntfs-3g"
install_name_tool -change "@rpath/libfuse-t.dylib" \
  "@executable_path/../Frameworks/libfuse-t.dylib" \
  "$MACOS/ntfs-3g"
for t in ntfs-3g ntfsfix; do
  install_name_tool -change "/usr/local/lib/libntfs-3g.89.dylib" \
    "@executable_path/../Frameworks/libntfs-3g.89.dylib" \
    "$MACOS/$t"
  install_name_tool -change "@rpath/libfuse-t.dylib" \
    "@executable_path/../Frameworks/libfuse-t.dylib" \
    "$MACOS/$t"
done
install_name_tool -id "@executable_path/../Frameworks/libntfs-3g.89.dylib" \
  "$FW/libntfs-3g.89.dylib"
install_name_tool -id "@executable_path/../Frameworks/libfuse-t.dylib" \
  "$FW/libfuse-t.dylib"

echo "==> 4/5 签名"
codesign --force --sign - "$FW/libfuse-t.dylib" "$FW/libntfs-3g.89.dylib"
codesign --force --sign - "$MACOS/ntfs-3g" "$MACOS/ntfsfix"
codesign --force --sign - "$BUNDLE_TMP"

echo "==> 5/5 输出并制作拖拽安装 DMG"
ditto "$BUNDLE_TMP" "$BUNDLE"
STAGING=$(mktemp -d)
cp -R "$BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "NTFS 读写助手.dmg" >/dev/null

echo "==> 完成"
ls -lh "$BUNDLE" "NTFS 读写助手.dmg"
