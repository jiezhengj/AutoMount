本文档定义 Feature `002-init-wizard-ux` 的核心实体、字段语义、校验规则及状态流转。

# 实体一：主机顺位配置实体 (HostConfig)

用于承载单台目标网络存储服务器的探测参数与从属共享集合，作为顺位探测的基本单元。

### 属性与字段

| 属性名称 | 类型 | 必须 | 默认值 | 描述 |
| :--- | :--- | :--- | :--- | :--- |
| `host` | String | 是 | - | 目标主机 IP 地址、mDNS 局域网域名或远程域名（不带协议与端口）。 |
| `alias` | String? | 否 | `nil` | 人类友好别名/显示名称（如“家庭高速 NAS”）。未设置时属性列表中省略此键，展示时回退使用 `host`。 |
| `port` | Int | 否 | `445` | TCP 探测端口，默认标准 SMB 端口 445。 |
| `timeoutMs` | Int? | 否 | `1000` | 针对该主机的单次 TCP 握手超时时间（毫秒），缺省时继承默认 1000ms。 |
| `preventSpotlightIndex` | Bool | 否 | `true` | 是否对该主机名下的挂载卷宗自动执行 Spotlight 防索引保护，避免网络磁盘假死。 |
| `enabled` | Bool | 否 | `true` | 是否启用该主机顺位。为 `false` 时跳过该主机的可达性探测。 |
| `shares` | Array<SMBShareConfig> | 是 | `[]` | 从属于该主机的 SMB 共享文件夹清单。 |

### 校验规则

- `host` 必须为有效非空字符串，严禁包含 `smb://`、`http://` 等协议前缀，严禁包含斜杠或端口后缀。
- `port` 必须在有效端口范围（`1...65535`）内。
- `timeoutMs` 若设置，必须在有效区间（`100...30000`）内。
- `shares` 允许为空数组；同一主机名下的 `shares` 中不得包含重复的 `smbUrl`。

# 实体二：从属共享配置实体 (SMBShareConfig)

用于定义归属于特定主机的具体 SMB 共享文件夹资源及其本地挂载点规范。

### 属性与字段

| 属性名称 | 类型 | 必须 | 默认值 | 描述 |
| :--- | :--- | :--- | :--- | :--- |
| `name` | String | 是 | - | 共享显示名称，默认与远端共享名保持一致。 |
| `smbUrl` | String | 是 | - | 完整 SMB URL，格式为 `smb://<host>/<share>`。 |
| `mountPoint` | String | 是 | - | 标准本地目标挂载点，严格推导为 `/Volumes/<shareName>`。 |
| `enabled` | Bool | 否 | `true` | 是否启用该共享的自动挂载。 |

### 校验与推导规则

- **单一真理推导**：`mountPoint` 不得直接采用本地探测到的带 `-1`、`-2` 后缀的临时冲突路径，必须且只能由 `deriveStandardMountPoint(from: smbUrl)` 函数直接从 `smbUrl` 真实共享名称提取推导。
- **凭据隔离原则**：`smbUrl` 严格禁止内嵌明文用户名与密码（如 `smb://user:pwd@host/share`），在保存与校验阶段由格式检查器强制拒绝。
- **合法数字保护**：当共享名本身合法带有数字（如 `data-1`）时，`mountPoint` 完整保留为 `/Volumes/data-1`，绝不允许对其进行截断裁剪。

# 实体三：顶层应用配置实体 (AutomntConfig)

代表持久化保存在 `~/Library/Application Support/automnt/automnt.plist` 中的活动配置文件结构。与基线代码库高度自洽，仅将核心策略模型升舱为主机顺位模型。

### 属性与字段

| 属性名称 | 类型 | 必须 | 默认值 | 描述 |
| :--- | :--- | :--- | :--- | :--- |
| `version` | String | 是 | `"3.1.0"` | 当前配置文件规范版本（本 Feature 晋级为 `3.1.0`）。 |
| `hosts` | Array<HostConfig> | 是 | `[]` | 有序的主机顺位列表。数组索引 0 代表最高顺位，索引越大顺位越低。允许为空数组 `[]`（表示合法空配置）。 |
| `updateChannel` | String? | 否 | `"off"` | 自动更新检查策略（`"off"`, `"notify"`, `"auto"`）。 |
| `retryPolicy` | RetryPolicy? | 否 | - | 事件触发有限重试策略（最大尝试次数、重试间隔、总时间窗口）。 |
| `lastUpdateCheckTimestamp` | Double? | 否 | `nil` | 最近一次尝试检查更新的 UNIX 时间戳。 |
| `updateRetryAfterTimestamp` | Double? | 否 | `nil` | 更新检查失败退避重试时间戳。 |
| `lastNotifiedVersion` | String? | 否 | `nil` | 最近一次向用户发出提示的版本号（防重复打扰）。 |

