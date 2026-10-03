**Feature 分支**: `002-init-wizard-ux` | **日期**: 2026-10-03 | **规格**: [spec.md](spec.md)

**输入**: 来自 `specs/002-init-wizard-ux/spec.md` 的功能规格与需求定义，及前序评估（`.specify/assessments/init-wizard-ux/`）的技术决策。

# 方案摘要

本特性聚焦于重塑 `automnt` 的交互心智模型与配置架构，全面落实“纯主机顺位排他探测模型”，彻底消除“网络策略”二分法与特定组网工具的特化债务；统一首次向导（`--init`）与日常管理（`--config`）为“主机优先 + 扫描倒推 + 循环登记”的顺畅体验；以 SMB URL 为单一真实来源推导标准挂载点，彻底根除 `-1`、`-2` 等临时冲突后缀污染并保护合法带数字共享名；引入基于 POSIX 终端机制的轻量字符捕获行输入，全局支持按 `Esc` 键即时放弃输入并优雅回退；解绑空配置与配置损坏判定，确立 0 台主机的合法休眠状态机；修复向导无视用户意愿强装 LaunchAgent 的缺陷；并提供存量配置启动时原地无感平滑升舱。

全量变更继续严格恪守项目架构纪律：保持单一活动配置、纯原生单文件零第三方依赖、无第二常驻进程，版本号按 SemVer Contract 规范晋级为 `v3.1.0`。

# 技术上下文

**编程语言与版本**: Swift 6.4（macOS 27.0 SDK）

**核心系统依赖**: Apple 原生系统框架（Foundation, SystemConfiguration, NetFS, Darwin 内核 POSIX termios API），严格零第三方库依赖

**数据存储**:
- 唯一活动配置文件：`~/Library/Application Support/automnt/automnt.plist`（Apple Property List 格式，0600 权限）
- 凭据存储：macOS 系统钥匙串（Keychain Services），代码与配置中严禁明文密码

**测试体系**: 内置自动化自测套件（`./automnt --self-test`），扩展包含挂载点净化、终端输入模拟、配置升舱映射、空主机休眠等原子自测用例

**目标平台**: macOS 27.0 或更高版本，Apple silicon（arm64）硬件架构

**工程形态**: 原生独立 macOS 命令行工具与 LaunchAgent 用户守护服务

**性能与交互指标**:
- 命令行冷启动耗时 < 50ms
- 单次主机探测耗时 < 1000ms（非阻塞 Socket 超时控制）
- 交互输入延迟 < 1ms，终端 Esc 键捕获响应无感知延迟
- 存量配置平滑升舱解析与写回耗时 < 10ms

**刚性约束**:
- 顺位探测绝对排他性：首个可达主机挂载后即刻短路终止探测，坚决不进行跨主机并发挂载
- 探索与设计阶段严禁修改生产代码，禁止向远端推送未晋级版本号的草稿代码
- 统一交互行读取机制必须具备非 TTY 环境安全回退能力，杜绝在自动化管道中崩溃
- 挂载点推导必须以 SMB URL 为单一真理，严禁对本地目录进行脆弱的正则猜切

# 宪法原则审查 (Constitution Check)

本计划依据项目宪法（Constitution v2.0.0）的核心工程原则进行前置审查：

| 宪法核心原则 | 合规判定 | 方案落实与证据 |
| :--- | :--- | :--- |
| **I. 配置数据只能来自真实探测或输入** | **通过** | 向导主机与共享完全来自系统活跃卷宗倒推或用户手动明确键入；代码中严禁硬编码任何默认 IP 或私有路径；凭据全权交由系统钥匙串保管，不落盘密码。 |
| **II. 不得引入第二个常驻运行进程** | **通过** | 保持单一 LaunchAgent 事件驱动唤醒机制；空配置识别后记录日志并以状态码 0 立即退出；不增加任何后台轮询守护循环。 |
| **III. 每个用户配置只有一个活动来源** | **通过** | 交互向导、日常配置与后台评估全量读取并维护唯一的 `automnt.plist`；存量旧格式在启动时原地升舱，不保留第二份配置。 |
| **IV. 版本与发布产物必须来自同一真理来源** | **通过** | 版本号严格以 `automnt.swift` 顶部的 `automntVersion = "3.1.0"` 为单一真理，CLI 输出、配置版本、Git Tag 严格派生同步。 |
| **项目约束：凭据由系统钥匙串管理** | **通过** | SMB URL 严禁内嵌明文密码，认证全权交由 macOS NetFS 与系统钥匙串处理；对扫描倒推的主机精准免除多余提示。 |

