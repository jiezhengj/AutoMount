- **Slug**：netfs-mount-at-mount-dir
- **修复日期**：2026-09-26
- **评估记录**：./assessment.md
- **状态**：applied

# 修复摘要

AutoMount 现在在传入显式且已存在的挂载目录时设置 kNetFSMountAtMountDirKey，使 SMB 共享挂在配置路径本身。软件及文档版本已提升至 2.7.1。

# 修改内容

| 文件 | 修改 | 说明 |
|------|------|------|
| auto_mount.swift | 修改 | 增加精确挂载选项、回归检查，并将补丁版本提升至 2.7.1。 |
| auto_mount | 重建 | 使用 macOS 27 SDK 编译为 arm64 程序。 |
| README.zh.md | 修改 | 更新 NetFS 示例和版本信息。 |
| README.en.md | 修改 | 更新 NetFS 示例和版本信息。 |
| ARCHITECTURE.zh.md | 修改 | 说明精确挂载路径行为。 |
| ARCHITECTURE.en.md | 修改 | 说明精确挂载路径行为。 |

# 新增或更新的测试

- runSelfTests 验证显式挂载目录设置 kNetFSMountAtMountDirKey，系统创建的 /Volumes 挂载点保留默认行为。
- runSelfTests 更新 2.7.1 版本下的高版本配置保护断言。

# 本地验证

- xcrun swiftc -warnings-as-errors -O -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk -target arm64-apple-macosx27.0 auto_mount.swift -o auto_mount：通过。
- ./auto_mount --version：输出 2.7.1。
- ./auto_mount --self-test：69 项通过，0 项跳过，0 项失败。
- /usr/bin/swift "/Users/jiezhengj/Library/Application Support/AutoMount/auto_mount.swift" --self-test --network --remote-smb：74 项通过，0 项跳过，0 项失败；2 个远程 SMB 目标均挂在准确的临时路径并成功卸载。
- ./auto_mount.acceptance --self-test --network --remote-smb：70 项通过，4 项因 Codex 执行环境的 ARP 子进程无输出而跳过，0 项失败；远程 SMB 目标 2/2 挂载并卸载成功。
- launchctl kickstart -k gui/501/com.user.auto-mount：成功；最近退出码为 0，日志记录局域网策略的 2/2 个目标已挂载。
- ./auto_mount.acceptance --install --config-source runtime：保留现有守护配置并部署 2.7.1。
- ./auto_mount --migrate-only：将工作区配置平滑迁移至 2.7.1；随后核实工作区和守护配置版本均为 2.7.1。
- 挂载表和缓存目录检查：没有遗留验收挂载或 AutoMountRemoteAcceptance-* 目录。

# 与评估的差异

- 无。修复覆盖了精确路径选项、回归检查、文档、补丁版本升级和真实远程 SMB 验收。

# 后续

- Bug Test 验证报告已写入 ./test.md。
