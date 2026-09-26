- **Slug**：netfs-mount-at-mount-dir
- **创建日期**：2026-09-26
- **来源**：用户描述及 SMB 验收时观察到的现象
- **结论**：valid
- **严重程度**：medium

# 现象报告

此前远程 SMB 检查确认 NAS 的 Tailscale 节点可达，但 NetFS 没有把共享挂载到验收程序指定的临时路径。

# 症状

NetFS 收到已存在的挂载目录、但未收到 kNetFSMountAtMountDirKey 选项时，可能把共享挂在该目录下的子目录。AutoMount 检查到实际路径与配置不一致后，会卸载该挂载并报告失败。

# 复现步骤

1. 使用已配置的远程策略和在线的 Tailscale NAS 节点。
2. 将配置中的 SMB 共享挂载到一个已存在的临时目录。
3. NetFS 返回成功，但把共享挂在指定目录的子目录；AutoMount 随后清理并报告失败。

macOS 27 SDK 头文件说明，设置 kNetFSMountAtMountDirKey = true 后会挂载到指定路径本身。此前真实测试通过 Tailscale 连到 SMB，观察到了子目录挂载，并确认清理成功。

# 可疑代码路径

- auto_mount.swift:1152 的 silentMount：传给 NetFS 的 mount_options 为 nil，但调用方要求使用指定路径。
- auto_mount.swift:1224 的 runRemoteSMBAcceptanceChecks：在已有临时目录中挂载远程目标，并检查实际路径。

# 根因假设

NetFSMountURLSync 的挂载选项参数为 nil，因此 NetFS 对已存在的挂载目录采用默认行为，可能创建共享名子目录。AutoMount 的精确路径检查正确；调用方缺少满足该路径约束的系统选项。置信度：高。

# 建议修复

**首选方案**：显式挂载目录存在时，为 NetFSMountURLSync 传入 kNetFSMountAtMountDirKey = true；保留精确路径检查和失败清理。使用配置的远程 SMB 共享执行 Tailscale 实挂验收，并添加回归检查。

将补丁版本提升至 2.7.1，并同步更新用户文档中的版本示例和技术说明。

# 可能涉及的文件

- auto_mount.swift
- auto_mount
- README.zh.md
- README.en.md
- ARCHITECTURE.zh.md
- ARCHITECTURE.en.md
- .specify/bugs/netfs-mount-at-mount-dir/fix.md
- .specify/bugs/netfs-mount-at-mount-dir/test.md

# 应新增或更新的测试

- 验证显式挂载目录会启用 NetFS 精确挂载选项。
- 执行自测和真实远程 SMB 验收，确认两个共享都挂到准确路径并在结束后卸载。
- 使用 macOS 27 SDK 编译 arm64 程序并检查自测结果。

# 风险与注意事项

- 集成验收使用现有 SMB 配置和 Tailscale 会话；结束时必须清理临时挂载。
- NetFS 仍可能因服务器、凭据或网络等原因拒绝挂载；应与挂载路径问题区分。

# 未决问题

- 无阻塞问题。SDK 契约和实际观察足以确定所需选项。
