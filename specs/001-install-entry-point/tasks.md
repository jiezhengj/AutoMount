# Phase 1: Setup (Shared Infrastructure)

**Purpose**: 建立基础工程环境与临时测试沙箱

- [x] T001 建立 Feature 001 开发基线与临时验证工作区环境（确认 macOS 27 SDK、swiftc 编译器与当前基线 ./automnt --self-test 全绿） automnt.swift
- [x] T002 [P] 准备隔离测试环境变量与临时沙箱目录支持 automnt.swift

# Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: 核心基础架构与数据模型重构，阻塞所有后续用户故事

- [x] T003 重构配置路径解析为单活动配置模式：移除 workspaceConfigURL 与 runtimeConfigURL 双副本解析与双写同步，统一由 activeConfigURL 锁定规范路径 ~/Library/Application Support/automnt/automnt.plist automnt.swift
- [x] T004 实现数据模型迁移：定义 InstallState, Profile, MountTarget, RetryPolicy, AutomntConfig, ShellSnippet 实体结构，并废弃链路层相关字段（彻底清除 gateway_mac, router_ip, interface_name） automnt.swift
- [x] T005 实现主机可达性探测器 HostReachabilityProbe：使用 Darwin POSIX 原生非阻塞 Socket 对指定主机及端口（默认 445）发起 TCP 握手探测（支持超时参数，默认 1000ms） automnt.swift
- [x] T006 实现有限重试执行器 EvaluationRetryRunner：基于 RetryPolicy（默认最多 3 次，间隔 1000ms，总窗口上限 10000ms）封装事件唤醒后的有限重试状态机 automnt.swift
- [x] T007 实现 Shell profile 命令入口注入与还原工具：支持按行扫描定界标记 # >>> automnt CLI begin >>> 到 # <<< automnt CLI end <<<，实现幂等注入与精确剥离 automnt.swift

# Phase 3: User Story 1 - 首次安装与下载副本自清理 (Priority: P1) 🎯 MVP

**Goal**: 使用者运行预编译程序即可自动搬迁至规范目录 ~/Library/Application Support/automnt/bin/automnt，自动清理下载目录临时副本，并在 Shell 中注入命令入口，无需人工搬运或清理。

**Independent Test**: 在临时目录中运行二进制，验证其被搬迁到规范路径、当前运行副本被 unlink 清除、Shell 配置文件包含有效定界标记。

- [x] T008 [P] [US1] 在自测套件中添加自搬迁路径探测、unlink 下载副本及 Shell 注入定界标记的独立单元测试用例 automnt.swift
- [x] T009 [US1] 实现安装管理器 InstallationManager.relocateIfNeeded()：通过 CommandLine.arguments[0] 与 proc_pidpath 获取真实物理路径，若不在规范安装目录则执行拷贝并赋予 0755 权限，随后调用 POSIX unlink() 解除当前运行位置目录项 automnt.swift
- [x] T010 [US1] 实现 Shell 命令入口注入逻辑：按顺序检测 $HOME/.zshrc、$HOME/.bash_profile、$HOME/.bashrc，幂等写入 export PATH="$HOME/Library/Application Support/automnt/bin:$PATH" 定界块 automnt.swift
- [x] T011 [US1] 完善首次运行引导交互契约：若未检测到配置文件则自动唤醒初始化向导，输出安装完成状态摘要 automnt.swift

# Phase 4: User Story 2 - 日常运行与再次配置 (Priority: P1)

**Goal**: 交互命令与后台服务读写同一份物理配置，提供状态查询与向导管理。

**Independent Test**: 执行 --config 更改配置，检查后台服务与 CLI 查询的状态完全一致。

- [x] T012 [P] [US2] 在自测套件中添加单活动配置的日常读写、修改与 --status 状态查询测试用例 automnt.swift
- [x] T013 [US2] 实现 --status 查询命令：输出当前安装状态、守护服务注册状态、当前活动配置文件路径及已配置策略概况 automnt.swift
- [x] T014 [US2] 适配 --config 日常配置向导：移除双副本来源选择菜单，直接管理唯一活动配置 automnt.swift

# Phase 5: User Story 5 - 按主机可达性识别网络 (Priority: P1)

**Goal**: 废弃所有网关 MAC / ARP 链路层逻辑，全面转向基于目标主机服务可达性（TCP 445 端口直连）的网络策略匹配。

**Independent Test**: 配置指向真实或本地测试端口的策略，验证 TCP 握手成功时命中挂载，握手失败或超时时不命中并顺延至下一顺位。

- [x] T015 [P] [US5] 在自测套件中添加基于非阻塞 Socket 的主机可达性探测、IPv4/IPv6 主机名解析与超时逻辑的测试用例 automnt.swift
- [x] T016 [US5] 彻底清理旧链路层代码：删除 RouteEntry、ARPParser、网关 MAC 缓存及所有相关命令行展示与自测代码 automnt.swift
- [x] T017 [US5] 重构策略评估主循环：接入 HostReachabilityProbe，按顺序对策略中声明的 host 与 port（默认 445）发起探测，根据可达性判定策略命中 automnt.swift
- [x] T018 [US5] 更新配置向导录入逻辑：挂载目标仅能从当前系统挂载卷动态提取或向导手动输入，禁止要求输入网关 MAC 或网段扫描 automnt.swift

