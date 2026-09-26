- **Slug**：netfs-mount-at-mount-dir
- **测试日期**：2026-09-26
- **评估记录**：./assessment.md
- **修复记录**：./fix.md
- **结果**：verified

# 总结

修复后没有再出现 NetFS 将共享挂在指定目录子目录中的现象。部署源码通过 Tailscale 将两个 SMB 共享挂在准确的临时目录，核对来源后成功卸载。launchd 运行 2.7.1 后也挂载了两个局域网目标。

# 执行的检查

| 检查 | 命令或动作 | 结果 | 说明 |
|-------|----------|------|------|
| 严格原生编译 | xcrun swiftc -warnings-as-errors -O -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk -target arm64-apple-macosx27.0 auto_mount.swift -o auto_mount | pass | macOS 27 SDK 编译 arm64，无警告。 |
| 编译程序自测 | ./auto_mount --self-test | pass | 69 项通过，0 项跳过，0 项失败。 |
| 编译候选程序网络及 SMB 验收 | ./auto_mount.acceptance --self-test --network --remote-smb | pass | 70 项通过，4 项环境相关 ARP 检查跳过，0 项失败；远程 SMB 2/2 通过。 |
| 已部署源码网络及 SMB 验收 | /usr/bin/swift "/Users/jiezhengj/Library/Application Support/AutoMount/auto_mount.swift" --self-test --network --remote-smb | pass | 74 项通过，0 项跳过，0 项失败；远程 SMB 2/2 通过。 |
| 精确路径复现 | 通过 Tailscale 执行远程 SMB 验收 | pass | 两个共享挂在请求的缓存目录本身，随后均成功卸载。 |
| LaunchAgent 部署 | ./auto_mount.acceptance --install --config-source runtime | pass | 保留运行配置；守护程序和配置均为 2.7.1。 |
| LaunchAgent 运行 | launchctl kickstart -k gui/501/com.user.auto-mount | pass | 服务已加载，最近退出码为 0；日志记录局域网策略 2/2 个目标已挂载。 |
| 工作区配置迁移 | ./auto_mount --migrate-only | pass | 工作区配置成功迁移；工作区和守护配置版本均为 2.7.1。 |
| 临时资源清理 | 检查挂载表和缓存目录 | pass | 没有验收挂载或缓存目录残留。 |

# 结果摘录

    Self-tests: 74 passed, 0 skipped, 0 failed
    Remote SMB acceptance: 2 passed, 0 failed
    last exit code = 0
    Finished execution of 'local_lan': 2/2 mounted.

# 剩余限制

- 当前 Codex 命令执行环境中的编译版可选 --self-test --network 没有从 arp 子进程取得表格输出，该次运行的 4 项环境相关检查因此跳过。实际安装的 LaunchAgent 通过 /usr/bin/swift 启动同一份源码；该路径读到了网关 MAC，所有网络检查通过并挂载了两个局域网共享。未在交互式 Terminal 中单独测试编译版。
- 没有重启整台电脑。安装时重新加载 LaunchAgent，RunAtLoad 执行成功；随后通过 kickstart 触发并确认退出码为 0。

# 建议

此 Bug 可按已验证关闭。修复前能复现挂载路径错误；修复后，编译版验收候选程序和已部署的 LaunchAgent 源码均通过精确挂载验证。守护服务和配置已部署为 2.7.1。
