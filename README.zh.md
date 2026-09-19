# 产品定位

AutoMount 是专为 macOS 设计的原生轻量级网络存储（SMB）自动化挂载工具。针对多网络漫游场景（家庭局域网与外出移动办公环境无缝切换），穿透 VPN 与代理干扰，支持基于物理网关 MAC 指纹识别与 Tailscale 异地互联的多网络策略路由，提供完全静默、免密码输入、断网自动超时熔断清理的稳定网络卷宗挂载体验。

# 核心特性

- **静默后台挂载**：基于 macOS 原生 NetFS 深度系统框架调用，全后台运行，挂载过程不弹出任何 Finder 窗口，不干扰日常桌面操作。
- **多策略优先级路由 (Profiles)**：支持按网络环境声明优先级策略序列。家庭局域网千兆/2.5G 高速直连优先；脱离家庭环境时自动无缝降级至 Tailscale 异地互联通道。
- **物理网关 MAC 指纹识别**：绕过 VPN TUN 虚拟网卡，直接通过底层 ARP 协议获取物理网卡（如 `en0`）连接的路由器真实网关 MAC 地址作为网络指纹。不受 macOS 14+ 定位隐私权限限制，且完全免疫 Clash 等代理工具的 TUN 虚拟网卡接管与 Fake-IP 干扰。
- **断网失效挂载的超时强制清理**：采用 Darwin 内核 `MNT_NOWAIT` 非阻塞挂载表快照。网络漫游切换或服务端失联时，带 3 秒严格超时熔断机制执行强制卸载（`diskutil unmount force` 与 POSIX `unmount(MNT_FORCE)` 双重保障），杜绝文件系统 I/O 阻塞引发的系统彩虹球假死。
- **Tailscale 握手就绪延迟应对机制**：针对开盖唤醒或网络切换瞬间 WireGuard 虚拟链路尚未完成握手的延迟，提供轻量重试窗口（默认 3 次重试，间隔 1.0 秒），确保稳定连通。
- **蜂窝热点流量与 Spotlight 索引防护**：挂载成功后自动调用 `mdutil -i off` 并写入 `.metadata_never_index`，彻底屏蔽 Spotlight 远程元数据索引检索，防止移动网络流量消耗与 NAS 硬盘频繁唤醒；支持 `exclude_gateway_ips` 规则，默认排除 iPhone 个人热点网关（`172.20.10.1`）。
- **现代化终端交互向导**：基于纯原生 ANSI Raw Mode 终端交互，支持方向键移动、空格勾选、回车提交；`--init` 阶段全自动动态扫描内核已挂载 SMB 共享与 Tailscale 在线节点，支持 MagicDNS 自动映射。
- **日常配置管理 (`--config`)**：提供交互式日常维护菜单，支持免重新初始化自由增删挂载目标、更新网关 MAC 与远程节点，修改后自动热同步至 LaunchAgent 守护配置。
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

向导将自动执行以下流程：

1. **自动提取物理网关 MAC 地址**：显示当前路由器的物理指纹供确认。
2. **动态扫描当前 SMB 挂载卷宗**：内核检测到已挂载的 SMB 卷宗后，呈现 ANSI 复选框供上下移动（`↑`/`↓` 或 `k`/`j`）与空格（`Space`）多选；若当前无挂载卷宗，则引导手动输入。
3. **动态探测 Tailscale 在线节点**：自动调用 `tailscale status --json` 获取节点列表，展示单选列表；选中目标设备后，自动询问是否将局域网共享目录一键映射为远程主机目标（优先推荐永久稳定的 MagicDNS 域名，也可选用虚拟 IP）。
4. **生成配置文件**：自动生成 `auto_mount.plist`，完成全流程零手打配置。

交互式终端复选框操作说明：
- `↑` / `k`：向上移动光标
- `↓` / `j`：向下移动光标
- `Space`：翻转当前选项选择状态 (`[●]` / `[ ]`)
- `a`：全选 / 取消全选
- `Enter`：提交当前选择
- `Ctrl + C`：优雅退出并恢复终端状态

## 日常配置管理 (`--config`)

日常如需新增挂载目录、删除已停用卷宗、或更换了家庭路由器，无需重新从零初始化，直接运行：

```bash
./auto_mount --config
```

终端将弹出交互式菜单：

```
Auto Mount - 配置管理中心
=========================
  [1] 查看当前配置详情 (Profiles)
  [2] 添加挂载目标 (支持动态嗅探或手动输入)
  [3] 删除挂载目标
  [4] 更新家庭网关 MAC (重新探测或手动指定)
  [5] 更新远程 Tailscale 目标 (重新发现对端节点)
  [0] 保存并退出
```

退出保存时，程序不仅会更新工作区的 `auto_mount.plist`，还会自动同步至后台守护进程所在的配置目录，修改即刻全局生效。

## 部署开机与切网自动守护 (`--install`)

配置完成后，使用内置命令将程序注册为系统的后台守护进程：

```bash
# 一键安装并启用 LaunchAgent 守护服务 (免 sudo)
./auto_mount --install

# 查看自启动服务状态与卷宗挂载情况
./auto_mount --status

# 移除自启动服务与部署文件
./auto_mount --uninstall
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
    <string>2.0</string>
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
| `version` | String | 配置文件规范版本，当前为 `2.0`。 |
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
- 2.0 各 Profiles 策略的匹配规则与挂载点挂载来源

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

# 许可证

MIT License
