**Slug**: init-wizard-ux
**Created**: 2026-10-03
**Evidence confidence (overall)**: high

# 用户与需求

- **直接受影响者**：项目维护者及使用该工具挂载 NAS 的 Mac 终端用户。在测试 v3.0.0 初始化向导与日常配置时，发现交互逻辑出现多处严重倒退与认知陷阱。— [source: 会话记录、真实终端日志] (confidence: high)
- **痛点集中在四个交互阶段**：
  1. 首次初始化向导：已挂载卷宗列表混杂、无视同源性、未加去重，极易误选远程 IP 并固化 `-1` 冲突后缀；
  2. 概念模型脱节：上层死抱“网络策略”、“局域网直连”、“远程降级”等陈旧工程术语，而底层早已演进为基于 TCP 445 端口的主机顺位探活；
  3. 日常配置割裂：新增主机与新增挂载目标退化为强制手动敲 IP/URL，两张皮现象严重；
  4. 终端操控陷阱：全系统手动输入无法通过 Esc 键放弃退出，逼迫用户敲回车或按 Ctrl+C 强退；
  5. 意愿被无视：向导中选择“暂不部署后台服务”，退出后依然被硬编码强行注册。— [source: 会话记录、`automnt.swift` 源码分析] (confidence: high)
- **确立的核心业务需求**：顺位探测的排他性是用户的刚性业务原则——首个顺位通畅则挂载并立即终止，后续备用顺位哪怕连通也坚决不自动挂载。— [source: 维护者明确指示] (confidence: high)

# 先例与历史代码深度溯源

- **历史先例一（v2.4.0 与“网络排他门牌”设计）**：
  - 在 commit `0aee581` 和 `c0722e6`（v2.4.0）中，项目曾明确引入“网络排他门牌（Exclusion Gatekeeper）”机制：`home_lan` 即使配置 0 个挂载目标，只要匹配成功，就起到排他阻断作用，严禁执行后续的远程策略。
  - 这证明维护者强调的“在家即使远程可达也不挂载、顺位排他”是本项目长久以来一以贯之的单一真理与核心需求，绝非 bug。— [source: git commit 0aee581, c0722e6, README.zh.md (v2.4.0)] (confidence: high)
- **历史先例二（v2.5.0 的成熟勾选导入与路径推导）**：
  - 在 commit `0ea26f2`（v2.5.0）中，`manageMountTargets` 早已实现了“自动嗅探系统活动 SMB 挂载并使用 `promptInteractiveCheckbox` 批量勾选导入（支持 Space 切换、a 全选、Enter 确认、Esc 跳过）”；
  - 同时实现了 `deriveDefaultMountPath(from:)` 函数，自动从 SMB URL 截取共享名并合成 `/Volumes/<share>` 默认路径；
  - （注：当年该版本曾包含 `findTailscaleBinary()` 专属嗅探，但事实证明这是走向特定厂商耦合的历史弯路；本次架构已明确彻底废弃该特化分支，绝不恢复）。
  - **倒退成因证实**：v3.0.0 在重构单一活动配置与 TCP 445 探活时，重写了 `--config`，却把 v2.5.0 已经做好的卷宗嗅探复选和路径推导彻底遗漏，退化成了简陋的裸调 `readLine()`。— [source: git show 0ea26f2:auto_mount.swift:459-485, 2315-2345] (confidence: high)
- **历史先例三（向导强塞服务注册 Bug 的引入点）**：
  - `runInitWizard`（1448 行）正确提供了“仅保存配置，暂不部署”交互分支，但在 v3.0.0 的 `main()` 入口第 2821 行，被无条件硬编码添加了 `installLaunchAgent()`，导致用户意愿被直接践踏。— [source: `automnt.swift:1448-1466, 2819-2824`] (confidence: high)

# 市场与现状

- **macOS 系统挂载重名与残留机制**：
  - 外部事实：macOS 在网络闪断、未正常卸载或同一 NAS 经由不同通道（如 LAN mDNS 与 Tailscale IP）并发连接时，`/Volumes/` 目录会因旧挂载点被占用而自动为后继连接命名为 `/Volumes/<ShareName>-1`、`-2` 等；
  - 行业现状：商业软件如 AutoMounter、ConnectMeNow 均重点解决该机制引发的重复卷宗问题；
  - 规整方案：严禁用正则去粗暴裁剪本地目录名（会误伤如 `project-1` 等合法共享名）；唯一可靠解是以 SMB 协议 URL 为单一真理，提取 URL 路径首段的真实共享名，标准化映射为 `/Volumes/<真实共享名>`。— [source: Apple Discussions, SuperUser, Backblaze KnowledgeBase, AutoMounter 架构] (confidence: high)
- **macOS Keychain（钥匙串）认证机制**：
  - 外部事实：macOS 的系统级 SMB 挂载框架（`NetFSMountURLSync`）在无交互静默调用时，完全依赖系统钥匙串中以 `hostname/IP` 为键索引的“网络密码”；
  - 现实困境：同一台 NAS，用户在 Finder 中若仅通过主机名（如 `dx4600.local`）连接并记住密码，系统钥匙串并不会自动同步到其 IP 地址（如 Tailscale IP `100.113.x.x`）。因此新 IP 在静默挂载时会因缺少凭证直接报错返回 `-5000`；
  - 引导原则：在用户手动录入未挂载的新 IP 时，给予一次性温和指引；对于从已挂载卷宗倒推的主机，因系统已有凭据，坚决不作提示。— [source: Apple Developer Documentation, Reddit MacSysAdmin, SuperUser] (confidence: high)

