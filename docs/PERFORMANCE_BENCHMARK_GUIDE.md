# Veer Android 性能基准指南

更新日期：2026-07-29

## 目标

该基准用于生成可复现的 Veer 自身趋势数据，并为后续 Veer、FlClash、
ClashMetaForAndroid 同机 A/B 提供统一结果结构。

当前第一阶段覆盖：

- VPN 停止到 `EngineState.Running` 的时间
- 控制器可用时间
- 通过 Android 端 Mihomo mixed-port 完成真实 HTTPS 204 的时间
- 稳态 PSS、RSS、Java/Native heap
- 固定窗口内 UI 与 Veercore 各自的 CPU
- Mihomo 控制器常用接口的响应体积与耗时

## 前置条件

1. 安装 Veer debug APK。
2. 至少导入并激活一个有效配置。
3. 手动完成一次 Android VPN 授权。
4. 设备可通过 `adb devices` 访问。
5. 主机安装 `python3` 和 `curl`。

脚本只使用 debug manifest 中受 `android.permission.DUMP` 保护的显式广播。
release 包不包含这些入口。脚本不会读取配置、订阅、API Key 或 app 私有凭据。

## 运行

```bash
python3 tools/perf/veer_benchmark.py \
  --adb "$HOME/Library/Android/sdk/platform-tools/adb" \
  --serial emulator-5554 \
  --iterations 5 \
  --warmup-seconds 30 \
  --cpu-sample-seconds 10 \
  --memory-samples 3 \
  --steady-ui-state background
```

默认输出到：

```text
build/perf/<UTC timestamp>/
├── result.json
└── startup.csv
```

无论基准成功还是中途失败，脚本都会尝试让 Veer 恢复到 Running。

## 数据解释

- `running_ms`：发送 debug 启动命令到进程状态变成 Running。
- `controller_ready_ms`：启动命令到 `/version` 返回 200。
- `internet_ready_ms`：启动命令到主机通过 adb-forward 的 Android mixed-port
  完成真实 HTTPS 请求。它包含代理节点网络延迟，不等于纯本地启动耗时。
- CPU 百分比按单个 CPU 核心为 100% 计算。
- `schema_version=2` 分别输出 `ui` 与 `core` 的内存/CPU，并提供两者合计。
- `--steady-ui-state background` 会先返回桌面；`foreground` 会显式启动
  `MainActivity`。两者都保持 VPN Running。
- PSS/RSS 取自多次 `dumpsys meminfo` 的中位数；必须在相同 warmup、设备、
  配置、采样次数和前后台状态下比较。
- 跨进程总内存优先比较 aggregate PSS。aggregate RSS 会把两个进程共享的
  APK、`.so` 和系统映射重复计入，不能当作物理内存占用。
- debug 构建用于研发回归；发布结论必须另用可测量的 release/profileable 构建复测。

## A/B 约束

比较不同客户端时必须固定：

- 同一台设备、系统、电量和温控状态
- 同一网络、订阅快照、节点和 Mihomo 版本
- 相同 TUN stack、MTU、DNS 模式和 IPv6 设置
- 相同 warmup 与采样窗口

竞品不具备 Veer debug 生命周期入口，因此其启动测量适配器需要单独实现；不得用
Veer 的内部 Running 时间与竞品仅 Activity 启动时间直接对比。
