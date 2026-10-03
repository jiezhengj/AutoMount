# Phase 1: Setup (Shared Infrastructure)

**Purpose**: 准备开发基线与隔离自测环境

- [X] T001 准备 Feature 002 开发基线与验证工作区环境（确认 Swift 6.4 编译环境与当前基线 ./automnt --self-test 全绿） automnt.swift
- [X] T002 [P] 扩展自测环境配置支持隔离注入临时配置文件路径与模拟 TTY 属性 automnt.swift

# Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: 核心数据模型重构、校验引擎升级、挂载点推导、termios 输入引擎、卷宗发现器及顺位探测执行器，阻塞所有后续用户故事

- [X] T003 重构核心配置数据模型：按 data-model.md 与 contracts/config-schema.md 定义 HostConfig 与 SMBShareConfig 实体，在 AutomntConfig 中引入 hosts 列表并保留编译兼容桥接，确保单文件构建与自测持续全绿 automnt.swift
- [X] T004 升级配置文件校验引擎 inspectConfigFile()：消除对 profiles.isEmpty 的强制依赖，支持解析与识别 hosts，并将合法的 0 台主机判定为 .usable 状态 automnt.swift
- [X] T005 实现 SMB URL 单一真理挂载点推导算法 deriveStandardMountPoint(from:)：从标准 URL 提取真实共享名称，统一推导为 /Volumes/<shareName>，根除本地 -1 临时冲突后缀并保护 data-1 等合法数字共享 automnt.swift
- [X] T006 实现基于 Darwin POSIX termios 的轻量级行输入引擎 promptLineWithEsc(prompt:)：支持单字符捕获、ASCII 27 (Esc) 清行安全回退、退格擦除，并通过 isatty(STDIN_FILENO) 实现非 TTY 环境自动流式降级 automnt.swift
- [X] T007 实现内核挂载表卷宗聚合与候选主机倒推逻辑 discoverCandidateHosts()：快照读取活跃 smbfs 卷宗，按服务器地址聚合为候选物理主机结构并提取从属共享 automnt.swift
- [X] T008 重构核心运行时排他探测主执行器：按 hosts 列表顺位自上而下探测，首个连通主机执行挂载并立即短路终止探测（排他性短路，绝不并发挂载备用主机），并在 0 台主机时记录静默休眠信息以退出码 0 安全退出 automnt.swift

# Phase 3: User Story 1 - 首次向导的主机优先、循环登记与部署意愿遵从 (Priority: P1) 🎯 MVP

**Goal**: 使用者运行 automnt --init 时，优先根据活跃卷宗倒推候选主机，直接接入 promptLineWithEsc 支持下钻多选名下共享、保存后返回候选列表展示 [✓] 已配置 防重标记、支持循环录入备选主机或跳过主机设置，并在向导末尾严格遵从用户的后台服务部署意愿。

**Independent Test**: 运行向导完成多主机顺位配置并立即触发挂载，末尾选择 n（暂不部署），验证生成包含多主机的配置文件、首个可达主机成功挂载且 LaunchAgent 未被安装注册。

- [X] T009 [P] [US1] 在自测套件中添加候选主机聚合倒推、多主机循环登记防重标记及跳过主机流程的测试用例 automnt.swift
- [X] T010 [US1] 重构首次初始化向导 runInitWizard()：调用 discoverCandidateHosts() 呈现候选主机列表，直接接入 promptLineWithEsc 提示可选别名（回车默认采用主机地址，杜绝旧版 id 与描述双重输入）并下钻多选从属共享 automnt.swift
- [X] T011 [US1] 实现向导循环登记与防重流转状态机：主机保存后标记 isConfigured = true 并返回候选列表，展示 [✓] 已配置 且禁止重复选择，支持继续选择备选主机或按 d 完成 automnt.swift
- [X] T012 [US1] 实现向导跳过主机配置分支：候选列表选择 [s] 时不强制录入任何主机，直接流转至更新策略设置并允许生成空主机配置 automnt.swift
- [X] T013 [US1] 修复 main() 首次向导拉起分支的后台服务强装缺陷：接收向导返回的部署标志位，用户选择暂不部署时仅保存配置安全退出，坚决不调用 installLaunchAgent() automnt.swift

# Phase 4: User Story 2 - 根除挂载点命名污染与临时后缀误伤 (Priority: P1)

**Goal**: 无论是扫描导入还是手动添加，挂载点路径始终以 SMB URL 为单一真实来源推导为 /Volumes/<ShareName>，彻底消除 -1、-2 临时后缀，并 100% 保护合法带数字共享名。

