# 产品定位

AutoMount 是专为 macOS 设计的原生轻量级网络存储（SMB）自动化挂载工具。针对多网络漫游场景（家庭局域网与外出移动办公环境无缝切换），穿透 VPN 与代理干扰，支持基于物理网关 MAC 指纹识别与 Tailscale 异地互联的多网络策略路由，提供完全静默、免密码输入、断网自动超时熔断清理的稳定网络卷宗挂载体验。

# 核心特性

- **静默后台挂载**：基于 macOS 原生 NetFS 深度系统框架调用，全后台运行，挂载过程不弹出任何 Finder 窗口，不干扰日常桌面操作。
- **多策略优先级路由 (Profiles)**：支持按网络环境声明优先级策略序列。家庭局域网千兆/2.5G 高速直连优先；脱离家庭环境时自动无缝降级至 Tailscale 异地互联通道。
- **物理网关 MAC 指纹识别**：绕过 VPN TUN 虚拟网卡，直接通过底层 ARP 协议获取物理网卡（如 `en0`）连接的路由器真实网关 MAC 地址作为网络指纹。不受 macOS 14+ 定位隐私权限限制，且完全免疫 Clash 等代理工具的 TUN 虚拟网卡接管与 Fake-IP 干扰。
- **断网失效挂载的超时强制清理**：采用 Darwin 内核 `MNT_NOWAIT` 非阻塞挂载表快照。网络漫游切换或服务端失联时，带 3 秒严格超时熔断机制执行强制卸载（`diskutil unmount force` 与 POSIX `unmount(MNT_FORCE)` 双重保障），杜绝文件系统 I/O 阻塞引发的系统彩虹球假死。
- **Tailscale 握手就绪延迟应对机制**：针对开盖唤醒或网络切换瞬间 WireGuard 虚拟链路尚未完成握手的延迟，提供轻量重试窗口（默认 3 次重试，间隔 1.0 秒），确保稳定连通。
- **蜂窝热点流量与 Spotlight 索引防护**：挂载成功后自动调用 `mdutil -i off` 并写入 `.metadata_never_index`，彻底屏蔽 Spotlight 远程元数据索引检索，防止移动网络流量消耗与 NAS 硬盘频繁唤醒；支持 `exclude_gateway_ips` 规则，默认排除 iPhone 个人热点网关（`172.20.10.1`）。
- **自升级与自动更新信道 (Auto-Update Channel)**：支持安全自升级机制（`--update`），通过语义化版本（SemVer）比对 GitHub 官方发布。支持三种更新策略：`off`（默认完全关闭，零外部网络请求）、`notify`（发现新版本时发送 macOS 系统横幅提醒，单版本仅提醒 1 次防打扰）、`auto`（全自动静默下载并热升级）。内置 24 小时冷却时间窗口与本地 `swiftc -parse` 编译期抽象语法树安全门，预检不通过自动终止升级，确保守护进程零崩溃风险。
- **现代化终端交互向导**：基于纯原生 ANSI Raw Mode 终端交互，支持方向键移动、空格勾选、回车提交；`--init` 阶段全自动动态扫描内核已挂载 SMB 共享与 Tailscale 在线节点，支持 MagicDNS 自动映射。
- **日常配置管理 (`--config`)**：提供一站式交互式控制中心，在同一界面内展示后台守护服务运行状态与自动更新策略，支持免重新初始化自由增删挂载目标、更新网关 MAC 与远程节点、管理更新信道，并提供自启动守护的一键安装、重载与卸载，修改后自动热同步至 LaunchAgent 运行时。
- **终端中英双语自适应 (i18n)**：基于 macOS 系统首选语言自适应中英双语界面，并支持通过环境变量 `AUTO_MOUNT_LANG=zh|en` 显式指定语言。
- **严格参数校验与帮助规范**：内置标准 `--help` / `-h` 帮助说明，严格拦截未知参数并给出错误提示，杜绝误操作。
- **免 Sudo 与零外部依赖**：纯原生 Swift 语言编写，通过 macOS 自带的 Swift 运行时直接执行，无需编译配置，日常运行无需 Root/Sudo 提权。

