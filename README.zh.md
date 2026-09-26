# 产品定位

AutoMount 是专为 macOS 设计的原生轻量级 SMB 自动挂载工具，支持按物理网关 MAC 和远程 SMB 服务可达性匹配网络策略。程序通过 macOS NetFS 挂载共享；已有可用钥匙串凭据时无需交互输入密码，挂载失败会返回错误并记录诊断信息。

# 核心特性

- **静默后台挂载**：基于 macOS 原生 NetFS 深度系统框架调用，全后台运行，挂载过程不弹出任何 Finder 窗口，不干扰日常桌面操作。
- **多策略优先级路由 (Profiles)**：按配置顺序检查网络策略。匹配局域网策略时使用局域网 SMB 地址；未匹配时继续检查远程 SMB 服务。
- **物理网关 MAC 指纹识别**：程序优先从物理默认路由或 DHCP 信息确定网关与接口，再查询该接口作用域内的 ARP 邻居项。识别结果取决于 macOS 当前公开的路由和邻居信息。
- **断网失效挂载的有界清理**：采用 Darwin 内核 `MNT_NOWAIT` 非阻塞挂载表快照。程序只切换或卸载 SMB 挂载，不会卸载占用挂载点的其他文件系统；清理使用有总时限的 `diskutil` 与 `umount -f` 子进程，无法确认前一进程退出时不会并发卸载。
- **远程 SMB 就绪重试**：远程策略通过 TCP 445 探测 SMB 服务，并支持重试窗口（默认 3 次、间隔 1 秒），覆盖网络切换或唤醒后的短暂不可达状态。此探测检查 SMB 端口，不直接读取 Tailscale 握手状态。
- **Spotlight 索引防护与网关排除规则**：可为策略设置用户指定的物理网关排除 IP。挂载后程序调用 `mdutil -i off` 并写入 `.metadata_never_index`，同时记录系统是否确认关闭索引。
- **自升级与自动更新信道 (Auto-Update Channel)**：支持安全自升级机制（`--update`），通过语义化版本比对已发布的 GitHub Release。支持三种策略：`off`（默认关闭）、`notify`（每个版本提醒一次）、`auto`（自动下载并升级）。升级前完整编译源码，并在临时位置迁移配置；部署失败会恢复原文件，自动更新失败会在 15 分钟后重试。
- **现代化终端交互向导**：基于纯原生 ANSI Raw Mode 终端交互，支持方向键移动、空格勾选、回车提交；`--init` 阶段全自动动态扫描内核已挂载 SMB 共享与 Tailscale 在线节点，支持 MagicDNS 自动映射。
- **日常配置管理 (`--config`)**：提供一站式交互式控制中心，在同一界面内展示后台守护服务运行状态与自动更新策略，支持增删挂载目标、更新网关 MAC 与远程节点、管理更新信道，并提供自启动守护的一键安装、重载与卸载。已安装守护配置时，菜单直接读取并编辑应用程序支持目录里的配置；状态页同时显示 LaunchAgent 是否已加载和程序最近一次运行结果。
- **终端中英双语自适应 (i18n)**：基于 macOS 系统首选语言自适应中英双语界面，并支持通过环境变量 `AUTO_MOUNT_LANG=zh|en` 显式指定语言。
- **严格参数校验与帮助规范**：内置标准 `--help` / `-h` 帮助说明，严格拦截未知参数并给出错误提示，杜绝误操作。
- **免 Sudo 与零外部依赖**：纯原生 Swift 语言编写，通过 macOS 自带的 Swift 运行时直接执行，无需编译配置，日常运行无需 Root/Sudo 提权。

# 快速上手

## 运行方式

项目仅支持 macOS 27.0 或更高版本的 Apple silicon（arm64），不支持 Intel Mac。仓库包含 Swift 源码 [auto_mount.swift](auto_mount.swift) 和 arm64 预编译程序 [auto_mount](auto_mount)；运行源码和安装守护服务都会检查系统版本与 CPU 架构。`--install` 会使用 macOS 27 或更高版本 SDK 编译守护程序，因此需要提供该 SDK 的 Xcode 或 Command Line Tools：

```bash
cd /path/to/AutoMount
chmod +x auto_mount
./auto_mount
```

源码运行方式：

```bash
swift auto_mount.swift
```

## 首次初始化配置 (`--init`)