# Phase 6: User Story 7 - 由事件触发的评估与有限重试 (Priority: P1)

**Goal**: 后台守护服务彻底移除 StartInterval 定时轮询，改由系统网络配置变动与登录事件驱动唤醒；单次触发内对当前策略执行最多 3 次（上限 10 秒）的有限重试，平滑吸收握手延迟。

**Independent Test**: 检查 LaunchAgent plist 中不存在 StartInterval 键；模拟网络变动，确认有限重试在成功后立即挂载退出，全部失败后顺延下一顺位。

- [x] T019 [P] [US7] 在自测套件中添加 EvaluationRetryRunner 有限重试状态机用例（覆盖首次成功、重试后成功、超时熔断与顺延下一顺位） automnt.swift
- [x] T020 [US7] 重构 LaunchAgent 生成器：在 ~/Library/LaunchAgents/com.user.automnt.plist 中配置 RunAtLoad: true 与 WatchPaths（监听 NetworkInterfaces 与 airport plist），刚性禁止写入 StartInterval automnt.swift
- [x] T021 [US7] 实现事件触发评估工作流：接入 EvaluationRetryRunner，评估完成后立即正常退出，不驻留常驻循环；主动卸载后在无新网络变动前不重新挂载 automnt.swift

# Phase 7: User Story 3 - 升级 (Priority: P1)

**Goal**: 程序自行从发布源获取新版本预编译程序并原子替换规范路径二进制，全程免编译，保持单一副本与命令入口可用。

**Independent Test**: 模拟从更新源下载新版二进制，验证原子替换、权限保留、配置保持与失败回滚。

- [x] T022 [P] [US3] 在自测套件中添加三档更新信道（off, notify, auto）、预编译二进制原子替换与回滚测试用例 automnt.swift
- [x] T023 [US3] 重构更新管理器：支持从 GitHub Release 获取预编译二进制，直接替换规范安装路径 ~/Library/Application Support/automnt/bin/automnt，彻底删除原有现场编译源码的更新逻辑 automnt.swift

# Phase 8: User Story 4 - 卸载 (Priority: P2)

**Goal**: 执行卸载命令注销服务、精确剥离 Shell 入口、清理安装产物，默认保留配置文件并提供彻底清理选项。

**Independent Test**: 运行 --uninstall 验证服务注销、Shell 标记清除、二进制删除、配置保留；运行 --uninstall --purge 验证全目录彻底清除。

- [x] T024 [P] [US4] 在自测套件中添加常规卸载与 --purge 彻底卸载的模拟环境测试用例 automnt.swift
- [x] T025 [US4] 实现常规卸载 automnt --uninstall：执行 launchctl bootout 并删除 plist，调用 Shell 入口剥离工具清理 profile，删除安装目录二进制，保留配置文件并输出提示 automnt.swift
- [x] T026 [US4] 实现彻底卸载 automnt --uninstall --purge：在常规卸载基础上，彻底删除 ~/Library/Application Support/automnt/ 目录及其所有历史文件 automnt.swift

# Phase 9: User Story 8 - 安装状态校验与自愈 (Priority: P2)

**Goal**: 每次运行校验安装状态（安装位置唯一性、Shell 命令入口存在性、LaunchAgent 描述文件合规性），若不一致则自动幂等修复或输出修复命令。

**Independent Test**: 人工删除 Shell 注入标记或篡改 LaunchAgent plist，运行程序验证其自动恢复健康。

- [x] T027 [P] [US8] 在自测套件中添加 InstallState 健康度评估与轻量级自愈恢复用例 automnt.swift
- [x] T028 [US8] 实现自检与自愈控制器：程序启动时评估 InstallState，若 Shell 入口缺失则自动重新注入，若 LaunchAgent 被篡改则重新生成并加载，无法自动恢复时输出可直接复制的修复命令 automnt.swift

# Phase 10: User Story 6 - 从 2.7.4 旧形态切换 (Priority: P3)

**Goal**: 形成面向旧版本使用者的明确文档指引，说明先执行旧版卸载再安装新版，代码中不保留针对 2.7.4 的兼容或迁移分支。

**Independent Test**: 验证文档指引清晰可执行，且源码中无 2.7.4 特例迁移代码。

- [x] T029 [US6] 编写旧版本切换迁移指引文档，说明旧形态卸载与新形态安装步骤，明确旧配置不自动迁移的原则 specs/001-install-entry-point/quickstart.md
- [x] T030 [US6] 审计并彻底清理源码中所有针对旧版本的特例兼容分支，确保新形态逻辑单一纯粹 automnt.swift

