# NTFS 读写助手（macOS）

一个常驻菜单栏的小工具，让 macOS 对 NTFS 磁盘从「只读」变成「原生读写」。
插盘自动挂载、拔盘自动清理，全程不弹密码框。

底层走 **FUSE-T + ntfs-3g**（用户态文件系统），不依赖 Apple 签名的 FSKit 扩展，
所以**不需要付费开发者账号**就能在 macOS 13 ~ 27 上工作。

---

## 它解决什么问题

macOS 自带驱动对 NTFS 只提供只读挂载。市面上的商业软件（iBoysoft、赤友等）
走 FSKit 扩展路线，功能可以但需要 Apple 官方签名授权。本项目走另一条路：
用 FUSE-T 在用户态接管 NTFS，配 ntfs-3g 做实际读写，功能等价、成本为零。

## 核心设计

主程序（`main.swift`）只做**编排**，不碰文件系统本身：

1. **周期对账（reconcile）** — 每 3 秒核对全部 NTFS 分区状态，不依赖单次事件通知。
   原因：macOS 的磁盘事件会丢、会重复，事件驱动必然漏状态，对账才能收敛。
2. **系统只读抢占** — macOS 26/27 的 FSKit 内置驱动会在插盘瞬间抢先只读挂载。
   检测到就强制卸载，转成读写挂载。
3. **插拔/唤醒重枚举** — 新盘插入、拔插、睡眠唤醒后重新枚举，均自动读写挂载。
4. **尊重用户意图** — 用户主动在 Finder 里推出的盘，不再自动挂回（重插除外）。
5. **僵尸挂载清理** — 盘已拔但 fuse-t 挂载残留时自动清理，避免挂载点被占。
6. **失败指数退避** — 挂载失败不无脑重试，指数退避防止打转刷日志。

特权操作（mount/umount/fix）由一个独立的特权脚本承担，通过 sudoers
**免密通道**调用，且规则精确到**这一个可执行文件**，不放宽其他任何权限。

## 环境要求

| 项 | 要求 |
|---|---|
| 系统 | macOS 13.0+（在 macOS 27 上实测稳定） |
| 芯片 | Apple Silicon 实测；Intel 需自备对应架构的 ntfs-3g 与 fuse-t |
| 构建工具 | Xcode Command Line Tools（`swiftc`） |
| 运行时依赖 | `ntfs-3g`、`libntfs-3g.89.dylib`、`libfuse-t.dylib`（构建时打进 App 包内） |

## 构建

```bash
./build.sh
```

脚本做五件事：编译 Swift 主程序 → 组装 `.app` 结构 → 把 ntfs-3g 引擎与运行库
拷进包内并用 `install_name_tool` 重写为 `@executable_path/../Frameworks` 相对引用 →
ad-hoc 签名 → 产出可拖拽安装的 DMG。

产物：
- `NTFS 读写助手.app`（全内置，拖进 Applications 即用，不依赖 /usr/local）
- `NTFS 读写助手.dmg`（约 1.5MB）

图标由 `make_icon.py` 生成，`AppIcon.icns` 缺省时才重新生成。

## 使用

1. 把 `NTFS 读写助手.app` 拖进「应用程序」
2. 首次启动会弹一次管理员授权（把特权 helper 三件套装进
   `/usr/local/lib/ntfs-rw-helper/bin` 并写入 sudoers 免密规则）——**只需一次**
3. 之后插上 NTFS 盘，几秒内自动以读写方式挂载，菜单栏图标显示状态

日志：`~/Library/Logs/NTFSReadWriteHelper.log`（挂载细节另见 `/tmp/ntfs3g_mount.log`）

## 目录结构

```
.
├── main.swift              # 菜单栏 App 全部逻辑（约 50KB，单文件）
├── Info.plist              # bundle 元信息，LSUIElement=true（无 Dock 图标）
├── build.sh                # 一键构建：编译 → 打包 → 嵌库 → 签名 → 出 DMG
├── helper-v2.sh            # 特权挂载脚本（mount / unmount / fix），装成 ntfs-rw-mount
├── install_helper.sh       # 首次启动时安装 helper + 写 sudoers 免密规则
├── make_icon.py            # 图标生成（含白边自动质检）
├── AppIcon.icns            # 构建用图标
├── AppIcon.iconset/        # 图标源帧
├── site/index.html         # 产品页
├── test/                   # 真盘/镜像测试与诊断脚本
├── logo_*.png, favicon_64.png, icon_preview.png
└── docs/                   # 开发过程记录
```

## 关键实现细节

**强制卸载带看门狗**：`diskutil unmount` 需要等全部 DiskArbitration 会话确认，
个别会话无响应时会无限挂起。helper 里超过 8 秒未完成就杀掉 diskutil，
改用 root `umount -f` 兜底。

**挂载成功的判定不看 mount 表**：僵尸 NFS 记录同样出现在 `mount` 输出里，
但访问会返回 `Device not configured`。只有能真正 `ls` 出目录才算挂载成功。

**sudoers 写入必须回滚**：写完立刻 `visudo -c -f` 语法校验，不通过就删掉，
绝不能因为一条规则把系统 sudo 弄坏。

## 测试记录（v1.2 阶段）

| 测试项 | 结果 |
|---|---|
| 真盘读写删全链路（含 50MB 文件 SHA-1 校验） | ✅ 全过 |
| 镜像 512MB 顺序写（119 MB/s）+ 校验 | ✅ 一致 |
| 镜像 1000 小文件创建 + 逐个校验 | ✅ 4 秒，零丢失 |
| 镜像 4 路并发写 + 校验 | ✅ 4/4 |
| 镜像模拟插拔 ×10 自动挂载 | ✅ 10/10 |
| App 重启自动挂载 | ✅ |
| USB 掉线重连恢复 | ✅ 实测发生一次，自动处理 |

## 已知限制

- 首次使用需要一次管理员授权（安装特权 helper），这是模型决定的，无法避免
- 构建依赖 `/usr/local/lib` 下已装好的 `ntfs-3g` 与 `fuse-t`；仓库不包含这两个第三方组件
- App 为 ad-hoc 签名、未公证，首次打开可能需要在「系统设置 → 隐私与安全性」里放行
- 卸载盘前请先在 Finder 推出，避免写入中断

## 仓库不包含的内容

- `fskit-ref/`：调研期参考的第三方源码（xntfs / ttntfs），非本项目代码，未纳入版本管理
- `.app` / `.dmg`：构建产物，用 `build.sh` 重新生成；发布版见 Releases

## 版本

当前 **1.4.0**（`Info.plist` 中 `CFBundleShortVersionString`）