首次使用时，请确保已在 Finder 中通过“连接服务器 (`Cmd + K`)”成功连接过目标 NAS 卷宗并勾选了“在钥匙串中记住密码”。

连接家庭网络后，运行初始化向导：

```bash
./auto_mount --init
```

向导分五步完成首次配置：

1. **[1/5] 自动提取物理网关 MAC 地址**：显示当前路由器的物理指纹供确认，允许输入自定义 MAC 覆盖（不可留空，作为网络环境匹配条件）。
2. **[2/5] 动态扫描当前 SMB 挂载卷宗**：内核检测到已挂载的 SMB 卷宗后，呈现 ANSI 复选框供上下移动（`↑`/`↓` 或 `k`/`j`）与空格（`Space`）多选；**允许直接按回车留空跳过**（即在局域网内不自动挂载任何卷宗，仅以此局域网作为外出判定的排他条件）；若进行手动录入，本地挂载路径支持按回车自动采纳推导默认值（如 `/Volumes/<共享名>`）。
3. **[3/5] 动态探测 Tailscale 在线节点**：自动调用 `tailscale status --json` 获取节点列表并展示单选列表；若未检测到在线节点直接友好跳过；若选中目标设备，支持自动映射局域网共享、或一键勾选已挂载项、或输入共享名由系统自动组装并推导挂载路径。
4. **[4/5] 软件更新策略配置 (Auto-Update Policy)**：选择自动更新信道（`1. off` 默认、`2. notify`、`3. auto`），直接按回车自动选择 `off`，零外部网络请求。
5. **[5/5] 保存配置并部署后台守护**：生成 `auto_mount.plist`，并询问是否注册 LaunchAgent（默认 `Y`，按回车部署并启动）。

交互式终端复选框操作说明：
- `↑` / `k`：向上移动光标
- `↓` / `j`：向下移动光标
- `Space`：翻转当前选项选择状态 (`[●]` / `[ ]`)
- `a`：全选 / 取消全选
- `Enter`：提交当前选择（或直接回车跳过）
- `Ctrl + C`：优雅退出并恢复终端状态

> [!IMPORTANT]
> **注意：`--init` 为全量覆写式初始化**
> - `--init` 旨在从零构建全新的全量配置文件，**绝不读取、合并或保留既有的历史配置**。
> - 若磁盘中已存在 `auto_mount.plist`，向导运行完毕后将全量覆写该文件。
> - 在“选择家庭局域网挂载目标”步骤中，若直接按回车跳过，代表**将该策略的挂载目标设为空列表；策略命中后本轮评估会结束，且原有挂载目标不会被保留**。
> - 若已有配置且仅需在保留原有挂载项目的前提下进行增删、更新网关 MAC 或调整 Tailscale 节点，**切勿使用 `--init`，请改用 `./auto_mount --config`**。

## 日常配置管理 (`--config`)

日常如需新增挂载目录、删除已停用卷宗、或更换了家庭路由器，**切勿重新运行 `--init`（避免覆写已有配置）**。直接运行日常配置管理命令，即可在完整保留既有配置的基础上进行安全维护：

```bash
./auto_mount --config
```

终端将弹出交互式一站式控制中心：

普通工作区命令读取可执行文件旁的配置。存在已安装守护配置时，`--config` 菜单直接读取和编辑 `~/Library/Application Support/AutoMount/auto_mount.plist`，守护状态页也从该路径读取；没有守护配置时才使用工作区配置。首次安装时，`--install` 从工作区初始化守护配置。重装时若两份有效配置不同，交互运行会询问来源；非交互运行默认保留守护配置。可用 `--install --config-source workspace` 明确用工作区配置覆盖守护配置，或用 `--config-source runtime` 明确保留守护配置。无效或版本更新的守护配置不会被静默覆盖。

```text
Auto Mount Tool - 日常配置管理 (v2.7.0)
====================================

当前已配置策略流水线 (自顶向下顺序评估，首次命中即执行)：
  [1] [局域网] local_lan (本地局域网高速直连) - 0 个挂载目标 (命中后结束策略评估)
  [2] [远程] remote_network (远程互联 (NAS)) - 2 个挂载目标
      • /Volumes/documents <- smb://nas.example.ts.net/documents
      • /Volumes/media <- smb://nas.example.ts.net/media

软件版本: v2.7.0 | 自动更新信道: auto (后台静默自动升级)
后台守护服务状态: 已加载，当前空闲等待触发；守护配置存在 (gui/<uid>)

请选择操作模块：
  [●] 📁 挂载目标管理 (批量导入活动挂载、手动添加目标、批量勾选删除)
  [ ] 🚦 网络策略管理 (调整优先级顺序、新建策略、修改触发规则、删除策略)
  [ ] ⚙️ 守护服务管理 (部署自启动守护、查看详细运行状态、卸载服务)
  [ ] 🔄 自动更新设置 (切换自动更新策略、立即检查并升级)
  [ ] 🚪 退出配置管理
(↑/↓ 移动光标，Enter 选定确认，Esc 取消)
```