### 顺位探测与状态转移

```mermaid
stateDiagram-v2
    [*] --> Wakeup: 系统网络变化 / 登录事件唤醒
    Wakeup --> CheckEmpty: 读取活动配置
    CheckEmpty --> SafeSleep: hosts 为空 (0 台主机)
    SafeSleep --> [*]: 记录静默日志，退出码 0

    CheckEmpty --> ProbeHost0: hosts 不为空
    ProbeHost0 --> MountShares0: 顺位 0 主机 445 可达
    MountShares0 --> Terminate: 挂载从属共享并排他性短路
    Terminate --> [*]: 退出本次评估

    ProbeHost0 --> ProbeHost1: 顺位 0 主机不可达
    ProbeHost1 --> MountShares1: 顺位 1 主机 445 可达
    MountShares1 --> Terminate: 挂载从属共享并排他性短路

    ProbeHost1 --> AllUnreachable: 所有顺位主机均不可达
    AllUnreachable --> CleanupStale: 超时检查并清理失效挂载
    CleanupStale --> [*]: 退出本次评估
```

# 实体四：运行期卷宗发现与主机分组实体 (DiscoveredMount & DiscoveredHostGroup)

仅存在于向导与日常配置的交互内存中，用于支持“主机优先 + 扫描倒推 + 循环登记”的操作流。

### 属性与字段

```text
DiscoveredMount:
- mountPoint: String       # 实际本地挂载路径（可能带 -1 临时冲突后缀）
- rawSmbUrl: String        # 内核挂载表返回的原始 URL
- host: String             # 提取解析出的主机 IP 或域名
- shareName: String        # 从 URL 提取的标准真实共享名
- cleanMountPoint: String  # 推导出的标准规整路径 /Volumes/<shareName>

DiscoveredHostGroup:
- host: String                      # 聚类聚合的主机标识
- mounts: Array<DiscoveredMount>   # 该主机名下检测到的所有活跃卷宗
- isConfigured: Bool               # 是否已在当前配置向导中被保存过
```

### 交互防重状态流转

- **未配置状态 (`isConfigured == false`)**：展示在候选主机列表中，供使用者点选下钻配置。
- **已配置状态 (`isConfigured == true`)**：展示为 `[✓] 已配置`，不可重复被点选，防止使用者在循环配置中产生混淆。

# 实体五：存量迁移结构映射 (MigrationMapping)

定义从旧版 `v3.0.0` 及更早版本配置向新版 `v3.1.0` 规范的原地升舱映射矩阵：

| 旧版字段 (Legacy Profile / Config) | 新版字段 (v3.1.0 HostConfig / Config) | 转换与清洗逻辑 |
| :--- | :--- | :--- |
| `config.version` | `config.version` | 递增为 `"3.1.0"`。 |
| `config.profiles` 数组 | `config.hosts` 数组 | 按原有数组顺序排列，平滑延续历史顺位优先级。 |
| `profile.host` | `host` | 原样复制，去除潜在的空白字符。 |
| `profile.description` | `alias` | 原样复制，作为人性化显示别名；若原描述为空则为 `nil`（不持久化 key）。 |
| `profile.port` | `port` | 原样复制（缺省为 445）。 |
| `profile.timeoutMs` | `timeoutMs` | 原样复制，无损继承历史连接超时。 |
| `profile.preventSpotlightIndex` | `preventSpotlightIndex` | 原样复制，无损继承历史防假死索引保护。 |
| `profile.targets` | `shares` | 遍历各 target，通过 `deriveStandardMountPoint` 纠偏 `mountPath` 为标准路径。 |
| `config.update_channel` | `config.update_channel` | 原样保留，无损继承既有更新通道设置。 |
| `config.retry_policy` | `config.retry_policy` | 原样保留，无损继承既有重试策略。 |
| `config.*_timestamp` | `config.*_timestamp` | 原样保留，无损延续更新频次防打扰状态。 |
