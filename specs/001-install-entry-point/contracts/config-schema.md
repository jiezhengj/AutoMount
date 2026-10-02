本文档规范单一活动配置文件 `~/Library/Application Support/automnt/automnt.plist` 的 XML 结构、键值类型与验证约束。

# 配置文件结构示例

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>version</key>
    <string>3.0.0</string>
    <key>update_channel</key>
    <string>off</string>
    <key>retry_policy</key>
    <dict>
        <key>max_attempts</key>
        <integer>3</integer>
        <key>interval_ms</key>
        <integer>1000</integer>
        <key>max_total_window_ms</key>
        <integer>10000</integer>
    </dict>
    <key>profiles</key>
    <array>
        <!-- 策略 1: 本地局域网直连 (面向高速 NAS 主机 445 端口直连) -->
        <dict>
            <key>id</key>
            <string>local_lan</string>
            <key>description</key>
            <string>本地局域网高速直连</string>
            <key>host</key>
            <string>nas.local</string>
            <key>port</key>
            <integer>445</integer>
            <key>timeout_ms</key>
            <integer>1000</integer>
            <key>targets</key>
            <array>
                <dict>
                    <key>smb_url</key>
                    <string>smb://nas.local/documents</string>
                    <key>mount_path</key>
                    <string>/Volumes/documents</string>
                </dict>
            </array>
        </dict>
        <!-- 策略 2: 远端 Tailscale 互联 (面向异地 VPN/Tailscale 节点) -->
        <dict>
            <key>id</key>
            <string>remote_network</string>
            <key>description</key>
            <string>远程网络互联</string>
            <key>host</key>
            <string>nas.example.ts.net</string>
            <key>port</key>
            <integer>445</integer>
            <key>timeout_ms</key>
            <integer>1500</integer>
            <key>targets</key>
            <array>
                <dict>
                    <key>smb_url</key>
                    <string>smb://nas.example.ts.net/documents</string>
                    <key>mount_path</key>
                    <string>/Volumes/documents</string>
                </dict>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

# 根字典键规范

| 键名 (Key) | 类型 (Type) | 必须 | 语义说明 |
| :--- | :--- | :--- | :--- |
| `version` | String | 是 | 配置文件格式规范版本号，必须与程序版本保持全局严格对齐。 |
| `update_channel` | String | 是 | 自动更新策略：`off`（默认）、`notify`、`auto`。 |
| `retry_policy` | Dictionary | 否 | 网络事件触发时的有限重试参数，缺省时使用系统默认值。 |
| `profiles` | Array | 是 | 网络策略规则数组，自顶向下按数组顺序具有严格的评估优先级。 |
| `last_update_check_timestamp` | Real | 否 | 上一次尝试检查新版本的 Unix 时间戳（秒）。 |
| `update_retry_after_timestamp` | Real | 否 | 自动更新遇到网络异常时的指数退避重试时间点。 |
| `last_notified_version` | String | 否 | 已经向用户弹出系统通知的最高版本号（防打扰）。 |

# 策略字典键规范 (`profiles[*]`)

| 键名 (Key) | 类型 (Type) | 必须 | 语义说明 |
| :--- | :--- | :--- | :--- |
| `id` | String | 是 | 策略唯一标识符（例如 `local_lan`、`remote_network`）。 |
| `description` | String | 是 | 策略的人类可读描述文本。 |
| `host` | String | 是 | 目标探测主机名称或 IP 地址（不得包含协议前缀）。 |
| `port` | Integer | 否 | 探测端口，默认 `445`。 |
| `timeout_ms` | Integer | 否 | 单次 TCP 握手超时时间（毫秒），默认 `1000`。 |
| `targets` | Array | 是 | 匹配成功时待挂载的目标列表。 |

# 废弃与禁止字段说明

- **`gateway_mac` / `mac`**：全面废弃并严禁出现。若解析到此类历史遗留字段，解析器自动忽略，且不会写回新配置文件。
- **`router_ip` / `interface`**：全面废弃。
- **凭据相关键（如 `username`、`password`）**：严禁出现。程序保存配置前必须校验并拒绝任何包含明文凭据的字典。