# 快速上手

## 运行方式

项目提供原生 Swift 脚本 [auto_mount.swift](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount.swift) 以及配套的便捷调用脚本 [auto_mount](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount)。系统内置 Swift 解释器直接运行，开箱即用：

```bash
cd /path/to/AutoMount
chmod +x auto_mount
./auto_mount
```

也可以直接通过系统命令调用：

```bash
swift auto_mount.swift
```

## 首次初始化配置 (`--init`)

首次使用时，请确保已在 Finder 中通过“连接服务器 (`Cmd + K`)”成功连接过目标 NAS 卷宗并勾选了“在钥匙串中记住密码”。

连接家庭网络后，运行初始化向导：

```bash
./auto_mount --init
```

向导将自动执行以下五步闭环流程：

1. **[1/5] 自动提取物理网关 MAC 地址**：显示当前路由器的物理指纹供确认，允许输入自定义 MAC 覆盖（不可留空，作为网络环境判定的核心排他基准）。
2. **[2/5] 动态扫描当前 SMB 挂载卷宗**：内核检测到已挂载的 SMB 卷宗后，呈现 ANSI 复选框供上下移动（`↑`/`↓` 或 `k`/`j`）与空格（`Space`）多选；**允许直接按回车留空跳过**（即在局域网内不自动挂载任何卷宗，仅以此局域网作为外出判定的排他条件）；若进行手动录入，本地挂载路径支持按回车自动采纳推导默认值（如 `/Volumes/<共享名>`）。
3. **[3/5] 动态探测 Tailscale 在线节点**：自动调用 `tailscale status --json` 获取节点列表并展示单选列表；若未检测到在线节点直接友好跳过；若选中目标设备，支持自动映射局域网共享、或一键勾选已挂载项、或输入共享名由系统自动组装并推导挂载路径。
4. **[4/5] 软件更新策略配置 (Auto-Update Policy)**：选择自动更新信道（`1. off` 默认、`2. notify`、`3. auto`），直接按回车自动选择 `off`，零外部网络请求。
5. **[5/5] 保存配置并一键部署后台自启动守护**：自动生成 `auto_mount.plist`，并主动询问是否立即注册为系统的后台自启动守护服务（默认 `Y`，按回车即可一键部署并启动），彻底打通首次使用的最后一公里。

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
> - 在“选择家庭局域网挂载目标”步骤中，若直接按回车跳过，代表**将该局域网环境的挂载目标明确设为空列表（作为排他门牌），原有的挂载目标不会被保留**。
> - 若已有配置且仅需在保留原有挂载项目的前提下进行增删、更新网关 MAC 或调整 Tailscale 节点，**切勿使用 `--init`，请改用 `./auto_mount --config`**。

## 日常配置管理 (`--config`)

日常如需新增挂载目录、删除已停用卷宗、或更换了家庭路由器，**切勿重新运行 `--init`（避免覆写已有配置）**。直接运行日常配置管理命令，即可在完整保留既有配置的基础上进行安全维护：

```bash
./auto_mount --config
```

终端将弹出交互式一站式控制中心：

```text
Auto Mount Tool - 日常配置管理 (v2.2.0)
====================================

当前已配置策略：
  [1] home_lan (家庭局域网直连 (千兆/2.5G 高速)) - 0 个挂载目标 (网络排他门牌，不执行本地挂载)
  [2] tailscale_remote (Tailscale 异地互联 (dx4600)) - 2 个挂载目标
      • /Volumes/finalhome <- smb://dx4600.tail5efc91.ts.net/finalhome
      • /Volumes/personal_folder <- smb://dx4600.tail5efc91.ts.net/personal_folder

软件版本: v2.2.0 | 自动更新信道: off (关闭自动检查，纯手动)
后台守护服务状态: 已注册运行 (gui/501/com.user.auto-mount)

请选择操作：
  [1] 添加挂载目标 (支持从当前已挂载项中导入或手动输入，本地挂载点自动推导)
  [2] 删除已有挂载目标
  [3] 重新检测/更新家庭网关 MAC
  [4] 重新检测/更新远程 Tailscale 目标 (若未配置 Tailscale 则显示为：配置并添加远程 Tailscale 策略)
  [5] 守护服务管理 (部署/重载、查看详情、卸载服务)
  [6] 自动更新信道与版本维护 (设置更新策略、立即检查并升级)
  [0] 保存配置并退出
```

