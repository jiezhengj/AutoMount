- **Slug**: workspace-install-compile-fallback
- **创建日期**: 2026-09-27
- **来源**: 用户反馈在 macOS 27 正式版工作区安装守护进程报 Swift 编译失败
- **结论**: valid
- **严重程度**: high

# 现象报告

在用户电脑（macOS 27 正式版）的工作区目录下运行程序并选择安装守护进程时（通过日常菜单、`--init` 向导或 `--install`），程序输出 Swift 编译失败错误并强行中断安装。在开发者电脑（macOS 27.2 beta，已安装 Xcode 开发工具链）上执行相同操作则不会报错。

# 症状

当工作区同时存在源码文件 [auto_mount.swift](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount.swift) 和可执行文件 [auto_mount](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount) 时，安装逻辑由于检测到源码文件存在，无条件调用 `compileOptimizedSwiftSource` 尝试通过 `swiftc` 重新编译出临时二进制文件。

如果运行环境缺少 Xcode 或 Command Line Tools，或者系统升级到 macOS 27 后开发者工具 SDK 仍停留在旧版本（如 macOS 26 SDK），`currentMacOSSDKPath()` 探测 macOS 27 SDK 失败并返回 `nil`，导致安装流程直接打印“当前 Swift 源码编译失败，旧运行程序未覆盖”，并附带“AutoMount requires the macOS 27 SDK or later from Xcode or Command Line Tools.”错误后以退出码 1 中止。程序没有直接使用工作区中原本已存在且完全可用的发布可执行二进制来完成守护进程安装。

# 复现

1. 在未安装 Xcode / Command Line Tools 或仅安装旧版 SDK 的 macOS 27 设备上准备工作区目录，包含当前可执行程序 `auto_mount` 与源码 `auto_mount.swift`。
2. 运行 `./auto_mount --install`。
3. 程序检测到 `auto_mount.swift` 存在，调用 `compileOptimizedSwiftSource`；SDK 检查未通过，编译退出码非 0。
4. 安装流程直接中止退出，未直接使用现成的 `auto_mount` 二进制。

## 涉及代码

