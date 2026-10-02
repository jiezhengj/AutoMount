**Slug**: install-entry-point
**Created**: 2026-10-02
**Evidence confidence (overall)**: medium

# 用户与需求

- 唯一能直接观察到的受影响者是项目维护者本人：本机同时存在"下载区"和"安装区"两份程序、两份配置，维护者在 2026-10-02 的会话中把它列为要解决的问题。— [source: 会话记录；本机仓库与安装状态] (confidence: high)
- 痛点有两个具体表现：删除下载区后失去配置入口；保留下载区则要长期处理两边版本与配置是否一致。— [source: 会话记录] (confidence: high)
- 分发对象是少量朋友，他们没有编译 Swift 源码的条件，只能直接使用预编译二进制。— [source: 会话记录（维护者口述）] (confidence: medium)
- 没有外部反馈渠道可查（无 issue、无讨论区数据、无使用统计）。— [source: 仓库状态] (confidence: medium)

# 先例

- 内部先例一：2.2.0 至 2.7.4 的安装形态为"下载区 + 安装区"。安装时把程序、源码和配置三份文件复制到 `~/Library/Application Support/AutoMount/`；升级时下载 `.swift` 源码并在用户机器上编译，然后同步两边。— [source: auto_mount.swift:3543-3549、4764、5022] (confidence: high)
- 内部先例二：2026-10-01 引入包管理器安装形态，2026-10-02 回滚。回滚的技术原因已核实：该形态下服务定义由包管理器生成，而包管理器的服务描述能力不含"网络配置变化"触发，服务只剩周期触发。— [source: /opt/homebrew/Library/Homebrew/service.rb 的 plist 生成清单；会话记录] (confidence: high)
- 内部先例三：项目宪法已规定"每个用户配置只有一个活动来源"与"不得要求用户机器现场编译源码"，而现版本的自更新（下载源码 + 在本机编译）与后者直接冲突。— [source: .specify/memory/constitution.md 原则 III、IV；auto_mount.swift:4764] (confidence: high)
- 外部先例：多数 macOS 命令行工具由程序自身注册后台服务并提供命令入口，而不是把服务交给包管理器；该说法没有取得可引用来源。— [ASSUMPTION] (confidence: low)

- 外部先例（官方文档）：包管理器的官方文档完整列出"服务块"可用选项（执行命令、运行类型、间隔、定时、保活、登录时运行、是否需要 root、环境变量、工作目录、根目录、输入、日志、重启延迟、停止超时、节流间隔、进程类型、旧式定时器、socket、优先级、服务名），全页不含"监听路径变化"这一能力。— [source: docs.brew.sh/Formula-Cookbook（host: docs.brew.sh，policy: confirmed-by-user）] (confidence: high)
- 外部先例（官方文档）：Apple 的公证流程说明——公证为 Gatekeeper 提供票据，用户首次安装或运行软件时 Gatekeeper 依据票据决定是否显示启动提示；可公证的交付物包括应用、非应用 bundle、磁盘映像和扁平安装包。— [source: developer.apple.com/documentation/security/notarizing-macos-software-before-distribution（host: developer.apple.com，policy: confirmed-by-user）] (confidence: high)

# 市场与现状

- 今天用户实际可选的形态：手动解压后运行安装（现状）；安装包管理器再安装（已实测会失去网络变化触发）；不安装只手动挂载（失去自动挂载价值）。— [source: 本仓库形态；本机实测] (confidence: high)
- 不做改变的代价：每次发版都要处理两边同步；使用者需要重新走一遍安装；维护者无法确定对方正在运行哪一份。— [ASSUMPTION，基于现有代码结构推断] (confidence: medium)
- 平台侧趋势：macOS 对未签名程序与系统能力的限制在收紧（本机 27.2 已实测到链路层信息读取受限）。— [source: 本机对照实验] (confidence: high)

# 数据与约束

- 配置解析规则：配置路径等于"当前运行的可执行文件所在目录 + `auto_mount.plist`"，并会解析符号链接；因此从不同目录运行会读到不同配置。— [source: auto_mount.swift:48-80] (confidence: high)
- 安装复制三份文件到安装目录：程序、源码、配置。— [source: auto_mount.swift:3543-3549] (confidence: high)
- 网络变化触发依赖"程序自己写服务描述文件"：自写的 LaunchAgent 含 `RunAtLoad`、`StartInterval=60` 与 `WatchPaths=[/Library/Preferences/SystemConfiguration, 配置路径]`。— [source: auto_mount.swift:3524-3536] (confidence: high)
- 包管理器的服务描述能力不含 `WatchPaths`：本机包管理器源码生成的服务描述键为程序参数、`RunAtLoad`、`StartInterval`、`KeepAlive`、进程类型、工作目录、日志路径等，无变化监听项。— [source: /opt/homebrew/Library/Homebrew/service.rb] (confidence: high)
- 发布资产已具备："下载预编译二进制"这条更新通道在现有发布流程里已经可用（对应 Release 含预编译二进制资产，739,896 字节）。— [source: gh release view 对应版本] (confidence: high)
- 自更新现状：从代码托管站点下载 `.swift` 源码，再用系统编译工具在本机编译。— [source: auto_mount.swift:4764、5022] (confidence: high)
- 命令入口事实：系统默认路径列表首项是 `/usr/local/bin`；本机该目录属 `root:wheel`，普通用户不可写；`~/bin` 与 `~/.local/bin` 不在系统默认路径里（本机出现该目录来自用户自己配置）。— [source: /etc/paths、目录属性实测] (confidence: high)
- 未签名程序的能力限制：本机 macOS 27.2 上，非 Apple 签名的本机编译程序读不到 ARP/邻居表（普通局域网 TCP 连接正常；由 launchd 直接启动的 Apple 签名工具可读）。任何不改变签名或权限的安装形态都会保留这条限制。— [source: 2026-10-02 本机对照实验] (confidence: high)
- 首次运行拦截：带隔离标记的未签名二进制在直接执行时未被拦截（实测返回正常）；系统评估工具对纯命令行程序的判定对官方自带程序同样返回拒绝，因此不能作为用户可见拦截的证据；由图形界面双击触发的路径未实测。— [source: 本机实测与官方工具对照] (confidence: medium)
- 服务身份约束：后台服务以当前登录用户身份运行，不需要 Root 权限。— [source: .specify/memory/constitution.md 项目约束] (confidence: high)

