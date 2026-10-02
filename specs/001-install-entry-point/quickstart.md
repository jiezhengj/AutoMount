本文档提供 Feature `001-install-entry-point` 的端到端可执行验证场景，用于在功能交付后独立证明各项需求达成。

# 准备工作与环境前置

- **操作系统**：macOS 27.0 或更高版本（Apple silicon arm64）；
- **环境要求**：机器无需安装 Xcode 或命令行开发者工具（Command Line Tools），完全基于预编译可执行文件运行；
- **测试产物准备**：获取预编译的二进制文件 `automnt`，放置于临时测试目录（例如 `~/Downloads/automnt`）。

# 场景一：首次搬迁安装与下载副本自清理验证 (US1, FR-001, FR-002)

### 执行步骤

1. 打开终端，进入放置下载副本的目录并直接运行程序：
```bash
chmod +x ~/Downloads/automnt
~/Downloads/automnt --install
```
2. 观察控制台输出，确认安装成功回显。

### 预期结果与判定标准

- 检查规范安装位置：`ls -la "$HOME/Library/Application Support/automnt/bin/automnt"` 确认文件存在且权限为 `0755`；
- 检查原下载副本：`test ! -e ~/Downloads/automnt` 返回真（下载目录中的可执行文件已被自动清理，无需手动删除）；
- 检查进程状态：`pgrep automnt` 应为空（未留下常驻进程）。

# 场景二：新终端窗口短命令入口验证 (US1, FR-003, FR-004)

### 执行步骤

1. 打开一个全新的终端窗口（或执行 `source ~/.zshrc`）；
2. 不带任何路径前缀，直接输入命令并查询状态：
```bash
automnt --status
```

### 预期结果与判定标准

- 命令正常执行并回显当前 automnt 状态，无 `command not found` 错误；
- 查看用户 shell 配置文件（如 `~/.zshrc`），末尾应包含完整定界代码段：
```sh
# >>> automnt CLI begin >>>
export PATH="$HOME/Library/Application Support/automnt/bin:$PATH"
# <<< automnt CLI end <<<
```

# 场景三：主机可达性探测与挂载策略匹配验证 (US5, FR-007, FR-017)

### 执行步骤

1. 打开配置向导：`automnt --config`；
2. 配置一条指向当前局域网可用 NAS 或测试机的主机策略（设置目标主机 `host` 为可达机器，端口 `445`）；
3. 保存后执行一次手动评估：
```bash
automnt
```

### 预期结果与判定标准

- 控制台或日志输出确认通过 TCP 445 端口直连探测判定目标主机可达；
- 配置生成的 `~/Library/Application Support/automnt/automnt.plist` 中，不包含任何 `gateway_mac` 或链路层字段；
- 对应的挂载点成功挂载至系统。

# 场景四：网络配置变动触发与有限重试验证 (US7, FR-020, FR-021)

### 执行步骤

1. 确认 LaunchAgent 描述文件中不存在 `StartInterval` 键：
```bash
/usr/libexec/PlistBuddy -c "Print :StartInterval" ~/Library/LaunchAgents/com.user.automnt.plist 2>&1 | grep "Does Not Exist"
```
2. 模拟高顺位主机延迟就绪（或在 Tailscale 握手期间切换网络）；
3. 检查系统日志或查看输出：
```bash
cat ~/Library/Logs/automnt/stdout.log
```

### 预期结果与判定标准

- 守护进程在网络接口变动时被 launchd 单次唤醒；
- 日志中体现最多 3 次有限重试（间隔 1 秒），在窗口期内主机变为可达后顺利命中；
- 评估完成后进程正常退出，未留下常驻等待进程；
- 使用者主动卸载共享后，在没有新网络变动前，共享不会被异常重新挂载。

# 场景五：安装状态损坏与自愈验证 (US8, FR-027)

### 执行步骤

1. 手动破坏 Shell 配置文件中的命令入口（删除注入代码段）：
```bash
sed -i '' '/automnt CLI/d' ~/.zshrc
```
2. 使用完整路径运行一次程序：
```bash
"$HOME/Library/Application Support/automnt/bin/automnt" --status
```

### 预期结果与判定标准

- 程序在运行初期自动检测到 Shell CLI 入口缺失，并在控制台提示修复成功；
- 再次检查 `~/.zshrc`，注入代码段已自动恢复（幂等恢复）。

# 场景六：干净卸载与数据保护验证 (US4, FR-009)

### 执行步骤

1. 运行常规卸载命令：
```bash
automnt --uninstall
```
2. 检查系统状态：
```bash
launchctl list | grep com.user.automnt || true
test ! -e "$HOME/Library/Application Support/automnt/bin/automnt"
test -f "$HOME/Library/Application Support/automnt/automnt.plist"
```
3. 测试连同配置彻底删除：
```bash
"$HOME/Library/Application Support/automnt/bin/automnt" --uninstall --purge 2>/dev/null || rm -rf "$HOME/Library/Application Support/automnt"
```

### 预期结果与判定标准

- 常规卸载后：后台服务被注销、Shell 入口被剥离、二进制被删除，但配置文件被安全保留，并给出彻底清理的指引；
- 彻底卸载后：`~/Library/Application Support/automnt` 目录完全移除，系统恢复干净状态。

# 场景七：从 2.7.4 旧形态切换验证 (US6, FR-012)

### 执行步骤

1. 在旧环境中使用历史版本命令执行完整卸载：
```bash
./<legacy-binary> --uninstall
```
2. 确认旧守护服务已注销且旧命令入口已清理：
```bash
launchctl list | grep com.user.automount || true
which <legacy-binary> || true
```
3. 下载 3.0.0 新版预编译二进制 `automnt` 并运行安装：
```bash
chmod +x ~/Downloads/automnt
~/Downloads/automnt
```
4. 运行初始化向导生成新形态单一配置：
```bash
automnt --init
```

### 预期结果与判定标准

- 旧形态服务（`com.user.automount`）注销，旧命令无法再调用；
- 3.0.0 规范安装成功，位于 `~/Library/Application Support/automnt/bin/automnt`；
- 旧配置不会被静默读取或迁移（新程序不维护对 2.7.4 双配置的特例迁移分支）；
- 使用者在新向导中完成目标配置后，系统稳定运行于新架构下。