退出保存时，程序不仅会更新工作区的 `auto_mount.plist`，还会自动同步至后台守护进程所在的配置目录，修改即刻全局生效。

## 部署开机与切网自动守护 (`--install`)

如果未在 `--init` 向导结尾部署守护，或需要单独管理后台服务，可使用以下独立命令（也可直接在 `./auto_mount --config` 菜单选项 `[5]` 中操作）：

```bash
# 一键安装并启用 LaunchAgent 守护服务 (免 sudo)
./auto_mount --install

# 查看自启动服务状态与卷宗挂载情况
./auto_mount --status

# 检查并升级软件至最新版本 (带本地语法安全校验)
./auto_mount --update

# 移除自启动服务与部署文件
./auto_mount --uninstall

# 查看命令行帮助与环境变量说明
./auto_mount --help
```

`--install` 命令会自动将运行文件与当前配置部署至 `~/Library/Application Support/AutoMount` 规范目录，规避 macOS 对 Documents / Downloads 等受保护目录的 TCC 权限限制，并在 `~/Library/LaunchAgents` 中生成系统事件监听描述文件。系统网络发生任何变更或从睡眠唤醒时，`launchd` 均会触发运行。

# 配置规范

配置文件位于 `auto_mount.plist`，采用标准 Apple 属性列表（XML）格式。多策略路由结构示例如下：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>version</key>
    <string>2.2.0</string>
    <key>update_channel</key>
    <string>off</string>
    <key>profiles</key>
    <array>
        <!-- 策略 1: 家庭局域网直连 (高优先级) -->
        <dict>
            <key>id</key>
            <string>home_lan</string>
            <key>description</key>
            <string>家庭局域网高速直连</string>
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

        <!-- 策略 2: Tailscale 异地互联 (外出降级策略) -->
        <dict>
            <key>id</key>
            <string>tailscale_remote</string>
            <key>description</key>
            <string>Tailscale 异地互联通道</string>
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
            <!-- 排除计量网关 (如 iPhone 个人热点) -->
            <key>exclude_gateway_ips</key>
            <array>
                <string>172.20.10.1</string>
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
| `version` | String | 规范版本号，与软件版本保持全局严格对齐（如 `2.2.0`）。程序读取配置时具备原地无损自动升舱能力，若旧版本落后会自动平滑升级为当前版本并写回，无需人工维护。 |
| `update_channel` | String | 软件自动更新策略，可选值为 `off`（关闭，默认）、`notify`（通知提醒）、`auto`（自动静默热升级）。 |
| `last_update_check_timestamp` | Real | 上次执行更新检查的 Unix 时间戳，用于 24 小时冷却时间窗口管理。 |
| `last_notified_version` | String | 已发送通知的最新远端版本号，确保同一版本最多仅提醒 1 次防打扰。 |
| `profiles` | Array | 策略规则列表。按数组先后顺序从上至下进行优先级匹配，一旦首个策略命中并执行，立即终止后续检查。 |
| `id` | String | 策略唯一标识（如 `home_lan`, `tailscale_remote`）。 |
| `description` | String | 策略的人类可读描述信息。 |
| `match.type` | String | 匹配类型：`gateway_mac`（物理网关 MAC 匹配）或 `probe_host`（主机连通性探测）。 |
| `match.value` | String | 匹配目标：网关 MAC 地址（不区分大小写）或探测的主机名/MagicDNS 域名/IP。 |
| `match.retry_count` | Integer | `probe_host` 模式下的重试次数（默认 3 次）。 |
| `match.retry_interval` | Real | `probe_host` 模式下每次探测的间隔秒数（默认 1.0 秒）。 |
| `exclude_gateway_ips` | Array | 排除的物理网关 IP 列表。若当前物理网关命中该列表，直接跳过该策略（默认包含 `172.20.10.1` 规避蜂窝热点流量）。 |
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