每次配置修改都会原子写入当前配置文件；已安装 LaunchAgent 时，程序会尝试同步到其运行目录。若同步失败，程序会报告错误，守护服务继续使用运行目录中已有的配置。

## 部署开机与切网自动守护 (`--install`)

如果未在 `--init` 向导结尾部署守护，或需要单独管理后台服务，可使用以下独立命令（也可直接在 `./auto_mount --config` 菜单选项 `[5]` 中操作）：

```bash
# 一键安装并启用 LaunchAgent 守护服务 (免 sudo)
./auto_mount --install

# 查看自启动服务状态与卷宗挂载情况
./auto_mount --status

# 检查并升级软件至最新版本 (完整编译预检)
./auto_mount --update

# 移除自启动服务与部署文件
./auto_mount --uninstall

# 查看命令行帮助与环境变量说明
./auto_mount --help
```

`--install` 会从当前 Swift 源码编译命令行程序，并将程序和源码部署至 `~/Library/Application Support/AutoMount`。首次安装时，程序会从工作区复制配置；重装时会比较两份配置（忽略版本号和守护进程更新检查状态）。若配置不同，交互安装会询问来源；非交互安装默认保留守护配置。`--install --config-source workspace` 可明确把工作区配置写入守护目录，`--install --config-source runtime` 可明确保留现有守护配置。无效或版本较新的守护配置不会自动被工作区覆盖。LaunchAgent 通过系统 Swift 运行时启动已部署的源码，以读取当前登录会话中的接口作用域网络信息；编译后的程序仍用于交互式命令。登录、网络配置变化、守护配置变化和每 60 秒间隔都会触发一次策略评估，以便网络就绪较晚时重试。

要运行网络验收，可执行 `./auto_mount --self-test --network --remote-smb`。`--remote-smb` 会读取当前配置的远程策略；若 Tailscale 状态中存在匹配节点，它会用该节点的 Tailscale 地址进行实挂测试，避免家中 DNS 把测试流量送回局域网。每个 SMB 共享都会临时挂载到用户缓存目录，核对挂载源后卸载。自测会把当前进程拿不到 ARP 输出的检查标记为 `SKIP`，不会算作通过。

# 配置规范

配置文件位于 `auto_mount.plist`，采用标准 Apple 属性列表（XML）格式。多策略路由结构示例如下：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>version</key>
    <string>2.7.0</string>
    <key>update_channel</key>
    <string>off</string>
    <key>profiles</key>
    <array>
        <!-- 策略 1: 本地局域网直连 (基于物理网关 MAC 指纹) -->
        <dict>
            <key>id</key>
            <string>local_lan</string>
            <key>description</key>
            <string>本地局域网高速直连</string>
            <key>match</key>
            <dict>
                <key>type</key>
                <string>gateway_mac</string>
                <key>value</key>
                <string>00:11:22:33:44:55</string>
            </dict>
            <key>prevent_spotlight_index</key>
            <true/>
            <key>targets</key>
            <array>
                <dict>
                    <key>mount_path</key>
                    <string>/Volumes/documents</string>
                    <key>url</key>
                    <string>smb://nas.local/documents</string>
                </dict>
                <dict>
                    <key>mount_path</key>
                    <string>/Volumes/media</string>
                    <key>url</key>
                    <string>smb://nas.local/media</string>
                </dict>
            </array>
        </dict>

        <!-- 策略 2: 远程异地互联 (Tailscale / WireGuard / 动态域名 / IP) -->
        <dict>
            <key>id</key>
            <string>remote_network</string>
            <key>description</key>
            <string>远程异地互联通道</string>
            <key>match</key>
            <dict>
                <key>type</key>
                <string>probe_host</string>
                <key>value</key>
                <string>nas.example.ts.net</string>
                <key>retry_count</key>
                <integer>3</integer>
                <key>retry_interval</key>
                <real>1.0</real>
            </dict>
            <!-- 示例地址仅用于说明字段格式，请输入用户实际要排除的网关 IP -->
            <key>exclude_gateway_ips</key>
            <array>
                <string>192.0.2.1</string>
            </array>
            <key>prevent_spotlight_index</key>
            <true/>
            <key>targets</key>
            <array>
                <dict>
                    <key>mount_path</key>
                    <string>/Volumes/documents</string>
                    <key>url</key>
                    <string>smb://nas.example.ts.net/documents</string>
                </dict>
                <dict>
                    <key>mount_path</key>
                    <string>/Volumes/media</string>
                    <key>url</key>
                    <string>smb://nas.example.ts.net/media</string>
                </dict>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