# Phase 11: User Story 9 - CLI 命令简化与全局统一命名 automnt (Priority: P1)

**Goal**: 全链路 1:1 统一重命名为 automnt，源码文件为 automnt.swift，可执行二进制为 automnt，配置为 automnt.plist，服务为 com.user.automnt，日志为 ~/Library/Logs/automnt，GitHub 仓库名为 automnt，清除所有历史称谓。

**Independent Test**: 全项目全局检索 auto_mount 与 AutoMount 出现次数为 0，终端直接输入 automnt 正常执行，./automnt --self-test 全量通过。

- [x] T031 [US9] 更新源码内部所有标识符、日志输出、用户提示与常量定义为 automnt，版本号设置为 3.0.0 automnt.swift
- [x] T032 [US9] 更新内置自测套件中所有测试用例的断言与路径期望为 automnt 与 3.0.0 automnt.swift
- [x] T033 [US9] 执行源码重命名：将生产源码文件 automnt.swift 重命名为 automnt.swift automnt.swift
- [x] T034 [US9] 本地重新编译构建：在 macOS 27 环境下使用最高优化参数重新编译生成 automnt 可执行二进制（/usr/bin/swiftc -O -sdk $(xcrun --show-sdk-path) automnt.swift -o automnt） automnt
- [x] T035 [US9] 执行本地全量自动化自测：运行 ./automnt --self-test，确保所有用例 100% 绿灯通过 automnt
- [x] T036 [US9] 全量改写公开技术文档与项目规则中的历史称谓：将 README.zh.md、README.en.md、ARCHITECTURE.zh.md、ARCHITECTURE.en.md、AGENTS.md 中的 auto_mount 与 AutoMount 统一更名为 automnt README.zh.md
- [x] T037 [US9] 全仓库历史称谓清除审计：全量扫描仓库文件，确认 auto_mount 与 AutoMount 残留次数为 0 automnt.swift

# Phase 12: Polish & Cross-Cutting Concerns

**Purpose**: 最终质量核验与端到端验证

- [x] T038 执行 specs/001-install-entry-point/quickstart.md 中定义的全部 7 个端到端验证场景 specs/001-install-entry-point/quickstart.md
- [x] T039 运行 Speckit Analyze 技能对 spec、plan、tasks 产物进行最终一致性检查 specs/001-install-entry-point/tasks.md

# Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: 无依赖，可立即启动
- **Foundational (Phase 2)**: 依赖 Setup 完成，阻塞所有 User Story 实现
- **User Stories (Phase 3 - Phase 11)**: 依赖 Foundational 完成
  - US1 (首次安装) 构成最小可行产品 MVP
  - US2、US5、US7 紧随 US1 构成完整核心运行时
  - US3、US4、US8 提供全生命周期管理
  - US6 清理旧版本包袱
  - US9 执行最终的全局资产重命名与二进制交付
- **Polish (Phase 12)**: 依赖全部 User Story 任务完成

### User Story Dependencies

- **User Story 1 (P1)**: 依赖 Phase 2，无其他 Story 依赖
- **User Story 2 (P1)**: 依赖 US1（规范安装目录已就绪）
- **User Story 5 (P1)**: 依赖 Phase 2（HostReachabilityProbe 已具备）
- **User Story 7 (P1)**: 依赖 US5（策略可达性判据已就绪）
- **User Story 3 (P1)**: 依赖 US1（规范安装路径已确立）
- **User Story 4 (P2)**: 依赖 US1、US7（LaunchAgent 与 Shell 入口可逆向清理）
- **User Story 8 (P2)**: 依赖 US1、US7（InstallState 与守护服务定义已确定）
- **User Story 6 (P3)**: 依赖 US1、US2、US5（新形态已完整确立）
- **User Story 9 (P1)**: 依赖所有业务功能就绪后，执行全链路原子重命名与重新构建

# Parallel Opportunities

- T002 临时沙箱配置可与 T001 并行
- T008 (US1 测试)、T012 (US2 测试)、T015 (US5 测试)、T019 (US7 测试)、T022 (US3 测试)、T024 (US4 测试)、T027 (US8 测试) 单元测试编写可并行
- 文档更新与清理可在代码重命名后由不同任务分块执行

# Implementation Strategy

### MVP First (User Story 1 Only)

1. 完成 Phase 1: Setup
2. 完成 Phase 2: Foundational（关键基石）
3. 完成 Phase 3: User Story 1（首次安装与下载副本自清理）
4. 验证 User Story 1 独立运行

### Incremental Delivery

1. 完成 Setup + Foundational -> 基石就绪
2. 交付 US1（首次安装） -> MVP 达成
3. 交付 US2 + US5 + US7 -> 核心网络挂载流水线就绪
4. 交付 US3 + US4 + US8 -> 生命周期与韧性自愈就绪
5. 交付 US6 -> 文档与纯粹性审计就绪
6. 交付 US9 -> 全局命名统一 automnt、编译预编译二进制、运行自测
7. 交付 Polish -> 验证全场景与一致性分析