升级流程具备三层安全保障机制：
1. **语义化版本比对**：从 GitHub 官方 Release 元数据解析最新版本并进行 SemVer 对比。若远端无新版本或尚未发布正式 Release，友好提示无需更新。
2. **本地语法分析断路器**：下载的最新源码会在系统临时目录中调用 `/usr/bin/swiftc -parse` 进行完整的抽象语法树预检。若语法校验未通过，更新立即自动终止，绝不损坏当前正常工作的守护服务。
3. **双重运行环境同步与热重载**：升级成功后，不仅同步更新工作区源码，同时更新 `~/Library/Application Support/AutoMount` 部署目录下的核心程序，并自动执行 `launchctl bootout / bootstrap` 完成服务热重载，即刻无缝生效。

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

在开启代理软件（如 Clash Verge TUN 模式）的环境下，macOS 默认路由会被虚拟网卡接管，传统的高层网络接口查询均会将网络误判为虚拟链路。同时，macOS 14+ 对获取 Wi-Fi SSID 施加了严格的 CoreLocation 隐私提权限制。

AutoMount 穿透虚拟网卡层，直接读取系统底层 IPv4 默认物理路由接口（如 `en0`），并向系统 ARP 路由表发起查询获取该物理接口连接的下一跳路由器硬件 MAC 地址（BSSID）。此过程无需调用任何定位接口，不请求 Root/Sudo 提权，实现了零权限且免疫代理干扰的精准环境识别。

## 2. 内核非阻塞查询与超时强制清理机制

当 Mac 在外网漫游或合盖睡眠唤醒后，原本挂载的 SMB 卷宗往往变为无响应的失效挂载（Dead Mount）。若直接调用 POSIX `stat()` 或常规文件系统 API 探测该路径，当前线程将被内核死锁，甚至引发 Finder 与系统 UI 的彩虹球假死。

AutoMount 采用以下两级防护：
1. **零阻塞快照检索**：通过 Darwin 原生系统调用 `getmntinfo(..., MNT_NOWAIT)` 读取内核挂载表快照。由于指定了 `MNT_NOWAIT` 标志位，内核直接返回缓存的挂载记录而不向远端文件系统发起任何网络 I/O，整个比对过程耗时低于 1 毫秒。
2. **带 3 秒熔断的强制清理**：若比对发现挂载路径已被占用但远端服务器不可达，或当前网络策略已切换（例如挂载源原本是局域网 `nas.local`，当前处于外网需要切换到 `nas.example.ts.net`），程序启动异步子进程执行 `diskutil unmount force <mountPath>`。若 3 秒内未正常退出，主进程将向其发送 `SIGKILL` 强杀子进程，并立即通过系统调用 `unmount(mountPath, MNT_FORCE)` 执行内核级终极强制释放，确保本地挂载点恢复可用状态后再发起新策略的挂载。

## 3. NetFS 静默挂载核心

程序调用 macOS 内部核心框架 `NetFS.framework` 中的 `NetFSMountURLSync` API：

```swift
var mountPoints: Unmanaged<CFArray>?
let status = NetFSMountURLSync(
    url as CFURL,
    nil,
    nil,
    nil,
    nil,
    nil,
    &mountPoints
)
```

将用户名与密码参数传递为 `nil`，系统将自动读取当前登录用户保存在 macOS Keychain（钥匙串）中的 SMB 凭据。整个挂载过程完全由内核和后台守护完成，不弹出任何系统交互窗口。

# 常见问题

### Q: 开启 Clash 等代理的 TUN 模式后提示无法解析或连接失败？

AutoMount 的 MAC 地址探针已彻底免疫 TUN 虚拟网卡的干扰。如果挂载阶段提示主机不可达，通常是因为代理软件的 **Fake-IP 机制接管了内网域名解析**。

**解决方案**：在代理客户端的配置文件规则中，将 NAS 的域名（如 `*.local` 或特定的内网主机名）加入直连规则（Direct / Bypass）。例如添加规则：`DOMAIN-SUFFIX,local,DIRECT`。

