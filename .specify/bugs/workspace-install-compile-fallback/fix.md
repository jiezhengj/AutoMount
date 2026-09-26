- **Slug**: workspace-install-compile-fallback
- **修复日期**: 2026-09-27
- **评估文档**: ./assessment.md
- **状态**: applied

# 修复摘要

彻底移除守护服务安装（`--install`）与双向同步流程中的现场动态编译逻辑，改为始终直接校验并部署工作区现有的原生预编译可执行二进制 [auto_mount](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount)。同时在 [AGENTS.md](file:///Users/jiezhengj/Documents/Project/AutoMount/AGENTS.md) 中增加铁律，要求在发布 GitHub Release 之前必须在本地构建出最新二进制并通过自测，确保终端用户环境零依赖、开箱即用。

# 变更清单

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| [AGENTS.md](file:///Users/jiezhengj/Documents/Project/AutoMount/AGENTS.md) | 修改 | 增加发布前强制在本地使用最新源码编译构建优化二进制并通过自测的交付准则 |
| [auto_mount.swift](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount.swift) | 修改 | 版本晋级至 2.7.4；移除 install/sync 中的编译调用；LaunchAgent 始终使用二进制；更新自测用例 |
| [auto_mount](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount) | 重新构建 | 使用 macOS 27 SDK 对最新源码执行 `-O` 优化重新编译生成 arm64 原生可执行文件 |
| [README.zh.md](file:///Users/jiezhengj/Documents/Project/AutoMount/README.zh.md) | 修改 | 调整运行与安装说明，明确直接部署预编译二进制而无需 Xcode/CLT |
| [README.en.md](file:///Users/jiezhengj/Documents/Project/AutoMount/README.en.md) | 修改 | 英文文档同步调整为直接部署二进制描述 |
| [ARCHITECTURE.zh.md](file:///Users/jiezhengj/Documents/Project/AutoMount/ARCHITECTURE.zh.md) | 修改 | 架构文档中移除运行时动态编译和 `/usr/bin/swift` 解释执行描述，明确二进制部署架构 |
| [ARCHITECTURE.en.md](file:///Users/jiezhengj/Documents/Project/AutoMount/ARCHITECTURE.en.md) | 修改 | 英文架构文档同步对齐 |

# 代码变更要点

## 1. 交付准则强制本地构建 (AGENTS.md)

明确在执行代码提交、推送与创建 GitHub Release 之前，必须在 macOS 27 环境下使用当前最新源码通过最高优化参数重新编译生成 `auto_mount` 可执行二进制（`/usr/bin/swiftc -O -sdk ...`），并通过全部内置自测。Release 资源中必须包含与源码版本严格一致的预编译二进制。用户环境默认且只能基于预编译二进制运行、部署守护进程与同步，严禁在用户机器上现场动态编译源码。

## 2. 守护进程安装解耦源码编译 (auto_mount.swift)

在 `installLaunchAgent` 中校验 `currentBinaryURL`（`auto_mount`）具备可执行权限后，直接将其原子部署至 `installedBinaryURL`（`~/Library/Application Support/AutoMount/auto_mount`）。LaunchAgent 启动参数 `launchAgentProgramArguments` 始终固定为 `[installedBinaryURL.path]`。源码文件仅作为辅助参考拷贝，不再调用 `compileOptimizedSwiftSource`。

## 3. 双向同步解耦源码编译 (auto_mount.swift)

`syncCurrentToInstalledDaemon` 与 `checkAndSyncWorkspaceFromInstalledDaemonIfNeeded` 移除编译调用，统一使用已存在的 `auto_mount` 可执行二进制进行文件原子同步与配置迁移。

# 测试更新与验证

## 1. 测试用例调整

- 更新 `launchAgentProgramArguments` 相关测试用例，断言生成的启动参数始终直接指向已编译的原生二进制路径。
- 同步将未来版本保护矩阵中的虚拟高版本由 `2.7.4` 升级为 `2.7.5`，使测试用例与当前 `2.7.4` 版本语义严格对齐。

## 2. 本地执行验证

- 编译命令：`/usr/bin/swiftc -O -sdk $(xcrun --sdk macosx --show-sdk-path) -target arm64-apple-macosx27.0 auto_mount.swift -o auto_mount` → 成功退出（状态码 0）。
- 自测命令：`./auto_mount --self-test` → `Self-tests: 290 passed, 0 skipped, 0 failed`，全部通过。
- 版本核验：`./auto_mount --version` → 输出版本 `2.7.4`。

# 偏离说明 (Deviations from Assessment)

在最初的评估报告草案中，曾考虑在保留动态编译的同时增加“编译失败后降级回退至现有二进制”的策略。经用户明确裁定并批准，用户端本就持有随 Release 发布的预编译二进制，现场动态编译不仅属于多余设计，更是导致终端用户环境报错的根源。因此本次实际修复彻底剔除了安装与同步中的现场编译逻辑，改由交付准则强制发布前构建，完全基于二进制进行分发与部署。评估报告已同步修订。

# 后续工作

按 Bug 治理流程执行 `$speckit-bug-test slug=workspace-install-compile-fallback` 完成最终验证报告归档。
