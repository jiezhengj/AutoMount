**Feature 分支**: `001-install-entry-point` | **日期**: 2026-10-02 | **规格**: [spec.md](spec.md)

**输入**: 来自 `specs/001-install-entry-point/spec.md` 的功能规格与需求定义，及 `specs/001-install-entry-point/research.md` 的核心技术决策。

# 方案摘要

本特性实现用户级单一副本安装、稳定命令入口、主机可达性网络策略匹配、事件驱动重试机制，以及 CLI 命令简化与全局资产统一重命名为 `automnt`。

当前代码库基线基于 `auto_mount.swift`、`auto_mount` 命令与 `jiezhengj/AutoMount` 仓库。演进方案将 CLI 命令缩短简化为 7 字符紧凑风格 `automnt`，并将项目全链路资产（源码、编译产物、配置文件、LaunchAgent 标识、应用目录、公开文档与 GitHub 仓库名）全量 1:1 统一命名为 `automnt`，不保留历史别名或过渡兼容分支。

使用者下载预编译程序后直接运行，程序自动完成规范位置搬迁（`~/Library/Application Support/automnt/bin/automnt`），自动清理下载目录中的临时副本，并在用户 Shell 配置文件中注入受控定界的命令入口，实现无感部署。后台服务通过 macOS LaunchAgent 在登录和网络变动时事件驱动唤醒，彻底废弃固定周期轮询，并对高顺位主机实施有限重试以平滑吸收就绪延迟；策略匹配彻底废弃链路层网关 MAC 依赖，改为主机传输层（TCP 445）可达性探测。

# 技术上下文

**编程语言与版本**: Swift 6.4（macOS 27.0 SDK）

**核心系统依赖**: Apple 原生系统框架（Foundation, SystemConfiguration, NetFS, Darwin 内核 POSIX API），零第三方库依赖

**数据存储**: 
- 唯一活动配置文件：`~/Library/Application Support/automnt/automnt.plist`（Apple Property List 格式，0600 权限）
- 凭据存储：macOS 系统钥匙串（Keychain Services），代码与配置中严禁明文密码

**测试体系**: 内置自动化自测套件（`./automnt --self-test`），包含状态矩阵、配置迁移、URL 校验、原子替换等全量用例，测试在独立隔离临时目录中执行

**目标平台**: macOS 27.0 或更高版本，Apple silicon（arm64）硬件架构

**工程形态**: 原生独立 macOS 命令行工具与 LaunchAgent 用户守护服务

**性能指标**:
- 单次主机探测耗时 < 1000ms（非阻塞 Socket 超时控制）
- 单次事件唤醒评估总窗口不超过 10 秒
- 命令行冷启动耗时 < 50ms
- 非评估周期完全零 CPU 占用（无后台常驻进程）

**刚性约束**:
- 普通登录用户权限运行，严禁依赖 root 或 sudo
- 不依赖付费 Apple 开发者证书签名与公证
- 单一可运行程序副本、单一可编辑配置副本
- 卸载时精确还原 Shell 配置，不破坏用户其余配置
- 探索与设计阶段严禁修改生产代码或远端仓库，重命名等动作必须在实施阶段通过原子任务完成

# 宪法原则审查 (Constitution Check)

本计划依据项目宪法（Constitution v2.0.0）的核心工程原则进行前置审查：

| 宪法核心原则 | 合规判定 | 方案落实与证据 |
| :--- | :--- | :--- |
| **I. 配置数据只能来自真实探测或输入** | **通过** | 挂载目标只能来自用户当前挂载探测或配置向导显式输入，所有测试使用保留规范 IP，凭据严格由系统钥匙串保管，不写入配置或日志。 |
| **II. 不得引入第二个常驻运行进程** | **通过** | 彻底移除 LaunchAgent 的 `StartInterval` 定时器；后台评估由系统网络变动与登录事件按需拉起，评估与重试结束后立即退出，无常驻循环。 |
| **III. 每个用户配置只有一个活动来源** | **通过** | 交互命令与后台服务均唯一锁定 `~/Library/Application Support/automnt/automnt.plist`，废弃双配置判断与同步逻辑。 |
| **IV. 版本与发布产物必须来自同一真理来源** | **通过** | 严格以源码顶部 `automntVersion` 为 SSOT，预编译二进制与发布 Tag 保持完全同源派生。 |
| **约束：凭据由系统钥匙串管理** | **通过** | 拒绝任何含内嵌凭据的 SMB URL，所有连接认证委托给 NetFS 与钥匙串。 |