### 字段释义表

| 字段 | 类型 | 说明 |
| :--- | :--- | :--- |
| `version` | String | 规范版本号，与软件版本保持全局严格对齐（如 `2.7.0`）。程序读取配置时会自动升级配置并写回。 |
| `update_channel` | String | 软件自动更新策略，可选值为 `off`（关闭，默认）、`notify`（通知提醒）、`auto`（自动静默热升级）。 |
| `last_update_check_timestamp` | Real | 最近一次更新检查尝试的 Unix 时间戳；无失败重试时，常规检查间隔为 24 小时。 |
| `update_retry_after_timestamp` | Real | 后台检查或自动部署失败后的重试时间；到期后会绕过 24 小时正常间隔重新尝试。 |
| `last_notified_version` | String | 已发送通知的最新远端版本号，确保同一版本最多仅提醒 1 次防打扰。 |
| `profiles` | Array | 策略规则列表。按数组先后顺序从上至下进行优先级匹配，一旦首个策略命中并执行，立即终止后续检查。 |
| `id` | String | 策略唯一标识（如 `local_lan`, `remote_network`）。读取配置时，程序会将已支持的旧 ID（`home_lan`, `tailscale_remote`）迁移为当前名称。 |
| `description` | String | 策略的人类可读描述信息。 |
| `match.type` | String | 匹配类型：`gateway_mac`（物理网关 MAC 匹配）或 `probe_host`（探测 SMB TCP 端口 445）。 |
| `match.value` | String | 匹配目标：网关 MAC 地址（不区分大小写）或探测的主机名/MagicDNS 域名/IP。 |
| `match.retry_count` | Integer | `probe_host` 模式下的重试次数（默认 3 次）。 |
| `match.retry_interval` | Real | `probe_host` 模式下每次探测的间隔秒数（默认 1.0 秒）。 |
| `exclude_gateway_ips` | Array | 用户指定的物理网关 IP 列表。若当前物理网关命中该列表，程序跳过该策略；默认不排除任何网关。 |
| `prevent_spotlight_index` | Boolean | 挂载成功后是否自动阻断 Spotlight 建立索引（默认为 `true`）。 |
| `targets` | Array | 该策略下需要挂载的 SMB 卷宗列表。 |
| `targets[].url` | String | SMB 协议完整连接串（如 `smb://nas.local/share`）。 |
| `targets[].mount_path` | String | 本地预期挂载点绝对路径（如 `/Volumes/share`）。 |

# 日常维护

## 查看运行状态与挂载详情

随时可通过 `--status` 选项查看当前网络环境识别结果、底层物理网关详情与各策略挂载状态：

```bash
./auto_mount --status
```

输出内容包括：
- 当前活跃物理网络接口与网关 IP/MAC
- LaunchAgent 守护服务运行状态
- 各 Profiles 策略的匹配规则与挂载点挂载来源
- 软件版本与当前自动更新信道

## 软件检查与自升级 (`--update`)

随时可以通过 `--update` 子命令主动检查并升级 AutoMount：

```bash
./auto_mount --update
```

升级流程包含以下检查和更新步骤：
1. **Release 与版本检查**：只查询 GitHub 已发布的最新 Release；单纯推送 commit 不会触发用户更新。Release 版本必须高于当前版本，且 tag 下的源码内版本号必须与 Release tag 一致。
2. **工作区与运行目录版本同步**：
   - **工作区到运行目录**：从工作区执行 `--update` 时，程序更新已有的工作区和运行目录文件；已加载的 LaunchAgent 保持运行，并在配置变化触发或不超过 60 秒的下次启动时读取新文件；
   - **运行目录到工作区**：工作区命令检测到已安装版本更新时，会在工作区允许同步的情况下更新源码、编译程序并迁移配置。