- 平台对本地网络访问的放行规则（官方文档）：系统自动放行三类程序——由 launchd 启动的系统级守护进程、以 root 运行的程序、从终端或 SSH 运行的命令行工具及其子进程；同时明确"系统级守护进程的豁免不适用于用户级代理"。文档还说明程序身份按代码签名跟踪，并建议使用 Apple 颁发的签名身份。文档未提及链路层（邻居表）信息读取。— [source: developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy（host: developer.apple.com，policy: confirmed-by-user）] (confidence: high)

- 补充实测（2026-10-02）：把同一个探测程序用**免费 Apple 开发者证书**（Apple Development，本机钥匙串中已有 3 个有效身份）重新签名后再运行，邻居表仍然返回 **0 条**，与临时签名结果相同。→ 免费签名不足以恢复该能力。— [source: 本机对照实验] (confidence: high)
- 补充实测（2026-10-02 复核）：由 launchd 代为执行系统自带的地址解析工具，仍能读到完整邻居表（17 条，含网关条目）；调用方是本机编译程序，未使用 root，也未使用签名。对照：同一个本机编译程序自行派生同一工具，结果为 0 条。→ 存在"无需 root、无需签名"的可获得路径。— [source: 本机对照实验] (confidence: high)
- 补充实测（2026-10-02）：通过 LaunchServices 打开带隔离标记的未签名命令行程序时，调用返回用户取消类错误且程序未被执行；系统日志中未见相关判定记录，因此**无法区分**是安全机制拦截还是缺少图形交互上下文导致失败。该项未验证。— [source: 本机实测] (confidence: low)

# 反对这个想法的证据

- 双份问题的根因可能只在安装流程与配置解析规则，不必然需要更换分发渠道；直接改分发方式可能把范围放大。— [source: auto_mount.swift:48-80、3543-3549] (confidence: medium)
- 更换分发渠道一旦引入外部所有者，就可能丢失平台能力，这一失败模式已经在本项目上发生过一次。— [source: 本机实测与包管理器源码] (confidence: high)
- 需求信号薄弱：目前可见的受影响者只有维护者与少量朋友，没有工单或使用数据支持一次分发改造。— [source: 会话与仓库状态] (confidence: medium)
- 如果目标包含"下载后首次运行完全不被打断"，签名与公证的成本和发布流程改造是硬约束，而且签名是否能解除链路层读取限制尚未验证。— [ASSUMPTION] (confidence: low)
- 让程序进入系统路径需要"修改用户 shell 配置"或"一次管理员授权"，两者都与"零介入"的目标存在冲突。— [source: 路径与权限实测] (confidence: high)

# 缺口与待答问题

- [NEEDS CLARIFICATION: 本评估是否纳入"未签名程序读不到网关 MAC"这条限制，还是把它作为已知边界记录在案？]
- [NEEDS CLARIFICATION: 可接受的最低体验边界是什么——是否允许一次管理员授权、是否允许安装时修改 shell 配置、是否要求全程零介入？]
- [NEEDS CLARIFICATION: 可接受的成本上限是什么——是否接受每年 99 美元的签名费用，以及随之而来的发布流程改造？]
- [NEEDS CLARIFICATION: 更新通道的目标是什么——程序自行下载预编译二进制完成更新，还是只提示用户手动下载；是否要求使用者机器上不需要任何编译工具？]
- [NEEDS CLARIFICATION: 仍未验证的两项：图形界面双击首次运行的实际拦截行为（官方文档未覆盖命令行工具这一情形）；签名与公证对链路层读取限制的影响（官方文档只说明身份按签名跟踪，未涉及该信息读取）。]
- [NEEDS CLARIFICATION: 其他 macOS 命令行工具如何注册服务、如何提供命令入口，仍缺少一手来源；已授权的两份官方文档未覆盖该问题。]

# 来源

- 本地代码与文档：`auto_mount.swift`（配置解析、安装、卸载、自更新）、`.specify/memory/constitution.md`、仓库提交历史
- 本地系统事实：`/etc/paths`、`/opt/homebrew/Library/Homebrew/service.rb`、目录权限实测
- 本机对照实验：2026-10-02 的链路层信息可见性实验（系统工具/解释器可读；本机编译二进制不可读；由 launchd 直接启动的系统工具可读）与隔离标记执行实验
- 代码托管平台元数据：通过命令行工具读取的 Release 资产信息（未使用网页或直接接口）
- 官方文档（2026-10-02 经维护者授权抓取，policy: confirmed-by-user）：
  - https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy （host: developer.apple.com）
  - https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution （host: developer.apple.com）
  - https://docs.brew.sh/Formula-Cookbook （host: docs.brew.sh）