# 数据与约束

- **终端 POSIX Raw 模式与 Esc 监听机制**：
  - 技术事实：系统标准 `readLine()` 工作于规范模式（Canonical Mode），由系统终端缓冲整行直到回车换行，程序根本无法捕获单独的 ASCII 27 (`Esc`) 键；
  - 解决方案：必须通过 POSIX `termios` API 关闭 `ICANON` 与 `ECHO`（即 Raw Mode），配合单字节 `read(STDIN_FILENO, &byte, 1)`。当捕获到字节 27 且未紧随 `[` 等转义序列时，判定为 Esc 取消，立即清空当前行并返回 `nil`；
  - 本机验证：`automnt.swift` 现有的 `TerminalUI.setRawMode` 已具备 termios 底座，只需在此基础上封装一个支持退格、字符回显与 Esc 拦截的轻量行读取函数 `promptLineWithCancel` 即可全系统复用。— [source: POSIX termios 规范, Swift CLI Terminal Raw Mode 实践] (confidence: high)
- **空配置状态机合法化约束**：
  - `inspectConfigFile`（第 400 行）目前将 `!config.profiles.isEmpty` 硬编码为 `.usable` 的前置条件，导致 0 台主机时配置文件直接被判为 `.invalid`（损坏）；
  - 调整方案：将“配置结构完整且语法正确”判定为 `.usable`，允许 `profiles` 数组为空。当主机列表为空时，后台守护服务记录休眠日志并以状态码 0 干净退出；前台运行则友好提示添加主机。— [source: `automnt.swift:399-411, 2815-2832`] (confidence: high)
- **主机优先（Host-First）模型的通用性**：
  - 调研确认：无需在向导或配置中专门保留 Tailscale CLI 的特殊分支（此前 v2.5.0 的 `findTailscaleBinary` 虽能探测，但增加了对特定客户端的耦合）；
  - 无论是本地局域网、Tailscale、WireGuard 还是 DDNS 域名，在底层统统表现为一个标准主机（IP/域名 + 445 端口），全面消除特化逻辑。— [source: 架构审查与维护者指示] (confidence: high)

# 反对这个想法的证据

- **对“打破排他顺位”的彻底否定**：
  - 前期审计中曾推测“单策略 break 导致无法挂载多台 NAS 属于 Bug”，但深度调研 Git 历史（v2.4.0 排他门牌设计）和维护者指示表明，排他性是本工具的核心安全与整洁保障。打破排他性将导致家里高速网络与远程穿透链路发生冲突，该推断被证据完全推翻。— [source: git commit 0aee581, 维护者明确指示] (confidence: high)
- **直接废除配置文件旧字段的风险**：
  - 现有用户的 `automnt.plist` 中广泛存在 `profiles`、`local_lan`、`remote_network` 以及可能残留的 `-1` 挂载路径；
  - 激进的 Schema 变更可能导致存量用户配置无法加载；必须在 `migrateConfigIfNeeded` 中实现平滑的在机原地升级与挂载路径规范化净化。— [source: `automnt.swift:519-595`] (confidence: high)

# 遗留疑问与未知项

- [NEEDS CLARIFICATION: 原地配置迁移（In-Place Migration）：对于已存在于存量配置中带有 `/Volumes/xxx-1` 的挂载点，升级程序是否应当自动比对并重写为其标准推导路径 `/Volumes/xxx`？]
- [NEEDS CLARIFICATION: POSIX termios 行编辑器的边界处理：在开启 Raw 模式读取字符时，对常见的中文字符（多字节 UTF-8）退格处理与输入体验的最小化安全实现。]

# 来源清单

- 本机 Git 历史提交与标签：
  - `commit 0aee581` (feat: support empty LAN gatekeeper profile, streamlined Tailscale setup)
  - `commit c0722e6` (feat(release): bump version to v2.4.0 with generic profile decoupling)
  - `commit 0ea26f2` (feat: upgrade to v2.5.0 with full terminal UI navigation and profile pipeline management)
  - `commit 5849dfd` (revert: 回滚到 v2.7.4，撤销 Homebrew 改造)
  - `commit edf17d5` (feat: 发布 automnt 3.0.0，重构为单一活动配置、TCP 445 探活)
- 外部官方与技术文献（通过联网调研验证）：
  - macOS NetFS 挂载机制与钥匙串行为：Apple Developer Documentation / Discussions
  - macOS 重名卷宗 `-1` 排重冲突与残留机制：Apple Discussions / SuperUser / Backblaze KB
  - POSIX termios Raw Mode 与 CLI 键盘事件拦截：POSIX.1-2017 termios spec / Swift CLI Terminal 实践
- 本机源码与评估档案：
  - `automnt.swift` 源码全文
  - [`.specify/assessments/init-wizard-ux/intake.md`](file:///Users/jiezhengj/Documents/Project/automnt/.specify/assessments/init-wizard-ux/intake.md)
