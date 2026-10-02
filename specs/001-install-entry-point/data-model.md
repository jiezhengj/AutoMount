本文档定义 Feature `001-install-entry-point` 的核心实体、字段语义、校验规则及状态流转。

# 实体一：安装状态实体 (InstallState)

用于在运行时评估程序当前部署的健康状态，驱动自搬迁与自愈逻辑。

### 属性与字段

| 属性名称 | 类型 | 必须 | 描述 |
| :--- | :--- | :--- | :--- |
| `currentExecutablePath` | String | 是 | 当前正在执行的进程二进制真实物理路径。 |
| `installedBinaryPath` | String | 是 | 规范安装路径：`~/Library/Application Support/automnt/bin/automnt`。 |
| `activeConfigPath` | String | 是 | 唯一活动配置文件路径：`~/Library/Application Support/automnt/automnt.plist`。 |
| `launchAgentPlistPath` | String | 是 | 用户守护服务定义路径：`~/Library/LaunchAgents/com.user.automnt.plist`。 |
| `detectedShellProfile` | String | 是 | 检测到的当前用户 Shell 配置文件路径（如 `~/.zshrc`）。 |
| `isRelocated` | Bool | 是 | 判定 `currentExecutablePath == installedBinaryPath`。 |
| `isCliEntryPresent` | Bool | 是 | Shell 配置文件中是否包含合法的定界注入块。 |
| `isServiceRegistered` | Bool | 是 | launchd 中是否成功注册且未含定时轮询配置。 |

### 校验规则与状态跃迁

- **状态 1：下载初次运行 (Uninstalled)**：`isRelocated == false`。触发自搬迁逻辑：复制二进制到规范目录、清除当前下载文件、注入 Shell CLI 入口。
- **状态 2：已正常安装 (Healthy)**：`isRelocated == true && isCliEntryPresent == true && isServiceRegistered == true`。正常执行业务或配置管理。
- **状态 3：安装状态损坏 (Degraded)**：`isRelocated == true` 但 `isCliEntryPresent == false` 或服务注册异常。触发轻量自愈（Self-Healing），幂等修复入口与服务配置。

# 实体二：网络策略规则实体 (Profile)

全面废弃链路层网关 MAC 匹配，改为主机网络服务可达性规则。

### 属性与字段

| 属性名称 | 类型 | 必须 | 描述 |
| :--- | :--- | :--- | :--- |
| `id` | String | 是 | 策略唯一标识符（如 `local_lan`, `tailscale_remote`）。 |
| `description` | String | 是 | 策略的人类可读描述信息。 |
| `host` | String | 是 | 目标探测主机地址（支持局域网 IP、域名或 Tailscale 主机名）。 |
| `port` | Int | 否 | 探测端口，默认为 `445`（SMB 标准服务端口）。 |
| `timeoutMs` | Int | 否 | 单次 TCP 握手超时时间，默认 `1000` 毫秒。 |
| `targets` | Array<MountTarget> | 是 | 该策略命中时应挂载的共享目标清单。 |

### 约束与弃用字段

- **已删除字段**：`gateway_mac`、`router_ip`、`interface_name` 等链路层字段彻底移出模型，不得在 Plist 中出现或反序列化。
- **主机合法性**：`host` 字段不得为空，不得包含 URL 协议前缀（如 `smb://` 或 `http://`）。

# 实体三：挂载目标实体 (MountTarget)

承载具体的网络文件系统挂载映射。

### 属性与字段

| 属性名称 | 类型 | 必须 | 描述 |
| :--- | :--- | :--- | :--- |
| `smbURL` | String | 是 | 标准 SMB URL（例如 `smb://nas.local/documents`）。 |
| `mountPath` | String | 是 | 本地挂载目录路径（例如 `/Volumes/documents`）。 |

### 校验规则

- `smbURL` 必须为合法 SMB URL，且必须包含共享名称（Share name）。
- `smbURL` 严禁内嵌明文用户名或密码（如 `smb://user:pwd@host/share`），在保存前由校验器强制拒绝。
- 凭据完全由 macOS 钥匙串（Keychain）根据主机名和用户名统一检索。

# 实体四：有限重试策略实体 (RetryPolicy)

用于在网络配置变更触发时平滑吸收网络就绪抖动。

### 属性与字段

| 属性名称 | 类型 | 必须 | 默认值 | 描述 |
| :--- | :--- | :--- | :--- | :--- |
| `maxAttempts` | Int | 否 | `3` | 单次事件唤醒后对当前优先策略的最大重试次数。 |
| `intervalMs` | Int | 否 | `1000` | 两次尝试之间的等待间隔（毫秒）。 |
| `maxTotalWindowMs` | Int | 否 | `10000` | 单次评估流程的最大总耗时安全熔断上限（毫秒）。 |

### 校验规则

- `maxAttempts` 取值范围限制在 `1` 到 `10` 次之间。
- `intervalMs` 最小为 `200` 毫秒，最大为 `3000` 毫秒。
- `maxTotalWindowMs` 必须大于等于 `maxAttempts * intervalMs`，防止配置矛盾。

# 实体五：单一活动配置根实体 (AutomntConfig)

全系统唯一活动配置模型，持久化于 `automnt.plist`。

### 属性与字段

| 属性名称 | 类型 | 必须 | 描述 |
| :--- | :--- | :--- | :--- |
| `version` | String | 是 | 配置文件格式规范版本号，与当前软件版本保持一致。 |
| `updateChannel` | String | 是 | 自动更新策略：`off`（默认）、`notify`、`auto`。 |
| `retryPolicy` | RetryPolicy | 否 | 事件驱动时的重试策略参数。 |
| `profiles` | Array<Profile> | 是 | 策略评估流水线列表（自顶向下按顺序匹配）。 |
| `lastUpdateCheckTimestamp` | Double | 否 | 最近一次版本检查尝试的 Unix 时间戳。 |
| `updateRetryAfterTimestamp` | Double | 否 | 更新检查或下载失败后的重试退避截止时间戳。 |
| `lastNotifiedVersion` | String | 否 | 已向用户发送系统横幅通知的最新远端版本。 |

# 实体六：Shell 注入片段实体 (ShellSnippet)

用于命令入口的幂等注入与原子剥离。

### 结构定义

```text
# >>> automnt CLI begin >>>
export PATH="$HOME/Library/Application Support/automnt/bin:$PATH"
# <<< automnt CLI end <<<
```

### 状态流转规则

- **注入前**：按行扫描用户 profile 文件，检测 `# >>> automnt CLI begin >>>`。
- **已存在时**：若内容与当前定义一致，无操作；若内容有差异，原子替换该标记块内部的行。
- **卸载还原**：精确删除从起始标记到结束标记的所有行，前后保留 1 个空行（如果原文件该处存在），绝不截断或篡改用户自定义的其他变量。