*审查结论：全部原则均严格合规，无需例外审批。*

# 项目结构与演进

### 文档结构 (本 Feature)

```text
specs/002-init-wizard-ux/
├── spec.md              # 业务规格与需求定义
├── checklists/          # 需求与就绪检查清单
│   └── requirements.md
├── plan.md              # 实施技术方案计划（本文档）
├── research.md          # Phase 0 技术方案与调研论证
├── data-model.md        # Phase 1 实体模型与校验规则
├── contracts/           # Phase 1 接口与格式契约
│   ├── config-schema.md
│   └── cli-interactions.md
├── quickstart.md        # Phase 1 端到端快速验证指南
└── tasks.md             # Phase 2 任务拆解清单（后续阶段生成）
```

### 源码结构演进映射

版本由 `v3.0.0` 晋级为 `v3.1.0`（向下兼容的新功能与原地升舱）：

| 模块 / 结构 | 当前基线实现 (v3.0.0) | Feature 交付目标状态 (v3.1.0) | 变更性质 |
| :--- | :--- | :--- | :--- |
| **数据配置模型** | `Config.profiles`（网络策略模型） | `Config.hosts`（主机顺位模型 `HostConfig`） | 核心模型升舱 |
| **主机实体字段** | `Profile`（id, description, targets...） | `HostConfig`（host, alias, port, timeoutMs, preventSpotlightIndex, enabled, shares） | 字段语义规整 |
| **挂载点推导** | 直接取本地挂载目录路径（引入 `-1` 污染） | `deriveStandardMountPoint(from: smbUrl)`（以 URL 为真理提取） | 算法根除污染 |
| **终端输入机制** | 原生 `readLine()`（无取消、无法按 Esc） | `promptLineWithEsc(prompt:)`（基于 termios 字符捕获，非 TTY 降级） | 交互容错增强 |
| **首次向导** | 单线性输入、硬编码强装 LaunchAgent | 倒推候选主机、下钻勾选、循环登记防重、跳过流、严格遵从部署选择 | 交互流程重构 |
| **日常管理** | 独立于向导的“两套逻辑”、强制保留 1 主机 | 统一复用主机交互引擎、允许删空主机、支持共享增删与手动录入 | 交互统一与健全 |
| **空配置处理** | 判定为 `.invalid` 并抛错阻断退出 | 合法空配置，后台日志记录静默休眠并以退出码 0 安全退出 | 状态机健全化 |
| **存量配置迁移** | 无升舱机制 | `migrateConfigIfNeeded()`：启动时原地检测升舱、无损继承属性、清洗挂载点 | 向下平滑兼容 |

### 架构演进决策

1. **统一主机与从属共享交互引擎（Host-First Interaction Engine）**：
   - 提取通用的 `discoverCandidateHosts()` 逻辑，从内核挂载表提取所有活跃 SMB 卷宗，按 `host` 聚类；
   - 提取通用的 `selectAndConfigureHostsLoop()` 交互组件，由 `--init` 与 `--config` 统一调用，保证用户操作心智模型 100% 一致。
2. **基于 POSIX termios 的轻量级输入行读取（Lightweight Terminal Input）**：
   - 通过 Darwin 原生 `tcgetattr` 与 `tcsetattr` 开启字符捕获，处理 ASCII 27 (`Esc`)、ASCII 127/8 (`Backspace`) 与回车；
   - 按 `Esc` 时终端输出 `\r\u{1B}[K` 清除整行并返回 `nil`；
   - 使用 `isatty(STDIN_FILENO)` 判断，非 TTY 自动回退至标准流读取，确保 CI/CD 与重定向安全。
3. **SMB URL 单一真理挂载点推导（SSOT Mount Point Derivation）**：
   - 解析 SMB URL，提取标准 URL 路径的末尾 Component 作为唯一合法的共享名称；
   - 规整生成 `/Volumes/<ShareName>`，彻底解决本地卷宗残留带来的 `/Volumes/xxx-1` 污染，同时严禁任何正则替换以保护 `data-1` 等合法命名。
4. **存量配置原地平滑升舱（In-Place Configuration Migration）**：
   - 读取 plist 时检查是否存在 `profiles`；若存在，自动遍历各 profile，将其 `description` 赋给 `alias`，继承 `timeoutMs` 与 `preventSpotlightIndex`，将从属 `smbShares` 的挂载点用推导算法规整，生成新版 `hosts` 列表并原子写回原文件。

# 复杂度追踪 (Complexity Tracking)

*宪法原则审查全项通过，无任何违背宪法原则的例外情况，本节不适用。*
