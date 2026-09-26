- **Slug**: eager-config-migration
- **Created**: 2026-09-26
- **Source**: 用户明确要求程序启动时自动升级可见配置文件
- **Verdict**: valid
- **Severity**: medium

# Report

用户要求工作区程序启动时，如果能找到守护程序和守护配置，就分别升级工作区与守护配置；即使没有守护程序，程序启动时也要自动升级工作区配置。用户希望配置副本都能跟上当前程序版本，同时保留每份配置原有设置。

# Symptom

配置迁移目前按命令稍后选择的单个配置文件触发，启动时没有扫描并迁移所有已知配置副本。用户从工作区运行 `--config` 后，运行配置迁移到 v2.7.2，但工作区配置仍为 v2.7.1。

# Reproduction

1. 让工作区程序和已安装守护程序均为 v2.7.2，工作区配置为 v2.7.1，运行配置为 v2.7.2。
2. 从工作区启动 `./auto_mount --config`。
3. 守护运行配置被加载或迁移；工作区配置没有在同一次启动中迁移。

当前本机只读核对结果：已安装源码和二进制均为 v2.7.2，运行配置为 v2.7.2，工作区配置为 v2.7.1；两份配置除版本和更新状态元数据外设置一致。LaunchAgent 已加载，最近退出码为 0。

# Suspected Code Paths

- `auto_mount.swift:449` — `migrateConfigIfNeeded` 仅在某一配置被 `loadConfig` 读取时迁移该文件，并以 `syncInstalled: false` 保存。
- `auto_mount.swift:500` — `loadConfig` 只迁移调用方传入的单个 URL。
- `auto_mount.swift:2077` — `prepareManagementConfigURL` 根据 LaunchAgent 状态选择一个活动配置，因此 `--config` 不会自动迁移工作区副本。
- `auto_mount.swift:5117` — `main` 先处理命令分支，普通执行路径只加载当前工作区配置；启动阶段没有统一的多文件迁移步骤。
- `auto_mount.swift:4890` — 守护版本领先时已有工作区自愈同步，但守护和工作区程序版本相同的场景不会触发这条路径。

# Root Cause Hypothesis

配置迁移由按需读取触发，而不是由程序启动阶段统一发现和处理。`--config` 刻意选用守护运行配置；普通挂载执行则读取工作区配置，因此两条路径分别升级一份配置，却不会在同一工作区程序启动时升级另一份。判断置信度：高，代码路径和用户的实际版本核对结果一致。

# Proposed Remediation

**Preferred**：在平台检查和已有版本自愈之后、业务命令分发之前，加入幂等的可见配置迁移阶段。工作区程序独立检查工作区配置和 Application Support 配置；路径相同时去重。守护进程从其运行目录启动时只处理该运行目录配置。没有 LaunchAgent 时，工作区配置仍会在启动阶段自动迁移；若 Application Support 中还有可识别的旧配置，也可独立迁移。

每份可迁移配置都使用当前程序已有的 schema 迁移逻辑，分别原子写回并保留未知字段及自身设置，不将工作区内容覆盖到守护目录或反向覆盖。当前版本已无法读取的未来版本、损坏文件和访问失败的文件保持不变并记录清楚诊断；其它可迁移副本不因此被跳过。`--help`、`--version` 和 `--self-test` 保持只读/测试语义，不触发配置写入。

**Files likely to change**:

- `auto_mount.swift`
- `auto_mount`
- `README.zh.md`
- `README.en.md`
- `ARCHITECTURE.zh.md`
- `ARCHITECTURE.en.md`
- `.specify/bugs/eager-config-migration/fix.md`
- `.specify/bugs/eager-config-migration/test.md`

**Tests to add or update**:

- 覆盖有无 LaunchAgent、当前程序与守护程序版本相同/不同、两条路径重复和配置缺失/损坏/未来版本时的启动迁移目标选择。
- 验证每份配置独立迁移、重复启动不重复写入，且一份不可迁移配置不阻止其它兼容配置升级。
- 保留现有未知字段、原子保存、未来版本保护和中英文帮助行为。
- 继续使用 macOS 27 SDK 编译 arm64 程序并运行完整自测；不触碰真实 SMB 挂载。

# Risks & Considerations

- 启动阶段会写入当前运行上下文可以识别的多个配置文件；每份文件必须独立迁移、保留权限 `0600` 和未知字段，不可复制另一份配置覆盖它。
- 配置可能包含 SMB 凭据；诊断、测试输出和修复记录不能打印配置内容。
- 未来版本配置不能由旧程序降级；不可访问或损坏的副本不能被空配置覆盖。
- `--help`、`--version` 与 `--self-test` 保持无副作用，避免信息查询或测试命令暗中改写用户配置。

# Open Questions

- 无阻塞问题。迁移范围是启动程序能识别的配置文件副本；只读信息命令和自测不执行迁移。
