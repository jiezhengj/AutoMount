# 产品定位

automnt 是专为 macOS 设计的原生轻量级 SMB 自动挂载工具，基于目标主机 TCP 445 端口可达性自动匹配网络策略并挂载共享卷宗。程序通过 macOS 原生 NetFS 框架执行挂载；已有系统钥匙串凭据时无需交互输入密码，挂载失败返回明确状态并记录诊断日志。

# 核心特性

- **静默后台挂载**：基于 macOS 原生 NetFS 系统框架调用，全后台静默执行，挂载过程不弹出任何 Finder 窗口，不干扰日常桌面操作。
- **目标服务可达性路由**：全面基于主机 TCP 445 端口探测（`HostReachabilityProbe`）判定网络环境，无需依赖不稳定的链路层 MAC 地址或 ARP 缓存。
- **单用户标准安装与 CLI 自动注入**：规范安装于 `~/Library/Application Support/automnt/bin/automnt`，自动向当前用户的 Shell 配置文件（如 `.zshrc`、`.bash_profile`）注入 CLI 路径，打开终端即可全局使用 `automnt` 命令。
- **事件驱动响应式守护**：LaunchAgent 由 macOS 系统网络配置变更事件（`WatchPaths`）触发，严格杜绝定时器（`StartInterval`）轮询，空闲时零 CPU 与能耗占用。单轮网络评估引入有限重试机制（`EvaluationRetryRunner`），从容应对网络握手延迟。
- **断网失效挂载的有界清理**：采用 Darwin 内核 `MNT_NOWAIT` 非阻塞挂载表快照查询，杜绝 `stat()` 阻塞与系统彩虹球假死；仅对目标 SMB 挂载执行有时限的 `diskutil` 与 `umount -f` 强制清理。
- **单一活动配置契约**：系统统一使用 `~/Library/Application Support/automnt/automnt.plist` 作为唯一的运行时配置，严格采用 `0600` 权限安全原子写入。
- **Spotlight 索引防护**：挂载成功后自动请求 `mdutil -i off` 并尝试创建 `.metadata_never_index` 防护文件，避免网络卷宗被 Spotlight 建立索引导致性能下降。
- **免编译预编译升级**：通过官方 GitHub Release 直接下载对应版本的预编译二进制程序，在沙箱中完成签名与版本自验后原子替换，用户系统无需安装 Xcode 或 Swift 编译工具链。
- **安装完整性自检与自愈**：主程序启动时自动检测可执行文件、Shell 入口与守护服务状态，发现配置缺失或异常时自动触发原地自愈。
- **纯原生零依赖**：采用纯原生 Swift 编写，构建为针对 Apple silicon 原生优化的独立二进制可执行文件，无第三方运行时依赖。

# 快速上手

## 系统要求

- 架构：Apple silicon（arm64）
- 操作系统：macOS 27.0 或更高版本

## 安装与首次运行

从 GitHub Release 下载预编译二进制 `automnt` 并运行：

```bash
chmod +x automnt
./automnt
```

程序首次在临时或下载目录运行时，将自动执行自搬迁与环境初始化：
1. 规范安装至 `~/Library/Application Support/automnt/bin/automnt`；
2. 清理原下载临时文件；
3. 向当前用户的 Shell 配置注入路径；
4. 提示在新终端窗口中直接运行 `automnt`。

## 从旧版本 (2.7.4) 升级

3.0.0 采用全新的单活动配置与事件驱动架构，不提供从 2.7.4 旧形态的原地升级路径。既有旧版本使用者请按以下步骤迁移：

1. 在旧环境中使用 2.7.4 原程序提供的卸载命令执行完整清理：
   ```bash
   ./<旧版程序> --uninstall
   ```
2. 下载 3.0.0 预编译程序并运行首次安装：
   ```bash
   chmod +x automnt
   ./automnt
   ```
3. 运行初始化向导重新生成规范配置：
   ```bash
   automnt --init
   ```

> [!NOTE]
> 3.0.0 遵循纯粹单一模型架构，旧配置不会被沿用，请在向导中重新勾选或录入当前挂载目标。

## 初始化配置 (`automnt --init`)

首次使用前，请确保已在 Finder 中通过“连接服务器 (`Cmd + K`)”成功连接过目标 NAS 共享卷宗，并在提示时勾选了“在钥匙串中记住此密码”。

运行交互式初始化向导：

```bash
automnt --init
```