3. **配置迁移**：配置先复制到临时文件，再由新程序迁移。只有程序和所有目标配置均准备成功后才部署；迁移失败时原文件不变。
4. **完整编译与回滚**：下载源码先完整编译。程序、源码和配置作为一组替换；任一文件替换失败时会恢复已替换的文件。
5. **守护进程继续运行**：升级不会从当前守护进程中调用 `launchctl bootout`。LaunchAgent 使用固定的运行目录路径，新的程序文件会在配置变化触发或不超过 60 秒的下次启动时生效；升级不会强制启动原本未加载的服务。

## 查看软件版本 (`--version`, `-v`)

通过 `--version` 或 `-v` 选项可直接输出纯文本版本号，适用于脚本自动化集成与环境检查：

```bash
./auto_mount --version
```


## 审计日志

程序运行记录保存在可执行文件所在目录下的 `auto_mount.log` 中。仅记录网络匹配变更、挂载状态切换与异常错误，避免日志冗余：

```bash
tail -f ~/Library/Application\ Support/AutoMount/auto_mount.log
```

## LaunchAgent 维护命令

如需手动控制系统的 `launchd` 守护服务，可使用以下原生命令：

```bash
# 检查服务是否已加载注册
launchctl list | grep auto-mount

# 手动触发一次挂载评估
launchctl start com.user.auto-mount

# 停止服务
launchctl stop com.user.auto-mount
```

# 技术原理

## 1. 物理层网络指纹探测

AutoMount 不读取 Wi-Fi SSID。它优先从系统 IPv4 默认路由中选择物理以太网接口；如果当前默认路由走虚拟接口，则尝试从物理接口的 DHCP 信息读取网关，再查询该接口作用域内的 ARP 邻居项。识别结果依赖 macOS 当前提供的路由、DHCP 和 ARP 信息，网络服务或 VPN 配置可能影响探测结果。

## 2. 内核非阻塞查询与超时强制清理机制

网络切换或唤醒后，已有 SMB 挂载可能暂时无响应。程序通过 Darwin `getmntinfo(..., MNT_NOWAIT)` 检查内核挂载表，避免为该次检查主动访问远程文件系统。

AutoMount 采用以下两级防护：
1. **非阻塞挂载表检查**：使用 `getmntinfo(..., MNT_NOWAIT)` 读取内核挂载表快照，避免为此检查向远端文件系统发起文件操作。
2. **有总时限的 SMB 清理**：若配置路径上的 SMB 来源失效或与目标共享不同，程序先执行 `diskutil unmount force <mountPath>`，失败时在剩余时限内尝试 `umount -f <mountPath>`。程序会终止超时子进程；无法确认前一进程已退出时，不会并发启动下一种卸载操作。其他类型的挂载会保留并报告冲突。

## 3. NetFS 静默挂载核心

程序调用 macOS 内部核心框架 `NetFS.framework` 中的 `NetFSMountURLSync` API：

```swift
var mountPoints: Unmanaged<CFArray>?
let openOptions = NSMutableDictionary()
openOptions[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
let status = NetFSMountURLSync(
    url as CFURL,
    mountpointURL,
    nil,
    nil,
    openOptions as CFMutableDictionary,
    nil,
    &mountPoints
)
```

片段中的 `url` 和 `mountpointURL` 是经过校验的输入。标准 `/Volumes/<共享名>` 路径尚不存在时，`mountpointURL` 为 `nil`，由 NetFS 创建挂载目录；其他目标传入指定路径。程序将用户名与密码参数留空，并设置 NetAuth 无交互选项。macOS 可使用当前用户已有的钥匙串 SMB 凭据；如果没有可用凭据，挂载会失败并记录诊断信息，不会弹出凭据输入框。

# 常见问题

### Q: 开启 Clash 等代理的 TUN 模式后提示无法解析或连接失败？

启用代理 TUN 后，系统默认路由可能经过虚拟接口。AutoMount 会尝试回退到物理接口的 DHCP 网关信息，但该信息不可用时，状态页会显示网关或 MAC 未检测到。远程 SMB 连接失败时，也请检查代理规则和目标主机的 DNS 解析。