### Q: 为什么使用 Tailscale 时推荐 MagicDNS 域名而非虚拟 IP？

Tailscale 的 MagicDNS 域名（如 `nas.example.ts.net`）具有以下核心优势：
1. **钥匙串凭据绑定稳定**：macOS 钥匙串会将 SMB 用户名密码与服务器主机名严格绑定。若使用 IP 地址，当节点重新配置或变更时凭据将失效；而域名能够永久保持钥匙串凭据匹配。
2. **系统级原生解析**：macOS 系统 DNS 会自动拦截并极速解析 Tailscale 域名，无缝适应多网络漫游。

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

- **`--init`（从零全量初始化）**：用于首次全新配置或推倒重来。向导全程独立构造新的策略结构，**绝不读取、合并或继承旧配置**。在挂载目标步骤直接按回车跳过，意味着将该网络策略的目标列表明确设为空（`targets: []`），作为“网络排他门牌”（在该网络下不执行任何本地挂载，仅作为外出判定排他基准），并在向导结束时**直接覆盖原有的 `auto_mount.plist` 配置文件**。
- **`--config`（日常增量维护）**：用于日常配置维护。它会首先完整载入并保留当前系统的有效配置，支持增量添加新挂载项、选择性删除指定挂载项、重新探测网关 MAC 或更新远程节点，修改完成后才写回磁盘并自动热同步至后台守护进程。日常维护务必使用 `--config`。

### Q: 更新了工作区代码后，后台运行的守护服务如何同步更新？

当您在本地拉取了 Git 最新代码或手动修改了工作区文件后，有两种方式让后台守护服务同步生效：
1. 运行 `./auto_mount --install`：程序会自动将工作区最新代码与配置复制部署至 `~/Library/Application Support/AutoMount`，并自动重载 launchd 服务。
2. 若启用了自动更新信道（`auto`）或运行了 `./auto_mount --update`：自升级引擎会自动完成双端同步并平滑热重载。

### Q: 软件更新是否会产生未经授权的后台网络请求？

AutoMount 遵循严格的隐私保护与确定性原则：
- **默认策略为 `off`**：默认情况下，程序绝对不会在后台向 GitHub 或任何外部服务器发起网络请求，更新检查完全依赖您显式运行 `./auto_mount --update`。
- **通知与自动模式的低频设计**：即使您主动开启了 `notify` 或 `auto` 模式，程序内部也设有严格的 24 小时（86,400 秒）冷却窗口，只在系统切网挂载完成后的空闲时间段进行一次极轻量的元数据比对（仅请求数十字节的 JSON 响应），绝不在高频切网时滥发请求。

### Q: `notify` 模式的提醒频次和上限是怎样的？是否会频繁弹窗打扰？

`notify` 模式具备双重防打扰与限频设计：
1. **最高频次限制**：受 24 小时（86,400 秒）严格冷却窗口控制。即使一天内高频漫游切网或休眠唤醒 100 次，每天也至多只会触发 1 次轻量检查；
2. **单版本仅提醒 1 次**：配置文件中持久化记录 `last_notified_version`。发现新版本并发送 1 次系统通知横幅后，该版本将不再重复提醒，绝不疲劳轰炸，直到官方发布了更新的版本才会再次提醒。

### Q: 升级软件后配置文件是否需要手动修改？是否需要重新运行 `--init`？

完全不需要。AutoMount 彻底废弃了配置与程序的双轨版本号，采用统一版本体系与**原地无损自动升舱机制（In-Place Auto-Migration）**：
- 当您更新软件到新版本后，程序在首次读取配置时会自动检查配置文件的 `version` 与各项字段规范；
- 若检测到配置文件版本落后或缺少新增属性，程序会自动在内存中无损保留所有已有的业务配置（网关 MAC、Targets、排除项等），自动补全缺失字段的官方安全默认值（如 `update_channel: "off"`），并将 `version` 原地更新为当前软件版本号写回磁盘，同时自动热同步至 LaunchAgent 运行时目录；
- 您无需重新初始化，也无需人工维护不同版本之间的配置映射，整个升舱过程对用户完全透明且无感。

# 许可证

MIT License