*审查结论：全部原则均严格合规，无需例外审批。*

# 项目结构与演进

### 文档结构 (本 Feature)

```text
specs/001-install-entry-point/
├── spec.md              # 业务规格与需求定义
├── checklists/          # 需求与就绪检查清单
│   └── requirements.md
├── plan.md              # 实施技术方案计划（本文档）
├── research.md          # Phase 0 技术选型与调研论证
├── data-model.md        # Phase 1 实体模型与校验规则
├── contracts/           # Phase 1 接口与格式契约
│   ├── cli-interface.md
│   ├── config-schema.md
│   └── launchagent-service.md
├── quickstart.md        # Phase 1 端到端快速验证指南
└── tasks.md             # Phase 2 任务拆解清单（待生成）
```

### 源码结构演进映射

交付目标状态为全局 1:1 统一命名：

| 维度 | 当前基线状态 | Feature 交付目标状态 | 变更性质 |
| :--- | :--- | :--- | :--- |
| **CLI 命令** | `auto_mount` | `automnt` | 缩短并去下划线 |
| **核心源码** | `auto_mount.swift` | `automnt.swift` | 文件名重构 |
| **编译产物** | `auto_mount` | `automnt` | 二进制重构 |
| **唯一配置** | `auto_mount.plist` (多位置) | `~/Library/Application Support/automnt/automnt.plist` | 路径与文件名收敛 |
| **守护服务 Label** | `com.user.auto-mount` | `com.user.automnt` | 唯一标识变更 |
| **守护描述文件** | `com.user.auto-mount.plist` | `~/Library/LaunchAgents/com.user.automnt.plist` | 路径与内容变更 |
| **日志目录** | `~/Library/Logs/AutoMount` | `~/Library/Logs/automnt` | 目录全小写收敛 |
| **版本规划** | `2.7.4` | `3.0.0` (断代 MAJOR 架构重构) | 语义化版本晋级 |
| **GitHub 仓库** | `jiezhengj/AutoMount` | `jiezhengj/automnt` | 远端仓库更名 |

### 架构演进决策

1. **废弃旧双配置管理模块**：
   - 彻底删除源码中用于区分 `workspaceConfigURL` 与 `runtimeConfigURL` 的解析逻辑、内容等价性判定、差异提示以及双向同步；
   - 统一由 `activeConfigURL` 解析唯一活动路径。
2. **重构网络探测与策略评估管道**：
   - 移除 `RouteEntry`、`ARPParser` 及接口作用域 ARP 邻居提取逻辑；
   - 新增 `HostReachabilityProbe`，基于原生非阻塞 POSIX Socket 对目标端口 445 进行轻量 TCP 握手探测；
   - 引入 `EvaluationRetryRunner`，封装事件触发后的有限重试状态机。
3. **新增安装与命令入口管理器 (InstallationManager)**：
   - 封装路径自检测、搬迁复制与 `unlink` 原下载副本；
   - 封装 Shell profile 探测、带有安全定界符的代码段注入与精确逆向移除；
   - 封装 LaunchAgent plist 的生成（不含 `StartInterval`）与 `launchctl` 生命周期管理。
4. **资产全量重命名流水线 (Asset Renaming Pipeline)**：
   - 严格在 Phase 2（`tasks.md`）中拆解为原子任务，并在 Phase 3（`implement`）实施阶段执行；
   - 实施顺序：更新源码内部标识与单测 -> 将 `auto_mount.swift` 重命名为 `automnt.swift` -> 使用最高优化参数重新编译生成 `automnt` 二进制并验证自测 -> 全量更新公开技术文档 -> 提交代码并根据授权完成远端仓库更名与发布。

# 复杂度跟踪 (Complexity Tracking)

*无宪法违反项，无需记录复杂度妥协。*
