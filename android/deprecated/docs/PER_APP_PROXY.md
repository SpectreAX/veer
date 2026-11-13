# 应用分流（Per-App Proxy）

状态：已完成（2026-07-29）

## 目标

在 Android VPN 建立阶段按应用限定 TUN 的 UID 范围，支持三种互斥模式：

1. **代理所有应用**：默认模式；除 Veer 自身外，所有应用进入 VPN。
2. **仅代理所选应用**：只有用户选择的应用进入 VPN。
3. **绕过所选应用**：所选应用直连，其余应用进入 VPN。

Veer 自身始终不进入 TUN，防止订阅请求、AI 请求和核心控制流形成代理环路。

## 数据与进程边界

策略存储在：

```text
<filesDir>/settings/per_app_proxy.json
```

格式为带版本号的 JSON：

```json
{
  "schemaVersion": 1,
  "mode": "BYPASS_SELECTED",
  "packageNames": ["com.example.bank"]
}
```

UI 进程是唯一写入者，使用临时文件加原子替换提交。`:veercore` 不缓存 UI
进程内状态，而是在每次建立 TUN 前读取完整快照，避免使用
`SharedPreferences` 产生多进程缓存不一致。

## Builder 约束与安全策略

Android 禁止在同一个 `VpnService.Builder` 中混用
`addAllowedApplication()` 与 `addDisallowedApplication()`。Veer 因此先完成纯逻辑
preflight，再执行 Builder 调用：

- `ALL_APPS`：deny-list 仅包含 `com.yamax.veer`。
- `ONLY_SELECTED`：allow-list 包含仍然安装的所选应用，不再调用 deny-list。
- `BYPASS_SELECTED`：deny-list 包含 Veer 和仍然安装的所选应用。
- 已卸载应用会保留在 UI 中并标记“不可用”，可由用户取消选择。
- 如果 `ONLY_SELECTED` 中没有任何仍安装的应用，核心会 fail-safe 回退到
  `ALL_APPS`，防止产生“VPN 显示已连接，但没有应用流量进入隧道”的空连接。

策略变更只有重新建立 TUN 才能生效。VPN 运行中保存时，界面自动发起服务内快速
重连；未连接时则在下一次启动采用新策略。

## 应用发现与隐私

应用列表通过带 `MAIN` + `LAUNCHER` 的 package visibility query 获取，并展示
应用图标、名称、包名、系统应用标记和搜索。这样覆盖用户可直接启动的普通应用，
同时不申请能枚举整台设备所有软件的 `QUERY_ALL_PACKAGES` 敏感权限。

## 验证

自动化：

- `PerAppVpnPolicyTest`：覆盖默认 deny-list、selected-only allow-list、卸载应用、
  空白名单 fail-safe 和 bypass deny-list。
- `PerAppProxyPolicyStoreTest`：覆盖原子存储 round-trip、规范化和损坏文件回退。
- 完整 `testDebugUnitTest`、`lintDebug`、Release APK/AAB 构建通过。
- Android 16 arm64 模拟器完整仪器测试 16/16 通过。

Android 16 arm64 运行验证：

- 选择“仅代理 Chrome”后，核心日志为
  `mode=ONLY_SELECTED allowed=1 disallowed=0`；系统 VPN UID 范围仅包含 Chrome
  的 UID `10162`（以及同包的多用户 UID `20162`），不包含 Veer UID `10242`。
- 改为“绕过 Chrome”后，核心日志为
  `mode=BYPASS_SELECTED allowed=0 disallowed=2`；系统 VPN UID 范围同时排除
  Chrome 和 Veer。
- 两次运行中策略变更均复用原有 Veercore PID；teardown 实测约 10–19 ms。
- 验收后恢复 `ALL_APPS`；系统 UID 范围仅排除 Veer，VPN、Mihomo 控制器和
  实际互联网检查均恢复健康。
