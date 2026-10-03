本文档提供 Feature `002-init-wizard-ux` 的端到端可执行验证指南，用于在实施交付后独立检验各项用户旅程、异常容错与数据兼容性。

# 准备工作与环境前置

- **操作系统**：macOS 27.0 或更高版本（Apple silicon arm64 架构）；
- **执行终端**：原生 macOS Terminal.app、iTerm2 或兼容 ANSI 的标准终端；
- **程序就绪**：预编译完成的 `automnt` 二进制已就绪（遵循 [README.md](../../README.md) 运行准则）；
- **前置备份**：若系统已存在活动配置，可备份当前配置：
  ```bash
  cp ~/Library/Application\ Support/automnt/automnt.plist /tmp/automnt.plist.bak 2>/dev/null || true
  ```

# 场景一：首次初始化向导循环配置与部署意愿遵从验证 (US1, FR-003, FR-006)

### 执行步骤

1. 启动初始化向导：
   ```bash
   automnt --init
   ```
2. 在候选主机列表中选择编号 `1`（已扫描到的局域网主机），选择添加名下共享并回车确认保存；
3. 观察向导返回的候选主机列表，确认第一台主机已显示 `[✓] 已配置` 标记且不可再次点选；
4. 选择第二台主机录入备选顺位（或选择手动录入远程主机），完成从属共享配置；
5. 输入 `d` 完成主机配置，按提示完成自动更新策略设置；
6. 在末尾的“后台守护服务部署确认”提示中，输入 `n`（选择暂不部署）。

### 预期结果与判定标准

- 检查活动配置文件：`cat ~/Library/Application\ Support/automnt/automnt.plist`，确认生成了符合 [contracts/config-schema.md](contracts/config-schema.md) 的标准 XML，其中包含顺位有序的 2 台主机；
- 检查 LaunchAgent 守护服务：执行 `launchctl list | grep automnt` 应返回空，且用户服务定义文件 `~/Library/LaunchAgents/com.user.automnt.plist` 不存在或未被加载，严格遵从了用户的部署意愿。

# 场景二：标准挂载点零误伤推导与 `-1` 污染根除验证 (US2, FR-004)

### 执行步骤

1. 验证标准挂载点推导算法对本地临时冲突的净化：
   - 当系统存在因断网冲突挂载在 `/Volumes/Public-1` 的卷宗（其实际 SMB 地址为 `smb://192.168.1.100/Public`）时，通过向导扫描导入或手动添加；
   - 查看生成的配置文件中该共享的 `mount_point` 键值。
2. 验证合法包含数字的共享文件夹命名保护：
   - 手动或扫描添加 SMB 地址为 `smb://192.168.1.100/data-1` 的共享。

### 预期结果与判定标准

- 针对卷宗 `Public-1`：配置文件中的 `mount_point` 严格规整为 `/Volumes/Public`，`-1` 临时后缀被 100% 根除；
- 针对卷宗 `data-1`：配置文件中的 `mount_point` 准确保留为 `/Volumes/data-1`，绝不发生将合法 `-1` 误裁剪的情况。

# 场景三：交互行输入 Esc 键即时取消与安全回退验证 (US4, FR-005)

### 执行步骤

1. 运行日常配置管理：
   ```bash
   automnt --config
   ```
2. 选择 `[a]` 进入新增主机流程；
3. 选择手动输入主机地址，在提示符出现后键入若干测试字符（例如 `10.0.0.99`）；
4. 直接按下键盘左上角的 `Esc` 键；
5. 观察终端输出与返回状态。

### 预期结果与判定标准

- 终端当前行被整行清除，立即打印 `(已取消)`；
- 程序平稳、无缝回退到日常配置的主菜单，未产生任何未完成的半成品主机配置，终端未抛出任何错误，无程序崩溃。

# 场景四：空配置合法化与安全休眠验证 (US5, FR-007)

### 执行步骤

1. 运行日常配置管理：
   ```bash
   automnt --config
   ```
2. 使用 `[d]` 功能逐一删除所有主机，直到主机列表呈现为空（0 台主机）；
3. 系统提示“当前主机列表为空...保存并退出配置？”，输入 `Y` 确认保存；
4. 退出后，在终端手动执行一次挂载评估：
   ```bash
   automnt
   echo "Exit Code: $?"
   ```

### 预期结果与判定标准

- 执行 `automnt` 后的退出码必须严格为 `0`（`Exit Code: 0`）；
- 终端与日志输出显示：“当前配置包含 0 台主机，进入安全休眠状态”，系统不提示“配置文件损坏”，不报错，不拉起初始化向导。

# 场景五：存量旧版配置文件原地平滑升舱验证 (US6, FR-008)

### 执行步骤

1. 构造一份包含旧版 `v3.0.0` 结构的测试配置文件（写入旧格式 `profiles`，包含描述、探活超时、防索引设置及带 `-1` 污染的共享路径）：
   ```bash
   cat << 'EOF' > ~/Library/Application\ Support/automnt/automnt.plist
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>version</key>
       <string>3.0.0</string>
       <key>profiles</key>
       <array>
           <dict>
               <key>id</key>
               <string>legacy_lan</string>
               <key>description</key>
               <string>原有局域网直连</string>
               <key>host</key>
               <string>192.168.1.100</string>
               <key>port</key>
               <integer>445</integer>
               <key>timeout_ms</key>
               <integer>1200</integer>
               <key>prevent_spotlight_index</key>
               <true/>
               <key>targets</key>
               <array>
                   <dict>
                       <key>smb_url</key>
                       <string>smb://192.168.1.100/Public</string>
                       <key>mount_path</key>
                       <string>/Volumes/Public-1</string>
                   </dict>
               </array>
           </dict>
       </array>
   </dict>
   </plist>
   EOF
   ```
2. 执行状态查询命令触发升舱：
   ```bash
   automnt --status
   ```
3. 检查升舱后的配置文件内容：
   ```bash
   cat ~/Library/Application\ Support/automnt/automnt.plist
   ```

### 预期结果与判定标准

- 配置文件版本自动升级为 `3.1.0`；
- 原 `profiles` 数组被成功升舱为 `hosts` 列表；
- 原 `description`（“原有局域网直连”）无损映射为 `alias`；
- 原 `timeout_ms`（`1200`）与 `prevent_spotlight_index`（`true`）无损继承；
- 原受污染的挂载路径 `/Volumes/Public-1` 被自动清洗还原为标准路径 `/Volumes/Public`；
- 整个升舱过程就地原子完成，无外部冗余配置文件残留。

# 场景六：全量内置自动化自测验证

### 执行步骤

在终端直接运行内置自测套件：
```bash
automnt --self-test
```

### 预期结果与判定标准

- 终端依次输出自测套件执行详情（包含挂载点推导、URL 格式校验、配置升舱解析、字符流解析、空配置休眠等用例）；
- 自测套件全项通过（`Self-test passed`），退出状态码为 `0`。