**Independent Test**: 输入形如 /Volumes/Public-1（实际 URL 为 smb://host/Public）的卷宗与合法带数字共享 smb://host/data-1，验证配置中分别严格为 /Volumes/Public 与 /Volumes/data-1。

- [X] T014 [P] [US2] 在自测套件中添加挂载点规整净化与合法带数字名称保护的单元测试用例 automnt.swift
- [X] T015 [US2] 在向导与配置共享导入全链路接入 deriveStandardMountPoint，阻断直接读取本地冲突挂载点写入配置的所有路径 automnt.swift

# Phase 5: User Story 3 - 日常配置管理与向导交互流统一 (Priority: P2)

**Goal**: 日常配置命令 automnt --config 与首次向导共享底层主机交互引擎，提供主机顺位调整、名下共享追加、共享删除维护，以及未挂载新主机的手动录入与钥匙串温和提示。

**Independent Test**: 执行 automnt --config 依次测试进入主机删除共享、追加共享、调整顺位、手动添加未挂载主机并接收钥匙串提示。

- [X] T016 [P] [US3] 在自测套件中添加日常配置主菜单流转、共享增删维护与顺位调整逻辑的测试用例 automnt.swift
- [X] T017 [US3] 重构日常配置菜单 runConfigMenu()：统一以主机顺位列表为核心视图，直接接入 promptLineWithEsc 提供进入主机管理共享、新增主机、调整顺位与删除主机操作 automnt.swift
- [X] T018 [US3] 实现子菜单共享生命周期维护：支持查看已配置共享、输入编号删除已有共享、从当前活跃卷宗追加共享，以及重复添加防呆提示 automnt.swift
- [X] T019 [US3] 实现手动录入未挂载主机与共享交互流：支持键入主机 IP/域名、提示可选别名（回车默认主机地址，严禁索取底层 id）与从属共享路径，进行 445 端口可达性检测与离线警示确认，并在末尾展示克制的钥匙串密码温和提示 automnt.swift

# Phase 6: User Story 4 - 全局文本输入支持 Esc 键放弃并安全回退 (Priority: P2)

**Goal**: 在向导与日常管理的任何文本输入环节，按下 Esc 键均可立即清空行缓冲并平稳回退上一级菜单，不留存脏数据，非 TTY 环境安全回退。

**Independent Test**: 在终端各输入提示行按下 Esc 键，验证终端输出 (已取消) 并平稳返回上级菜单。

- [X] T020 [P] [US4] 在自测套件中添加模拟键盘输入流包含 ASCII 27 (Esc) 时的行清除与 nil 返回测试用例 automnt.swift
- [X] T021 [P] [US4] 在自测套件中添加退格擦除回显序列、ANSI 控制字符与非 TTY 管道流式降级的边界测试用例 automnt.swift
- [X] T022 [US4] 验证并强化向导与日常管理所有文本输入点对 nil 取消返回值的安全捕获与平稳回退，杜绝任何未处理异常 automnt.swift

# Phase 7: User Story 5 - 允许空配置与后台安全休眠 (Priority: P3)

**Goal**: 解绑 0 台主机与配置损坏（.invalid），允许用户删空主机并保存，后台服务被网络事件唤醒时识别到空配置记录一条静默休眠日志后以退出码 0 安全退出。

**Independent Test**: 删除所有主机保存配置，执行 automnt 验证退出码严格为 0，且终端显示安全休眠日志。

- [X] T023 [P] [US5] 在自测套件中添加 0 台主机配置解析、文件状态评估与安全休眠退出的测试用例 automnt.swift
- [X] T024 [US5] 完善日常管理删空所有主机的保存交互与安全休眠退出工作流 automnt.swift

# Phase 8: User Story 6 - 存量配置平滑升舱与历史数据洗涤 (Priority: P3)

**Goal**: 启动加载配置时自动嗅探旧版 profiles 结构，无损映射原描述为 alias，继承超时与防索引保护设置，自动清洗受 -1 污染的历史挂载路径，并原子原地写回 automnt.plist。

**Independent Test**: 注入一份旧版 v3.0.0 配置（含描述、超时、防索引及带 -1 共享路径），执行命令验证其被自动原地规整为 v3.1.0 规范，历史 -1 路径被清洗还原。