向导包含以下步骤：
1. **[1/4] 动态扫描当前系统已挂载的 SMB 卷宗**：内核检测到活动挂载后，呈现终端交互式复选框供空格（`Space`）多选；系统将自动从选中的目标提取主机名作为策略探测目标。
2. **[2/4] 动态探测 Tailscale 在线节点**：若系统运行 Tailscale，将自动列出在线节点供选择，便于配置异地远程互联访问。
3. **[3/4] 软件更新策略设置**：选择自动更新信道（`off` 手动更新、`notify` 仅通知、`auto` 后台自动升级），默认推荐 `off`。
4. **[4/4] 保存配置并部署后台守护服务**：生成 `automnt.plist`，并自动注册基于网络事件驱动的 LaunchAgent 后台守护服务。

> [!IMPORTANT]
> **注意：`--init` 默认保护现有配置**
> - 若已有可用配置，`automnt --init` 会自动保留现有配置。
> - 若需清空并从头重建配置，请明确执行 `automnt --init --reset`。写入前系统会自动生成带时间戳的 `.bak` 备份。

## 日常配置管理 (`automnt --config`)

日常如需新增共享挂载点、调整探测主机或修改更新信道，运行配置管理菜单：

```bash
automnt --config
```

终端将弹出交互式控制台，支持：
- 📁 **挂载目标管理**：批量导入活动挂载、手动录入 SMB 地址与本地挂载路径、勾选删除现有目标；
- 🚦 **网络策略管理**：调整策略优先级、修改探测主机与端口、设置重试策略；
- ⚙️ **守护服务管理**：查看 LaunchAgent 加载状态与日志、一键重新加载服务；
- 🔄 **自动更新设置**：切换更新信道、立即检查最新版本。

# 命令行接口规范

```text
使用方法:
  automnt                     评估网络策略并挂载匹配目标
  automnt --init              安全初始化；已有可用配置时不覆盖
  automnt --init --reset      备份现有配置并从头重建向导
  automnt --config            日常交互式配置管理控制台
  automnt --install           部署/修复后台挂载守护服务与 CLI 入口
  automnt --uninstall         移除后台守护服务与 CLI 入口（保留用户配置）
  automnt --uninstall --purge 全量卸载清理（包括守护、CLI、配置文件与日志）
  automnt --status            查看服务运行状态与当前挂载详情
  automnt --update            检查并升级软件至最新版本（下载预编译二进制）
  automnt --self-test         运行完整自动化测试套件
  automnt --version, -v       查看当前软件版本号
  automnt --help, -h          显示帮助说明

环境变量:
  AUTOMNT_LANG=zh|en          显式指定终端界面语言（默认自适应系统语言）
```

# 技术原理

## 主机服务端口探测 (HostReachabilityProbe)

系统采用非阻塞式 TCP Socket 连接探测指定目标主机（如 NAS 或服务器）的 445 端口：
- 对局域网或远程节点发送连接请求并设定有界超时（默认 1000 毫秒）；
- 端口可连接即判定该策略处于可达网络环境中；
- 连接被拒绝、主机不可达或超时即判定该网络策略未命中，继续向下评估下一策略。

## 事件驱动守护与自愈

- **网络事件监听**：LaunchAgent 配置文件注册 `WatchPaths` 监听 `/Library/Preferences/SystemConfiguration`，当网络发生切换（如从 Wi-Fi 切换到有线、连接/断开 VPN 等）时由 launchd 唤起执行。
- **重试调度**：唤起后通过 `EvaluationRetryRunner` 在指定时间窗口内进行有限重试，当网络握手建立后立即执行挂载；若重试窗口结束仍无任何策略命中，以退出码 `2` 静默退出，杜绝无限空转。
- **自动自愈**：主程序启动时读取 `InstallState`，若发现 LaunchAgent 缺失、配置失效或 Shell 入口被清理，自动进行无感自愈修复。

## 内核挂载表非阻塞扫描

为杜绝网络中断时标准文件系统调用 `stat()` 或 `FileManager` 造成的进程阻塞假死，automnt 采用 Darwin 原生内核接口：

```swift
let count = getfsstat(nil, 0, MNT_NOWAIT)
```

使用 `MNT_NOWAIT` 标志位直接从内核缓存中读取挂载快照，无论底层网络是否断开，调用均在微秒级立即返回。

## 卸载与清理

- 常规卸载：
  ```bash
  automnt --uninstall
  ```
  停止并注销 LaunchAgent 守护服务，从当前 Shell 配置文件中移除注入的 PATH 片段。用户的 `automnt.plist` 配置文件及日志目录被完整保留。

- 全量清理：
  ```bash
  automnt --uninstall --purge
  ```
  在常规卸载的基础上，彻底删除 `~/Library/Application Support/automnt` 及 `~/Library/Logs/automnt` 目录。