**解决方案**：在代理客户端的配置文件规则中，将 NAS 的域名（如 `*.local` 或特定的内网主机名）加入直连规则（Direct / Bypass）。例如添加规则：`DOMAIN-SUFFIX,local,DIRECT`。

### Q: 为什么使用 Tailscale 时推荐 MagicDNS 域名而非虚拟 IP？

Tailscale MagicDNS 域名（如 `nas.example.ts.net`）可提供稳定的主机名，便于多个网络环境复用同一 SMB 地址和对应的钥匙串条目。域名解析仍依赖 Tailscale 与系统 DNS 当前状态。

### Q: 提示挂载失败或没有权限？

1. 请先在 Finder 中按下快捷键 `Cmd + K`，输入目标 SMB 完整地址（例如 `smb://nas.local/share`），在弹出的凭据认证窗口中输入用户名和密码，并务必勾选**“在我的钥匙串中记住此密码”**。
2. 确保在 Finder 中能够正常浏览该卷宗内容后，AutoMount 即可在后台静默完成免密挂载。

### Q: 更换了家里的路由器或光猫后无法自动挂载？

由于路由器的物理 MAC 地址发生了改变，只需在家庭网络下运行一次配置更新命令即可：

```bash
./auto_mount --config
```

在菜单中选择 `[4] 更新家庭网关 MAC`，程序将自动捕获新网关的 MAC 指纹并保存生效。

### Q: 运行 `--init` 与 `--config` 有何本质区别？在 `--init` 中直接按回车跳过挂载目标会发生什么？

- **`--init`（从零全量初始化）**：用于首次全新配置或推倒重来。向导全程独立构造新的策略结构，**绝不读取、合并或继承旧配置**。在挂载目标步骤直接按回车跳过，意味着将该网络策略的目标列表明确设为空（`targets: []`）。当该策略匹配时，本轮评估会结束且不执行挂载；向导结束时会**直接覆盖原有的 `auto_mount.plist` 配置文件**。
- **`--config`（日常增量维护）**：用于日常配置维护。它会首先完整载入并保留当前系统的有效配置，支持增量添加新挂载项、选择性删除指定挂载项、重新探测网关 MAC 或更新远程节点，修改完成后才写回磁盘并自动热同步至后台守护进程。日常维护务必使用 `--config`。

### Q: 更新了工作区代码后，后台运行的守护服务如何同步更新？

当您在本地拉取了 Git 最新代码或手动修改了工作区文件后，有两种方式让后台守护服务同步生效：
1. 运行 `./auto_mount --install`：程序会部署工作区最新代码。首次安装会从工作区初始化守护配置；重装时若配置不同，交互运行会询问来源，非交互运行默认保留守护配置。需要覆盖时运行 `./auto_mount --install --config-source workspace`。
2. 若启用了自动更新信道（`auto`）或运行了 `./auto_mount --update`：升级器会先验证源码和配置，再更新程序与配置；后台服务会在配置变化触发或不超过 60 秒的下次启动时读取新版本。

### Q: 软件更新是否会产生未经授权的后台网络请求？

AutoMount 遵循严格的隐私保护与确定性原则：
- **默认策略为 `off`**：后台不会自动检查版本；需要检查时，可运行 `./auto_mount --update`。
- **通知与自动模式的检查间隔**：成功查询后，常规检查间隔为 24 小时。网络、下载或部署失败会保存 15 分钟后的重试时间，避免每分钟重复请求，也不会因一次失败停更 24 小时。

### Q: `notify` 模式的提醒频次和上限是怎样的？是否会频繁弹窗打扰？

`notify` 模式具备双重防打扰与限频设计：
1. **常规检查间隔**：成功检查后 24 小时内不重复查询；检查失败时 15 分钟后重试；
2. **单版本仅提醒 1 次**：配置文件中持久化记录 `last_notified_version`。发现新版本并发送 1 次系统通知横幅后，该版本将不再重复提醒，绝不疲劳轰炸，直到官方发布了更新的版本才会再次提醒。

### Q: 升级软件后配置文件是否需要手动修改？是否需要重新运行 `--init`？

已有配置仍可使用，无需仅为软件升级重新运行 `--init`。程序会更新配置版本、填入默认值、迁移支持的策略 ID 与描述，并保留配置中未识别的扩展字段。工作区和守护运行配置分别迁移；安装守护服务后，`--config` 会读取并编辑应用程序支持目录中的运行配置。

# 许可证

MIT License
