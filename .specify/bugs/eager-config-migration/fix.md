- **Slug**: eager-config-migration
- **Fixed**: 2026-09-26
- **Assessment**: ./assessment.md
- **Status**: applied

# 修复概要

在平台架构检查与版本自愈之后、业务命令分发之前，引入启动阶段可见配置副本统一扫描与原地迁移机制。工作区程序独立扫描工作区配置与 Application Support 守护配置并去重，守护进程从运行目录启动时仅处理自身配置；每份配置独立原子升级并保留未知字段与自身设置，损坏、不可访问或未来版本文件保持原样且不阻塞其它配置。

# 变更文件

| 文件 | 变更 | 说明 |
|------|------|------|
| `auto_mount.swift` | 修改 | 新增 `configNeedsMigration`、`discoverVisibleConfigURLs` 与 `eagerMigrateVisibleConfigs`；在 `main` 业务分发前统一执行可见配置原地迁移；在 `runSelfTests` 中增加可见配置发现、迁移判定、多副本独立迁移、权限保护、故障容忍与幂等性全套自测。 |
| `auto_mount` | 重建 | 由当前 Swift 源码基于 macOS 27 SDK 编译的 arm64 本地程序，版本为 2.7.3。 |
| `README.zh.md` | 修改 | FAQ 中补充启动时自动扫描并分别升级所有可见配置副本（工作区与守护配置）的说明。 |
| `README.en.md` | 修改 | 同步更新英文文档中启动期可见配置自动升级的 FAQ 说明。 |
| `ARCHITECTURE.zh.md` | 修改 | 更新配置迁移章节架构说明，增加启动期可见配置扫描、运行目录隔离、独立写回与故障容忍流程图。 |
| `ARCHITECTURE.en.md` | 修改 | 同步更新英文架构文档中的配置迁移机制与流程图。 |
| `.specify/bugs/eager-config-migration/fix.md` | 新增 | 记录修复概要、变更文件、主要行为、新增自测、本地验证与后续事项。 |

# 主要行为

- 工作区启动时，统一扫描工作区配置和 Application Support 运行配置；两处路径相同时自动去重。
- 守护进程从其运行目录（Application Support）启动时，仅检查并迁移该运行目录中的配置文件，不触及任何外部工作区。
- 未安装 LaunchAgent 时，工作区配置仍会在启动阶段自动迁移；若 Application Support 存在可识别的旧配置，亦会独立迁移。
- 每份配置独立判断是否需要执行迁移，使用原有 schema 升级逻辑原子写回，保留未知字段、各自原有设置与 `0600` 文件权限，严禁跨目录相互覆盖。
- 遇到不可访问、内容损坏或未来更高版本的文件时，保持原样并记录诊断日志，不阻止其他兼容配置的正常升级。
- 重复启动时，已处于最新规范的配置保持原样，不产生冗余写盘与升级提示（完全幂等）。
- `--help`、`--version` 与 `--self-test` 保持只读/测试语义，在启动检查前直接退出，不触发任何配置写入。

# 新增或更新的自测

- `auto_mount.swift::runSelfTests` — 守护模式仅发现运行目录配置、工作区模式同时发现工作区与运行配置、重合路径去重、显式 override 优先发现。
- `auto_mount.swift::runSelfTests` — 现代配置、旧版本配置、遗留策略 ID、缺少更新信道等全分支的 `configNeedsMigration` 迁移判定覆盖。
- `auto_mount.swift::runSelfTests` — 临时沙箱多副本迁移：工作区配置升级到当前版本规范并保留未知扩展字段与 `0600` 权限，运行配置保持不变且无跨目录覆盖。
- `auto_mount.swift::runSelfTests` — 故障容忍与保护：损坏文件不被覆盖、未来版本配置不被降级、缺失文件跳过，且兼容文件仍可正常升级。
- `auto_mount.swift::runSelfTests` — 幂等性验证：二次执行返回 `.unchanged`，不产生二次写盘。

# 本地验证

- 编译检查：`xcrun swiftc -warnings-as-errors -O -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk -target arm64-apple-macosx27.0 auto_mount.swift -o auto_mount` → 编译成功，零告警。
- 自动化自测：`./auto_mount --self-test` → 290 项全部通过（新增 24 项），0 项跳过，0 项失败。
- 只读命令语义验证：
  - `./auto_mount --version` → 输出 `2.7.3`，未触发配置扫描与文件写盘。
  - `./auto_mount --help` → 正常展示中英文帮助信息，未触发配置扫描与文件写盘。
- 复现场景验证：
  - 启动前：工作区配置为 `2.7.1`，守护运行配置为 `2.7.2`。
  - 执行 `./auto_mount --status`：控制台提示工作区配置已保存并平滑升级至 `v2.7.2` 格式规范。
  - 检查文件：工作区配置已变为 `2.7.2`，未知字段和原有目标保持完整；运行配置保持原样。
  - 再次执行 `./auto_mount --status`：直接展示状态，无配置保存与升级提示，验证幂等。

# 与评估方案的差异

无差异。所有变更严格遵循 `assessment.md` 中提出的 Preferred 修复方案与范围。

# 后续事项

- 运行 `$speckit-bug-test slug=eager-config-migration` 生成独立的缺陷验证报告。
