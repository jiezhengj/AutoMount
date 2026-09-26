- **Slug**: config-source-resolution
- **Fixed**: 2026-09-26
- **Assessment**: ./assessment.md
- **Status**: applied

# 修复概要

三个配置入口现在使用同一套配置状态判断，区分缺失、可用、损坏、未来版本和不可访问。安装和配置管理会在恢复前备份目标配置、验证写入结果，并在文件快照变化时停止；`--init` 默认保留已有可用配置，明确的 `--init --reset` 才会重建工作区配置。

# 变更文件

| 文件 | 变更 | 说明 |
|------|------|------|
| `auto_mount.swift` | 修改 | 统一状态解析、安装来源决策、配置备份与恢复、初始化保护；增加默认安装、显式来源、管理服务和初始化重置的全状态矩阵自测，并检查并发快照。 |
| `auto_mount` | 重建 | 由当前 Swift 源码编译的 arm64 macOS 27 程序，版本为 2.7.2。 |
| `README.zh.md` | 修改 | 说明初始化保护、配置来源选择、恢复和备份行为。 |
| `README.en.md` | 修改 | 同步英文使用说明。 |
| `ARCHITECTURE.zh.md` | 修改 | 记录初始化和运行配置恢复规则。 |
| `ARCHITECTURE.en.md` | 修改 | 同步英文架构说明。 |

# 主要行为

- 首次安装从有效工作区配置初始化运行配置；重装时两份配置有效且相同则保留运行配置。
- 两份配置有效但不同：交互安装让用户选择，默认保留运行配置；非交互安装保留运行配置。显式选择工作区配置时先备份运行配置。
- 运行配置损坏而工作区配置有效时，先备份损坏文件，再恢复并继续安装。
- 两边都没有可用配置时，交互安装运行初始化向导并继续；非交互安装在注册服务前失败。
- 未来版本配置不会被隐式降级；无法读取、备份或确认文件状态时停止写入。
- LaunchAgent 已安装时，`--config` 选择其实际运行配置；缺失或损坏时从另一份有效配置备份恢复。没有 LaunchAgent 时管理工作区配置。
- `--init` 发现已有可用配置时保留现状；`--init --reset` 才会在备份后重建工作区配置。
- 配置恢复写入前重新检查来源和目标快照，防止覆盖检查期间出现的并发更改。

# 新增或更新的自测

- `auto_mount.swift::runSelfTests` — 覆盖默认安装 26 种状态组合、显式来源 50 种组合、带/不带 LaunchAgent 的配置管理 50 种组合，以及 `--init` 保留和重置 51 种组合。
- `auto_mount.swift::runSelfTests` — 覆盖缺失/损坏文件识别、并发快照变化检测、备份权限 `0600` 和过期来源拒绝。

# 本地验证

- 命令：`xcrun swiftc -warnings-as-errors -O -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk -target arm64-apple-macosx27.0 auto_mount.swift -o auto_mount` → 通过。
- 命令：`./auto_mount --self-test` → 266 项通过，0 项跳过，0 项失败。
- 命令：`./auto_mount --version` → 输出 `2.7.2`。
- 命令：`./auto_mount --help` → 展示 `--init --reset` 和配置来源参数。
- 未运行实际 LaunchAgent 重部署或真实 SMB 挂载；本地检查没有修改 Application Support 配置、LaunchAgent 或挂载点。

# 与评估方案的差异

实施中额外加入恢复前来源与目标快照复核。该检查防止安装或配置管理检查完文件后、备份和写入前发生的并发修改被静默覆盖，属于同一配置恢复范围。

# 后续事项

- 真实 LaunchAgent 重部署和 SMB 挂载验收仍需在不替换现有运行配置的隔离环境中进行；本地验证已记录于 `./test.md`。