- [X] T025 [P] [US6] 在自测套件中添加从旧版 profiles 结构到新版 hosts 结构的升舱解码、字段继承与挂载路径清洗的测试用例 automnt.swift
- [X] T026 [US6] 实现配置原地升舱引擎 migrateConfigIfNeeded()：在读取 plist 时检测 profiles，执行字段映射、无损继承与路径清洗，以原子方式原地写回新版规范 automnt.swift

# Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: 版本真理晋级、全量自测套件集成与端到端验证

- [X] T027 晋级版本真理来源：将 automnt.swift 顶部的 let automntVersion = "3.0.0" 晋级为 3.1.0，确保配置、控制台输出与构建版本同源 automnt.swift
- [X] T028 [P] 扩展全量自动化自测套件：在 automnt --self-test 中串联新增的所有单元测试，确保回归测试 100% 通过 automnt.swift
- [X] T029 执行 quickstart.md 中定义的全部 6 项端到端可执行验证场景，验证向导、日常管理、挂载净化、Esc 取消、空配置休眠与平滑升舱 automnt.swift

# Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: 无前置依赖，可立即开始。
- **Foundational (Phase 2)**: 依赖 Phase 1 完成，重构数据模型、校验引擎、算法、输入行、卷宗发现与主执行器，阻塞所有后续用户故事实施。
- **User Stories (Phase 3 ~ Phase 8)**: 均依赖 Phase 2 完成。
  - P1 级故事（US1、US2）优先实施并交付 MVP；
  - P2 级故事（US3、US4）基于统一交互引擎与输入行扩展；
  - P3 级故事（US5、US6）完善状态机与存量兼容；
- **Polish (Phase 9)**: 依赖所有用户故事实施完成，执行全量自测与端到端验证。

### User Story Dependencies

- **User Story 1 (P1)**: 依赖 Phase 2 基础数据模型、校验引擎与执行器，直接调用 termios 输入引擎完成向导与部署控制。
- **User Story 2 (P1)**: 依赖 Phase 2 挂载点推导算法，与 US1 在向导录入中协同生效。
- **User Story 3 (P2)**: 依赖 Phase 2 与 US1 中的主机交互流，扩展日常管理菜单。
- **User Story 4 (P2)**: 依赖 Phase 2 termios 行输入引擎，强化边界用例与回归测试。
- **User Story 5 (P3)**: 依赖 Phase 2 数据模型与校验引擎，完善删空主机流转。
- **User Story 6 (P3)**: 依赖 Phase 2 数据模型与挂载点推导算法，实现存量配置升舱。

# Parallel Opportunities

- Phase 1 中的 T002 可与 T001 并行；
- Phase 2 中的 T005（挂载点推导）与 T006（termios 输入引擎）可并行开发；
- 各用户故事中带有 [P] 标记的自测套件用例开发任务可与实现准备并行；
- Phase 9 中的 T028 自测扩展可与版本号晋级并行。

# Implementation Strategy

### MVP First (User Story 1 & 2)

1. 完成 Phase 1 (Setup) 与 Phase 2 (Foundational) 核心基础架构、校验引擎与运行时执行器；
2. 完成 Phase 3 (US1 首次向导) 与 Phase 4 (US2 挂载点净化)；
3. 执行独立验证：验证向导支持点选卷宗生成无 -1 污染的配置，直接运行 automnt 成功挂载，且选择暂不部署时绝不安装 LaunchAgent；
4. 此时系统已具备真正可挂载、可配置、无污染的完整 MVP 可用形态。

### Incremental Delivery

1. 增量引入 Phase 5 (US3 日常管理统一) 与 Phase 6 (US4 Esc 输入边界保障)；
2. 增量引入 Phase 7 (US5 空配置休眠) 与 Phase 8 (US6 存量平滑升舱)；
3. 最终进入 Phase 9 完成版本晋级（v3.1.0）、全量自测回归与 quickstart 端到端验证。

# Phase 10: Convergence

- [X] T030 修复向导末尾后台服务部署意愿确认中 Esc 键取消被误判为同意安装的边界缺陷，在 promptLineWithEsc 返回 nil 时坚决默认跳过部署 per FR-005, FR-006, US1/AC4 (contradicts)

- [X] T031 修复日常配置管理中删空主机后保存退出确认中 Esc 键取消被误判为确认保存退出的边界缺陷，在 promptLineWithEsc 返回 nil 时默认取消退出并留在配置循环 per FR-005, US4, US5 (contradicts)

- [X] T032 增强 TerminalUI.readByte 对 STDIN 流 EOF (Ctrl+D 或管道断开) 与错误返回值的检测，避免在未提供字符时进入 b==0 无限自旋循环 per FR-005, US4 (partial)