- [auto_mount.swift:222-231](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount.swift#L222-L231) — `currentMacOSSDKPath()` 依赖 `/usr/bin/xcrun` 探测 SDK 路径与版本，缺少 macOS 27 SDK 时返回 `nil`。
- [auto_mount.swift:233-246](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount.swift#L233-L246) — `compileOptimizedSwiftSource()` 直接依赖 `currentMacOSSDKPath()`，探测失败时返回错误。
- [auto_mount.swift:3161-3166](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount.swift#L3161-L3166) — `launchAgentProgramArguments()` 错误地偏好使用 `/usr/bin/swift` 执行源码而非二进制。
- [auto_mount.swift:3491-3506](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount.swift#L3491-L3506) — `installLaunchAgent()` 只要源码存在即强制编译，编译失败直接以退出码 1 退出，而非直接部署现成二进制。
- [auto_mount.swift:5103-5118](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount.swift#L5103-L5118) — `syncCurrentToInstalledDaemon()` 在源码存在时强制现场编译，而非直接使用工作区已有二进制进行原子同步。
- [auto_mount.swift:5218-5228](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount.swift#L5218-L5228) — `checkAndSyncWorkspaceFromInstalledDaemonIfNeeded()` 从守护目录反哺工作区时强制重新编译，而非直接拷贝守护目录既有二进制。

# 根因判断

根本原因包含两层：

1. **运行期假设错误与职责越界**：代码错误地将“源码重新编译”的职责放在了终端用户的运行期。用户拿到程序时，运行目录中已具备经过发布验证的预编译二进制 `auto_mount`。普通终端用户的生产环境不具备也不应当被要求具备完整的 Xcode / macOS 27 SDK 编译环境。
2. **发布流程约束曾未文档化强制**：此前为了防止“修改源码后遗忘重新构建”，错误地在运行时引入现场编译作为防护；正确的工程方案应由交付规范（[AGENTS.md](file:///Users/jiezhengj/Documents/Project/AutoMount/AGENTS.md)）硬性约束在发布 GitHub Release 前必须在本地构建好最新二进制并通过自测。

判断置信度：高。用户明确指示：发布通过 Release 保证二进制与源码同步；用户端彻底移除动态编译，完全基于预编译二进制完成安装与同步。

# 修复方案

**首选方案**：

1. **工程纪律约束（发布前强制构建）**：在 [AGENTS.md](file:///Users/jiezhengj/Documents/Project/AutoMount/AGENTS.md) 中增加铁律，明确在执行提交、推送与创建 GitHub Release 之前，必须在本地使用最新源码重新编译生成 `auto_mount` 可执行二进制并通过全部自测，确保 Release 中始终附带同步的预编译二进制，杜绝遗漏构建。
2. **守护服务安装彻底解耦源码编译**：在 `installLaunchAgent` 中彻底移除调用 `compileOptimizedSwiftSource` 的逻辑。安装流程严格校验工作区 `auto_mount` 二进制是否有效（存在且具执行权限），直接将其原子部署到系统守护目录（`~/Library/Application Support/AutoMount/auto_mount`）；若工作区存在 `auto_mount.swift`，仅作为辅助源码文件同步拷贝（权限 0644），绝不触发现场编译。
3. **LaunchAgent 描述文件始终使用二进制**：调整 `launchAgentProgramArguments`，移除对 `/usr/bin/swift` 的偏好，始终固定以 `installedBinaryURL.path`（原生二进制路径）作为守护进程启动命令。
4. **双向同步逻辑彻底解耦源码编译**：在 `syncCurrentToInstalledDaemon` 与 `checkAndSyncWorkspaceFromInstalledDaemonIfNeeded` 中彻底移除编译调用，统一使用已存在的 `auto_mount` 二进制完成原子同步与替换。
5. **版本晋级与自测更新**：版本号遵循 SemVer 晋级至 `2.7.4`。更新 `--self-test` 中涉及启动参数的用例，确保全部 290+ 项自测通过。
6. **文档同步更新**：同步更新 `README.zh.md`、`README.en.md`、`ARCHITECTURE.zh.md`、`ARCHITECTURE.en.md` 中关于守护服务部署和反向自愈的技术机制描述，移除现场动态编译表述，明确二进制分发与部署机制。

**可能涉及文件**:

- [AGENTS.md](file:///Users/jiezhengj/Documents/Project/AutoMount/AGENTS.md)
- [auto_mount.swift](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount.swift)
- [auto_mount](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount)
- [README.zh.md](file:///Users/jiezhengj/Documents/Project/AutoMount/README.zh.md)
- [README.en.md](file:///Users/jiezhengj/Documents/Project/AutoMount/README.en.md)
- [ARCHITECTURE.zh.md](file:///Users/jiezhengj/Documents/Project/AutoMount/ARCHITECTURE.zh.md)
- [ARCHITECTURE.en.md](file:///Users/jiezhengj/Documents/Project/AutoMount/ARCHITECTURE.en.md)
- `.specify/bugs/workspace-install-compile-fallback/fix.md`
- `.specify/bugs/workspace-install-compile-fallback/test.md`

**验证**:

- 运行内置自测 `./auto_mount --self-test`，确保所有用例全部 PASS。
- 验证 `--install` 流程直接使用现有二进制完成部署，在无编译工具或模拟缺失 SDK 的环境下均可正常安装。
- 验证 LaunchAgent 生成的 plist 中的 ProgramArguments 直接指向 `auto_mount` 二进制。

# 风险与限制

- 必须在部署前严格校验当前目录 `auto_mount` 具备可执行权限（`FileManager.isExecutableFile`），若文件缺失或不可执行则明确拦截并报错。
