本文档规范 `automnt` 命令入口的参数格式、交互向导行为、子命令及返回值规范。

# 核心命令调用接口

### 语法

```text
automnt [选项]
```

### 命令选项列表

| 选项参数 | 说明 | 适用场景 |
| :--- | :--- | :--- |
| *(无参数)* | 执行常规挂载评估流水线（单次事件驱动）。 | 登录唤醒、网络变化触发或用户手动触发评估。 |
| `--config` | 打开日常全交互配置向导（管理挂载目标、网络策略、更新信道）。 | 终端日常配置管理。 |
| `--install` | 显式执行搬迁安装与服务注册（若未安装则自动执行）。 | 首次部署或修复安装状态。 |
| `--uninstall` | 卸载程序：注销守护服务、移除 Shell 入口并清理安装目录；默认保留配置文件。 | 用户主动卸载程序。 |
| `--uninstall --purge` | 彻底卸载程序：除常规卸载外，连同配置文件一同清理。 | 彻底清除所有痕迹。 |
| `--status` | 查询当前安装状态、守护服务注册状态及已配置策略概况。 | 状态巡检与诊断。 |
| `--self-test` | 执行全部内置自动化测试用例。 | 开发者构建验证与发布前测试。 |
| `-v`, `--version` | 打印当前可执行文件的 SemVer 规范版本号。 | 版本查询。 |
| `-h`, `--help` | 打印命令行使用说明帮助文档。 | 帮助查询。 |

# 首次运行搬迁交互契约

当使用者直接执行从 Release 下载的程序（例如 `./automnt` 或双击）时：

1. **环境检测**：程序探测当前可执行文件不在 `~/Library/Application Support/automnt/bin/automnt`。
2. **搬迁操作**：
   - 创建目录并拷贝二进制至目标路径；
   - 移除当前下载目录中的临时副本（`unlink`）；
   - 在检测到的 Shell profile 中注入命令入口；
   - 注册 LaunchAgent 后台服务（事件驱动，无 `StartInterval`）。
3. **输出提示**：
```text
✓ 成功安装 automnt 到规范目录: ~/Library/Application Support/automnt/bin/automnt
✓ 原下载临时副本已安全清理
✓ 已配置命令行入口，可在新终端窗口直接运行: automnt
✓ 后台网络监听守护已加载就绪
```
4. **引导后续**：若当前不存在配置文件，直接无缝唤醒初始化配置向导，引导用户录入首个挂载目标与策略。

# 卸载行为契约

### 常规卸载 (`automnt --uninstall`)

1. 注销并移除 `~/Library/LaunchAgents/com.user.automnt.plist`；
2. 清理用户 Shell profile 中的 automnt CLI 入口代码段；
3. 删除 `~/Library/Application Support/automnt/bin/automnt` 二进制；
4. **保留配置文件** `~/Library/Application Support/automnt/automnt.plist`；
5. 控制台输出：
```text
✓ 已注销后台守护服务
✓ 已从 Shell 配置文件中移除命令入口
✓ 已清理安装的可执行程序
ℹ 配置文件已保留: ~/Library/Application Support/automnt/automnt.plist
  若需彻底清理配置，请执行: automnt --uninstall --purge 或手动删除该文件
```

### 彻底清理 (`automnt --uninstall --purge`)

1. 执行上述常规卸载全部清理项；
2. 彻底删除 `~/Library/Application Support/automnt/` 目录及其下的全部配置文件与备份；
3. 控制台确认输出已彻底清除所有数据。

# 退出状态码契约

| 状态码 | 语义 |
| :--- | :--- |
| `0` | 执行成功（策略命中并挂载完成、自测全过、或配置成功保存并退出）。 |
| `1` | 常规错误（配置无效、参数错误、用户取消操作）。 |
| `2` | 网络不可达或策略全部跳过（无任何策略命中）。 |
| `3` | 文件系统或权限异常（挂载点无法创建、钥匙串凭据缺失）。 |
| `4` | 状态严重损坏且无法自愈。 |
