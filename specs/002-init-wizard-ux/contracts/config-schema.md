本文档规范单一活动配置文件 `~/Library/Application Support/automnt/automnt.plist` 在 `v3.1.0` 规范下的 XML 属性列表（Property List）结构、键值类型与约束。

# 配置文件结构示例

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>version</key>
    <string>3.1.0</string>
    <key>update_channel</key>
    <string>notify</string>
    <key>retry_policy</key>
    <dict>
        <key>max_attempts</key>
        <integer>3</integer>
        <key>interval_ms</key>
        <integer>1000</integer>
        <key>max_total_window_ms</key>
        <integer>10000</integer>
    </dict>
    <key>hosts</key>
    <array>
        <!-- 顺位 1: 最高优先级主机 (如局域网直连) -->
        <dict>
            <key>host</key>
            <string>192.168.1.100</string>
            <key>alias</key>
            <string>家庭高速 NAS</string>
            <key>port</key>
            <integer>445</integer>
            <key>timeout_ms</key>
            <integer>1000</integer>
            <key>prevent_spotlight_index</key>
            <true/>
            <key>enabled</key>
            <true/>
            <key>shares</key>
            <array>
                <dict>
                    <key>name</key>
                    <string>Public</string>
                    <key>smb_url</key>
                    <string>smb://192.168.1.100/Public</string>
                    <key>mount_point</key>
                    <string>/Volumes/Public</string>
                    <key>enabled</key>
                    <true/>
                </dict>
                <dict>
                    <key>name</key>
                    <string>data-1</string>
                    <key>smb_url</key>
                    <string>smb://192.168.1.100/data-1</string>
                    <key>mount_point</key>
                    <string>/Volumes/data-1</string>
                    <key>enabled</key>
                    <true/>
                </dict>
            </array>
        </dict>
        <!-- 顺位 2: 备用顺位主机 (如远程互联，未配置 alias 示例) -->
        <dict>
            <key>host</key>
            <string>nas.example.org</string>
            <key>port</key>
            <integer>445</integer>
            <key>timeout_ms</key>
            <integer>1500</integer>
            <key>prevent_spotlight_index</key>
            <true/>
            <key>enabled</key>
            <true/>
            <key>shares</key>
            <array>
                <dict>
                    <key>name</key>
                    <string>Public</string>
                    <key>smb_url</key>
                    <string>smb://nas.example.org/Public</string>
                    <key>mount_point</key>
                    <string>/Volumes/Public</string>
                    <key>enabled</key>
                    <true/>
                </dict>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

# 根字典字段规范

| 键名 (Key) | 数据类型 | 必须 | 默认值 | 描述 |
| :--- | :--- | :--- | :--- | :--- |
| `version` | String | 是 | `"3.1.0"` | 规范版本号，固定为 `"3.1.0"`。 |
| `hosts` | Array<Dict> | 是 | `[]` | 有序的主机顺位列表。允许为空数组 `[]`（表示合法空配置）。 |
| `update_channel` | String | 否 | `"off"` | 自动更新检查策略模式（`"off"`, `"notify"`, `"auto"`）。 |
| `retry_policy` | Dict | 否 | - | 事件触发有限重试策略（`max_attempts`, `interval_ms`, `max_total_window_ms`）。 |
| `last_update_check_timestamp` | Real | 否 | `nil` | 最近一次尝试检查更新的 UNIX 时间戳。 |
| `update_retry_after_timestamp` | Real | 否 | `nil` | 更新检查失败退避重试时间戳。 |
| `last_notified_version` | String | 否 | `nil` | 最近一次向用户发出提示的版本号（防重复打扰）。 |

# 主机字典 (Host Dictionary) 字段规范

| 键名 (Key) | 数据类型 | 必须 | 默认值 | 约束与校验规则 |
| :--- | :--- | :--- | :--- | :--- |
| `host` | String | 是 | - | 目标主机地址（IP、局域网 mDNS、远程域名）。严禁协议前缀、斜杠与端口。 |
| `alias` | String | 否 | `nil` | 人类友好别名/显示名称。未设置时属性列表中省略此键，展示时回退使用 `host`。 |
| `port` | Integer | 否 | `445` | TCP 探测端口，有效范围 1...65535。 |
| `timeout_ms` | Integer | 否 | `1000` | 针对该主机的探测超时毫秒，有效范围 100...30000。 |
| `prevent_spotlight_index` | Boolean | 否 | `true` | 是否对该主机的挂载卷禁用 Spotlight 索引扫描。 |
| `enabled` | Boolean | 否 | `true` | 是否参与顺位探测。 |
| `shares` | Array<Dict> | 是 | `[]` | 从属于该主机的 SMB 共享文件夹清单。 |

# 共享字典 (Share Dictionary) 字段规范

| 键名 (Key) | 数据类型 | 必须 | 默认值 | 约束与校验规则 |
| :--- | :--- | :--- | :--- | :--- |
| `name` | String | 是 | - | 共享文件夹名称。 |
| `smb_url` | String | 是 | - | 标准 SMB URL（必须以 `smb://` 起手，严禁内嵌明文密码）。 |
| `mount_point` | String | 是 | - | 标准目标挂载点，必须形如 `/Volumes/<shareName>`。严禁含有临时冲突后缀 `-1`。 |
| `enabled` | Boolean | 否 | `true` | 是否启用自动挂载。 |

# 废弃与禁止字段清单

- ❌ `profiles`：旧版网络策略顶层数组（已废弃并由 `hosts` 替代）。
- ❌ `id`：旧版策略内部标识符（已废弃）。
- ❌ `targets`：旧版挂载目标数组（已重命名为 `shares`）。
- ❌ `mount_path`：旧版挂载路径字段（已重命名为 `mount_point`）。
- ❌ `gateway_mac`, `router_ip`：链路层字段（严格禁止出现）。
