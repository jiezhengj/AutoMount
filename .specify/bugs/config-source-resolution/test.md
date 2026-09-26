- **Slug**: config-source-resolution
- **Tested**: 2026-09-26
- **Assessment**: ./assessment.md
- **Fix**: ./fix.md
- **Result**: partial

# 结果摘要

源码编译、266 项内置自测、完整状态矩阵、CLI 帮助和打包程序架构检查均通过。评估中描述的真实 LaunchAgent/Application Support 配置恢复没有在当前用户配置上执行，因此不能宣称端到端复现已通过；没有发现本地回归失败。

# 检查记录

| 检查 | 命令 / 操作 | 结果 | 说明 |
|-------|-------------|------|------|
| 修复后复现 | 在真实 LaunchAgent 下损坏 Application Support 配置后运行 `--config` / `--install` | skipped | 评估约定本轮不触碰真实配置、服务或挂载点；由状态决策矩阵覆盖对应分支。 |
| 新增 / 更新自测 | `./auto_mount --self-test` | pass | 266 passed，0 skipped，0 failed；覆盖默认安装 26 种状态、显式来源 50 种组合、配置管理 50 种组合、初始化保留/重置 51 种组合，以及备份权限和并发快照检查。 |
| 回归检查 | `./auto_mount --self-test` | pass | 全部内置检查通过。 |
| 编译检查 | `xcrun swiftc -warnings-as-errors -O -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk -target arm64-apple-macosx27.0 auto_mount.swift -o auto_mount` | pass | 无编译错误或警告。 |
| CLI / 文档入口 | `./auto_mount --version`、`./auto_mount --help`、`AUTO_MOUNT_LANG=en ./auto_mount --help` | pass | 版本输出 `2.7.2`；中英文帮助均列出安全初始化、`--init --reset` 和配置来源选项。 |
| 二进制目标 | `file auto_mount`；`otool -l auto_mount` | pass | Mach-O arm64；最低系统版本和 SDK 均为 macOS 27.0。 |
| 补丁格式 | `git diff --check` | pass | 无空白错误。 |

# 关键输出

```text
Self-tests: 266 passed, 0 skipped, 0 failed
2.7.2
auto_mount: Mach-O 64-bit executable arm64
minos 27.0
sdk 27.0
```

# 剩余风险

- 当前结果为 partial，因为真实守护服务的配置恢复和重新加载没有端到端运行。该验证会写入 Application Support 并操作 LaunchAgent；本轮按评估约定未触碰这些用户状态。
- 局域网/Tailscale SMB 挂载不属于配置来源修复的验证范围，本轮没有执行挂载或清理。

# 建议

本地代码验收通过。若需要把结果提升为端到端 verified，应在隔离 macOS 用户/虚拟机中运行：分别构造缺失、损坏、有效但不同和未来版本的工作区与运行配置，再执行 `--init`、`--config`、`--install` 并检查备份、文件内容与 LaunchAgent 加载结果。不要用当前用户的活动配置做破坏性复现。
