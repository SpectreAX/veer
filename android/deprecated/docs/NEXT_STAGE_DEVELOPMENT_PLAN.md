# Veer 下一阶段开发计划

开始日期：2026-07-28  
阶段目标：将当前可验证原型推进为可日常使用的 Alpha 版本。

## 执行规则

- 严格按优先级逐项执行；前一项未通过验收，不进入下一项。
- 每项必须至少通过代码检查、自动化测试和与风险相匹配的运行验证。
- 每项完成后，在本文档记录验证命令、设备/环境、结果和遗留问题。
- 不用“代码已编译”代替功能验收；涉及 VPN、代理、配置或 AI 的功能必须做端到端验证。
- 发现阻断性缺陷时，先修复并补回归测试，再继续原计划。

## 里程碑 A：稳定性与配置隔离

### 1. AI 规则按配置文件隔离

状态：已完成（2026-07-28）

实现内容：

- 每个本地配置或订阅拥有独立的 AI 规则集合。
- 激活配置时只合并该配置所属的 AI 规则。
- 将现有全局规则安全迁移到迁移时的活动配置。
- 切换配置后，不得引用另一个配置中的节点或策略组。

验收标准：

- 配置 A 添加的规则不会出现在配置 B 的运行配置中。
- 切回配置 A 后规则仍然存在并重新生效。
- 旧版本全局规则完成一次性迁移，不丢失、不重复。
- 两个配置分别启动 Mihomo 均通过配置验证。

### 2. 运行中安全切换配置

状态：已完成（2026-07-28）

实现内容：

- 串行执行停止旧内核、释放 TUN、激活配置、启动新内核。
- 为 Starting/Stopping 增加超时、幂等保护和用户可读错误。
- 阻止快速重复点击产生并行启动或停止。

验收标准：

- 连续切换并启停 20 次，无卡死、残留 TUN 或重复内核。
- 启停超时会进入明确错误状态，并提供安全恢复路径。

### 3. Last Known Good 自动回滚

状态：已完成（2026-07-28）

实现内容：

- 保存最近一次成功运行配置。
- 新配置验证或启动失败时自动回滚。
- 记录失败阶段、错误和配置摘要。

验收标准：

- 导入无效配置不会让设备持续断网。
- 回滚后控制器、DNS 和网页访问恢复。

## 里程碑 B：规则与节点管理

### 4. AI 规则管理页面

状态：已完成（2026-07-28）

实现内容：

- 展示规则目标、匹配类型、策略、所属配置和健康状态。
- 支持启用、禁用、删除、改绑策略和重新应用。
- 标记节点不存在、节点不可用、规则未加载。

验收标准：

- 所有操作无需手工修改 YAML。
- 操作后持久化文件、运行规则和 UI 状态一致。

### 5. 节点与策略组页面

状态：已完成（2026-07-28）

实现内容：

- 展示节点地区、延迟、可用性、当前选择和组关系。
- 支持单节点测速、策略组切换和自动选择。
- 继续过滤套餐、流量、到期等订阅元数据伪节点。

验收标准：

- UI 选择与 Mihomo `/proxies` 状态一致。
- 不可用节点有明确提示且不会被误选为低延迟节点。

### 6. 连接状态主页升级

状态：已完成（2026-07-28）

实现内容：

- 展示真实出口地区、IPv4/IPv6、延迟、活动规则和实时流量。
- 区分 VPN 已启动、Mihomo 可用、互联网实际可用。

验收标准：

- 断网、节点故障和正常连接三种状态能被准确区分。

## 里程碑 C：AI 多步骤执行

### 7. 多操作 AI 计划

状态：已完成（2026-07-28）

实现内容：

- 单次指令支持多个站点、策略组和切换操作。
- 定义有版本的操作计划 JSON Schema。

验收标准：

- “Netflix 走日本，YouTube 走美国”可一次完成且逐项反馈。

### 8. 原子执行与回滚

状态：已完成（2026-07-28）

实现内容：

- 执行前验证全部目标和策略。
- 所有修改一次性提交，失败时恢复原规则和选择。

验收标准：

- 任一子操作失败不会留下部分生效配置。

### 9. 确定性本地解析

状态：已完成（2026-07-28）

实现内容：

- 域名、直连、拦截、测速等高置信指令优先本地解析。
- 复杂语义再调用 LLM。

验收标准：

- 常见命令离线可用，输出与 LLM 路径一致。

## 里程碑 D：诊断、恢复与订阅生命周期

### 10. 完整网络诊断执行器

状态：已完成（2026-07-28）

实现内容：

- 检查底层网络、TUN、控制器、DNS、节点连接、目标站点和规则匹配。

验收标准：

- 能区分系统网络、DNS、规则和机场出口四类故障。

### 11. 自动恢复策略

状态：已完成（2026-07-28）

实现内容：

- 节点失败时切换健康替代。
- 自动组异常时回退最后可用节点。
- 恢复失败后安全停止 VPN。

验收标准：

- 故障注入后能恢复联网，或在明确失败状态下释放 TUN。

### 12. 定时刷新订阅

状态：已完成（2026-07-28）

实现内容：

- 使用 WorkManager 定期更新。
- 支持刷新历史、退避重试和配置差异摘要。

验收标准：

- 后台刷新不会中断当前连接；失败不覆盖可用配置。

### 13. 订阅信息与敏感数据安全

状态：已完成（2026-07-28）

实现内容：

- 展示流量、到期时间和更新时间。
- 隐藏订阅令牌，使用 Android Keystore 保护 API Key。
- 日志导出自动脱敏。

验收标准：

- UI、日志、崩溃报告和版本库均不出现完整令牌或 API Key。

## 里程碑 E：发布前质量保障

### 14. 自动化测试矩阵

状态：已完成（2026-07-28）

实现内容：

- Mihomo 控制器、LLM 异常、配置切换、规则回滚和订阅刷新测试。
- Android 模拟器端到端流量回归。

验收标准：

- Debug/Release 构建、单元测试、仪器测试和核心场景回归全部通过。

### 15. 真机稳定性测试

状态：部分完成（2026-07-30：首台 HyperOS 真机核心矩阵通过）

实现内容：

- Pixel 与 HyperOS/MIUI 真机测试。
- 覆盖锁屏、前后台、网络切换、飞行模式和系统回收。

验收标准：

- 关键生命周期场景无崩溃、无永久断网、无无法恢复的 TUN 残留。

## 验证记录

### 第 1 项：AI 规则按配置文件隔离

状态：已通过。

实现摘要：

- AI 规则由全局 `mihomo/ai_override.yaml` 改为按配置 ID 存储在
  `mihomo/ai_rules/{profileId}.yaml`。
- 活动配置 ID 与 YAML 作为同一个不可分割状态更新，避免并发读取到不匹配的
  配置和规则作用域。
- 旧版全局规则只迁移一次到迁移时的活动配置，并写入迁移标记。
- 删除配置时同步删除所属规则；取消活动配置时清除活动规则作用域。
- 运行时仍会过滤当前配置中不存在的节点或策略，防止无效历史规则阻断启动。

验证环境：

- macOS 主机，Homebrew JDK 21。
- Android 16 模拟器 `emulator-5554`。
- 应用包名 `com.yamax.veer`。

自动化验证：

```text
./gradlew :app:testDebugUnitTest :app:installDebug :app:assembleRelease --console=plain
```

结果：Debug 单元测试、模拟器安装和 Release 构建全部通过。新增测试覆盖旧规则
一次性迁移、不同配置作用域文件独立，以及已有的无效跨配置策略过滤。

端到端验证：

1. 在新订阅配置中添加唯一规则
   `DOMAIN-SUFFIX,veer-scope-test.invalid,DIRECT`。
2. 切换到旧配置 `Veer-restored`：该配置没有对应规则文件，运行时
   `base.yaml` 中规则匹配数为 0；Mihomo 配置验证及启动成功。
3. 切回新订阅配置：所属规则文件仍存在，运行时 `base.yaml` 中匹配数为 1；
   `VALIDATE_CONFIG`、`ESTABLISH_TUN` 和 `START_RUNTIME` 全部成功，界面进入
   `Running`。
4. 设备上只生成一个迁移标记；重复加载没有再次复制旧规则。

结论：配置 A 的规则不会泄漏到配置 B，切回 A 后规则可恢复，两个配置均可启动。

遗留问题：旧配置停止 VPN 时出现过一次停止超时，需要强制重启应用恢复。该问题
不影响规则隔离结论，已纳入第 2 项“运行中安全切换配置”处理。

### 第 2 项：运行中安全切换配置

状态：已通过。

实现摘要：

- 新增配置切换协调器，以互斥事务串行执行
  `停止旧内核 → 等待 Stopped → 激活配置 → 启动新内核 → 等待 Running`。
- 配置切换使用保留前台服务实例的准备动作，停止 Mihomo 并释放 TUN，不再依赖
  Android 延迟不确定的 `onDestroy()`。
- 停止、启动均有终态等待和超时恢复；失败时不会在旧内核仍存活时改写活动配置。
- UI 在协程启动前同步占用切换状态，屏蔽同一帧快速连点及切换期间的编辑、删除和刷新。
- Mihomo 升级到 `v1.19.29`，Veercore 升级到
  `0.1.6+mihomo-1.19.29.cmfa.gvisor`。
- Veercore 停止时主动挂起隧道、关闭兼容 provider、规则 provider、活动 tracker
  和监听器，避免健康检查与旧 TUN 跨重启残留。
- 修复 Veercore 日志订阅泄漏：进程内重启复用唯一订阅，替换 Logger 时只更新投递目标；
  分离时调用 `UnSubscribe`。此前旧订阅的 200 条缓冲区填满会阻塞 mihomo 全局日志通道，
  进而让第二次 `Start()` 卡在日志发送。

自动化验证：

```text
go test ./...
./gradlew testDebugUnitTest assembleDebug assembleRelease lintDebug
```

结果：Go 包测试、Debug 单元测试、Debug/Release 构建和 Android Lint 均执行成功。
协调器单元测试覆盖离线激活、运行中切换顺序、Android 异步启动、停止超时不激活、
启动超时恢复、错误终态和重复操作拒绝。Lint 无错误，现有依赖版本、废弃 SDK 判断、
未使用资源及 native 16 KB 对齐等警告留待发布质量阶段统一处理。

端到端验证：

1. Android 16 模拟器上在两个真实订阅配置间连续交替切换 20 次。
2. 每轮都验证状态至少经过一次非 `Running` 状态、活动 profile ID 与目标一致，
   最终恢复 `Running`；结果 20/20 通过。
3. 连续快速点击同一个 Activate 按钮 5 次，只产生 1 次停止请求、1 次激活和
   1 次 `Running → Stopping` 迁移。
4. 切换后 Android 将 Veer VPN 标记为 `VALIDATED`；IP 与 DNS 连通探测均为
   0% 丢包，Fake-IP 域名解析正常。
5. 现场 goroutine dump 验证修复前阻塞点位于遗留日志订阅，修复后不再出现
   JNI 停止超时、重复内核或无法退出的 `Starting`。

结论：运行中配置切换事务、超时边界和重复点击保护符合验收标准。

### 第 3 项：Last Known Good 自动回滚

状态：已通过。

实现摘要：

- 每次活动配置真正进入 `Running` 前，原子保存活动 profile 元数据和一份独立的
  `last_known_good_config.yaml`。快照保存实际成功配置，不依赖之后可能被刷新覆盖的
  profile 文件。
- 配置切换前再次确认并保存当前运行配置；目标配置激活、启动命令、运行时启动或
  启动超时任一阶段失败后，必须先等待失败实例与 TUN 完全进入 `Stopped`，才能恢复
  快照并重启。
- 回滚本身也有启动终态与超时边界；无法安全停止时禁止在同一进程继续启动，并要求
  用户重启 Veer。
- `index.json` 持久化最近失败的目标 profile、上一 profile、失败阶段、截断后的错误
  摘要、发生时间和回滚结果，不保存订阅地址、配置正文或凭据。
- 删除 Last Known Good 所属 profile 时同步清除快照。
- Profile 页面显示“正在恢复”阶段和最终恢复结果。

自动化验证：

```text
go test ./...
./gradlew testDebugUnitTest
./gradlew connectedDebugAndroidTest
./gradlew assembleDebug assembleRelease lintDebug
```

结果：Go 测试、单元测试、Debug/Release 构建与 Lint 全部成功；Android 16 模拟器
仪器任务完成 19 个测试条目，其中依赖专用 VPN 前置状态的 8 个生命周期用例按既有
假设条件跳过。新增协调器测试覆盖运行时启动失败后成功回滚、激活失败后恢复，以及
无快照时保持安全停止。

端到端故障注入：

1. 当前订阅配置进入 `Running`，确认 Last Known Good 快照已持久化。
2. 对下一次 Veercore `Start()` 注入一次性、仅触发一次的启动错误。
3. 尝试切换到另一配置：目标 profile 已激活并进入 `Starting`，随后出现注入的
   `START_RUNTIME` 错误。
4. Veer 自动完成失败实例 `Error → Stopping → Stopped`，恢复上一 profile 快照，
   再次启动并进入 `Running`。
5. 持久化失败记录为 `stage=START_RUNTIME`、`rollbackSucceeded=true`；页面提示
   已恢复最后可用配置并重新连接。
6. 回滚后 Android VPN 为 `VALIDATED`，IP 与 Fake-IP/DNS 连通探测均为 0% 丢包。

结论：无效或启动失败的新配置不会覆盖 Last Known Good 快照，也不会让设备持续处于
黑洞 TUN；安全可恢复时自动重新联网，不安全时停止继续启动。

### 第 4 项：AI 规则管理页面

状态：已通过。

实现摘要：

- 在当前实际使用的 Phase 1.5 主界面增加 `AI Rules` 入口和独立 Compose 管理页，
  不替换已经验证的 VPN、配置和 AI 入口。
- 页面展示匹配类型、目标、策略、所属配置及运行健康状态，支持启用、禁用、删除、
  从当前配置的真实策略列表改绑，以及手动重新应用。
- 规则文件保持向后兼容：启用规则继续存储在 `payload`，禁用规则存储在
  `disabled-payload`；旧文件无需迁移即可读取。
- 所有修改均先原子持久化，再重新生成 `base.yaml`；VPN 处于 `Running` 时调用
  Veercore 热重载，不重建 Android TUN。
- 当前配置中不存在的策略显示“策略不存在 · 未加载”，已知不可用的具体节点显示
  “节点不可用”；未连接或未进入物化配置的规则显示“未加载”。
- 规则 ID 由匹配器而非策略生成，改绑后仍可稳定执行后续启用、禁用和删除。
- 规则清单采用轻量扫描提取策略及物化状态，避免规则页冷启动完整解析大型订阅 YAML。

自动化验证：

```text
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintDebug --console=plain
```

结果：Debug 单元测试、Debug/Release 构建和 Android Lint 全部通过。新增测试覆盖
启用/禁用集合的向后兼容读写、启用/禁用/删除/改绑状态转换、带 `no-resolve`
修饰符的规则改绑，以及节点和策略组清单提取。

Android 16 模拟器端到端验证：

1. 向当前活动配置加入测试规则，页面正确展示所属配置、`DOMAIN-SUFFIX`、目标、
   `DIRECT` 和“运行中”。
2. 禁用后 UI 显示“已禁用”，规则移动至 `disabled-payload`，`base.yaml` 中匹配数
   从 1 变为 0，Veercore 日志确认规则表热重载。
3. 重新启用后规则回到 `payload`，`base.yaml` 匹配数恢复为 1，UI 恢复“运行中”。
4. 从页面将策略改绑为 `REJECT`，持久化文件、`base.yaml` 和 UI 同时更新，运行时
   再次热重载。
5. 加入引用已删除节点的规则，页面标记“策略不存在 · 未加载”，规则保留在所属配置
   文件中但未进入 `base.yaml`。
6. 通过页面删除两条测试规则，UI 回到空状态，规则文件和物化配置均无残留。
7. 全部操作后 IP 与域名连通探测均为 0% 丢包；最终测试规则已清理。

结论：规则管理操作无需编辑 YAML，持久化文件、运行规则和 UI 状态符合一致性验收。

### 第 5 项：节点与策略组页面

状态：已通过。

实现摘要：

- 在 Phase 1.5 主界面增加 `Nodes` 入口和独立 Compose 页面，直接读取 Mihomo
  `/proxies` 实时快照，不使用导入配置中的静态选择作为运行状态。
- 展示 Selector、URLTest、Fallback 和 LoadBalance 组，包含当前选择、真实叶子节点、
  组关系、节点协议、地区、历史延迟和可用性。
- Selector 支持手动选择节点；操作成功后重新读取控制器快照，以控制器返回值校正 UI。
- 支持单节点即时测速，调用 Mihomo delay endpoint 并更新节点延迟/健康状态。
- 支持“自动选低延迟”，并发执行新鲜延迟探测，排除当前链路、已知故障节点和订阅
  元数据后切换到实测最低延迟候选。
- 套餐、流量、到期等订阅状态行和 `DIRECT`/`REJECT` 等内建动作不会伪装成可测速节点。

自动化验证：

```text
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintDebug --console=plain
```

结果：Debug 单元测试、Debug/Release 构建和 Android Lint 全部通过。路由快照测试继续
覆盖低延迟候选、自动组稳定性、故障节点排除和地区等价替代，并新增常见节点命名的
地区码识别验证。

Android 16 模拟器端到端验证：

1. VPN 为 `Running` 时页面显示 `GLOBAL` 等真实组、当前选择、香港等叶子节点及延迟；
   UI 未出现套餐、流量、到期伪节点。
2. 从页面将 `GLOBAL` 由 `DIRECT` 手动切换为一个香港节点，UI 显示“已选择”，
   Mihomo `/proxies/GLOBAL` 的 `now` 同步返回该香港节点。
3. 对已选香港节点执行单节点测速，UI 返回 120ms 并更新节点行；控制器选择保持不变。
4. 执行“自动选低延迟”，Veer 通过新鲜探测选择 103ms 的澳门节点；UI 与控制器
   `now` 同时更新为该节点。
5. 安装最终 Debug 包并重启 VPN 后，控制器保留澳门选择；最终页面不再显示
   `DIRECT`/`REJECT` 为节点，套餐元数据仍为 0 条。
6. 手动切换、测速、自动选择及最终重启后，IP 与域名连通探测均为 0% 丢包。

结论：节点页的选择、延迟、健康状态和组关系来自实时控制器；UI 操作与 Mihomo 状态
一致，不可用节点不会参与自动低延迟选择。

### 第 6 项：连接状态主页升级

状态：已通过。

实现摘要：

- Phase 1.5 首页新增连接状态卡，每 5 秒并发刷新 VPN 生命周期、Mihomo 控制器、
  互联网探测、真实出口、实际路由、流量、活动连接和已加载 AI 规则。
- 出口展示 IPv4、IPv6 和地区；路由展示运行模式、最终 `MATCH/FINAL` 策略组、
  递归解析后的真实叶子节点及其延迟，不再把无效的 `GLOBAL` 选择误认为默认路由。
- 新增控制器 `/connections`、`/configs` 快照读取，并从当前物化配置解析默认策略。
- Veer 自身为避免回环而被排除在 Android TUN 外，因此健康探测和出口 API 显式通过
  `127.0.0.1:7890` Mihomo mixed-port 发起；这保证检测结果经过当前节点和规则。
- 每次互联网探测清空连接池并关闭连接，避免热重载后复用旧连接造成假健康。
- VPN 停止时明确显示“未检测”，不把未执行的探测误报为底层断网。

自动化验证：

```text
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintDebug --console=plain
```

结果：Debug 单元测试、Debug/Release 构建和 Android Lint 全部通过。新增测试覆盖嵌套
出口 API、纯文本 IPv4、Cloudflare trace 地区、最终默认策略解析和策略组叶子递归。

Android 16 模拟器端到端验证：

1. 正常连接时首页显示 VPN `Running`、控制器可用、互联网实际可用 163–445ms、
   HK 出口及真实 IPv4；日志确认探测请求从本地 mixed-port 按 `千速云` 规则出站。
2. 首页路由显示 `千速云[rule] → 实际叶子节点 → 延迟`，与控制器和 Mihomo
   规则匹配日志一致；流量和活动连接随探测实时增加。
3. 热加入 `DOMAIN,www.gstatic.com,REJECT` 后，VPN 和控制器保持健康，但首页在下一轮
   刷新显示“互联网：实际访问失败”，活动 AI 规则从 0 变为 1。
4. 删除该规则并热重载后，7 秒内恢复“实际可用”，规则计数回到 0；应用私有规则文件
   中确认无测试规则残留。
5. 关闭模拟器 Wi-Fi 后 VPN 和 Mihomo 按现有安全生命周期停止，首页显示 VPN 停止、
   控制器不可达和互联网未检测；恢复 Wi-Fi 并重启后重新进入 `Running`，控制器、
   互联网和 HK 出口全部恢复。
6. 最终设备保持 VPN `Running`、Mihomo 可用、互联网实际可用，活动测试规则为 0。

结论：正常连接、代理路径故障和底层断网三种状态具有不同且准确的 UI 结果；出口、
路由和可用性均来自实际 Mihomo 代理链路，而不是宿主机直连结果。

### 第 7 项：多操作 AI 计划

状态：已通过。

实现摘要：

- 新增 `AiPlan`，以 `schema_version: 1` 和有序 `operations` 数组承载 1–8 个动作；
  每项继续使用已有强类型 `AiIntent`，计划本身包含统一完成反馈。
- LLM system instruction 要求按用户语序拆分每个网站、App、策略组或独立动作，并加入
  “Netflix 走日本，YouTube 走美国”的双操作示例。
- 解析器拒绝未知 schema 版本、空计划和超过 8 项的计划；迁移期仍兼容旧版单动作
  JSON，并在本地包装为 schema 1 计划。
- 执行器按顺序执行并逐项保存结果；第 N 项失败时返回具体位置和已完成数量，不把
  未执行项报告为成功。原子预验证和失败回滚属于下一项计划。
- 主页面日志逐项显示动作、结果和 HTTP 状态；Debug E2E 接口返回 schema 版本、
  操作数量及每项目标和策略。

自动化验证：

```text
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintDebug --console=plain
```

结果：Debug 单元测试、Debug/Release 构建和 Android Lint 全部通过。新增测试验证
双操作顺序解析、旧单动作兼容和未知 schema 版本拒绝；system prompt 测试确认包含
版本字段、双服务示例和动态真实节点上下文。

Android 16 模拟器真实 LLM 端到端验证：

1. 输入“Netflix 走日本，YouTube 走美国”，真实模型返回 schema 1、2 个操作，
   目标依次为 `netflix` 和 `youtube`；当前订阅所有日本节点实时健康检查失败，
   执行器在第 1/2 项安全拒绝并报告 0 项完成，未写入部分规则。
2. 输入同结构的可用节点场景“Netflix 走香港，YouTube 走美国”，真实模型返回并
   顺序执行 2 项：`GEOSITE,netflix,🇭🇰香港 04` 和
   `GEOSITE,youtube,🇺🇸美国 02`。
3. 两项均完成持久化和 Mihomo 热重载，调试结果返回
   `schema=1 operations=2` 及两项独立结果。
4. 测试后通过应用接口删除两条规则；活动规则文件恢复为空，首页显示 0 条 AI 规则，
   VPN `Running`、控制器和互联网保持可用。

结论：多目标指令可由一次 LLM 请求形成有版本、有顺序、逐项反馈的操作计划并执行；
不可用节点会在明确的操作位置停止。跨操作的全量预验证和失败回滚继续在第 8 项实现。

### 第 8 项：原子执行与回滚

状态：已通过。

实现摘要：

- AI 计划执行改为两阶段事务，并用互斥锁串行化：第一阶段读取一次最新路由快照，
  对所有规则目标、策略、Selector 成员、节点健康和 selection mode 做全量预验证；
  任一项无效时不执行任何修改。
- 同一计划禁止重复修改同一规则 matcher 或重复切换同一 Selector，避免计划内部
  顺序歧义。
- 多条规则先在内存中的 `AiRuleStore` 批量 upsert，再一次原子写入规则文件、
  一次生成运行配置、一次热重载，不再每条规则单独落盘和重载。
- 提交前保存完整规则存储与每个 Selector 的原选择；提交异常时按逆序恢复已切换的
  Selector，再原子恢复规则存储并热重载恢复配置。
- 执行事务期间拒绝并发 AI 计划交错；成功后仍按原计划顺序生成逐项结果。
- Debug 构建增加仅限显式 ADB 调用的计划 JSON 和提交检查点故障注入，用于验证
  “规则重载后失败”和“Selector 切换后失败”的真实回滚路径。

自动化验证：

```text
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintDebug --console=plain
```

结果：Debug 单元测试、Debug/Release 构建和 Android Lint 全部通过。新增纯函数测试
验证多规则 batch upsert 的逐项变更结果、禁用规则替换和输入存储不变；既有 AI plan、
规则管理和配置合并测试全部回归通过。

Android 16 模拟器事务故障注入：

1. 计划第 1 项为有效 DIRECT 规则、第 2 项引用不存在策略；第 2/2 项预验证失败，
   结果报告“计划未执行”，规则文件和 `base.yaml` 均没有第 1 项残留。
2. 两条有效规则完成一次批量写入和热重载后，在
   `after_rule_reload` 检查点注入异常；执行器恢复原规则存储并再次热重载，两个文件
   均无测试 matcher，结果报告“所有修改已回滚”。
3. 混合计划先加入规则，再将 `千速云` 从“自动选择”切至健康的“香港 04”，随后在
   `after_proxy_switch` 注入异常；最终控制器 `now` 从测试前“自动选择”恢复为
   “自动选择”，规则文件和运行配置无残留。
4. 无故障双规则计划一次提交成功，存储和 `base.yaml` 同时包含两条规则，调试结果
   返回 2 项成功；随后通过应用接口删除并确认两个位置均清空。
5. 最终主页显示 VPN `Running`、Mihomo 与互联网可用、0 条 AI 规则；
   活动规则文件为 `payload: []`、`disabled-payload: []`。

结论：任一子操作在预验证或提交阶段失败，都不会留下部分规则或错误 Selector 选择；
可恢复提交故障会恢复事务前状态并明确反馈回滚结果。

### 第 9 项：确定性本地解析

状态：已通过。

实现摘要：

- 新增保守的 `LocalPlanResolver`，在读取真实 Mihomo 路由快照后优先处理高置信命令；
  只有返回 `null` 的歧义或复杂语义才调用 LLM。
- 支持一个或多个显式域名直连/不走代理，以及拦截/屏蔽/去广告；本地生成与 LLM
  完全相同的 schema 1 `AiPlan` 和 `AiIntent`。
- 支持“节点太卡了换一个”“切到低延迟”等命令，优先使用运行配置最终策略对应的
  真实 Selector，并继续由现有实时测速执行器选择候选。
- 支持单个知名服务或域名按明确地区分流；只从控制器中选择 `alive=true` 的真实
  叶子节点，并按延迟排序，不在本地猜测不可用节点。
- 多服务同地区、多个地区、冲突的直连/拦截语义及不健康地区会保守回退到 LLM。
- 本地解析发生在 API Key 校验之前，因此常见命令可在未配置 Key 或 LLM 网络离线时
  执行；结果中标记 `source=local`，便于验证与诊断。
- 修复域名紧跟中文命令时的边界识别：域名边界只限制 ASCII 域名字符，不再将中文
  “直连”误判为域名的一部分。

自动化验证：

```text
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintDebug --console=plain
```

结果：Debug 单元测试、Debug/Release 构建和 Android Lint 全部通过。新增测试覆盖
多域名直连、拦截、无空格中文域名命令、首选 Selector、健康地区最低延迟节点、
多服务歧义回退和不健康地区不猜测。

Android 16 模拟器端到端验证：

1. 输入 `local-test.example直连`，调试结果明确返回
   `schema=1 source=local operations=1`；规则同时进入活动规则存储和 `base.yaml`，
   热重载成功。测试后通过应用接口删除。
2. 输入“Netflix 走香港”，本地解析器从实时控制器选择健康且低延迟的“香港 04”，
   生成 `GEOSITE,netflix,🇭🇰香港 04` 并生效；随后删除且无残留。
3. 输入“节点太卡了换一个”，本地计划以 `千速云` 为 Selector，实时测速后从
   “自动选择”切至“香港 07 [0.5x]”；验证后通过控制器恢复为“自动选择”。
4. 最终规则存储为空，主页保持 VPN `Running`、Mihomo 与互联网可用。

结论：常见明确命令无需 LLM 即可产生和执行同格式计划；歧义输入不会被本地规则
过度解释，继续交给 LLM 处理。

### 第 10 项：完整网络诊断执行器

状态：已通过。

实现摘要：

- 新增分层诊断执行器，按依赖顺序检查非 VPN 底层网络、Android VPN/TUN、Mihomo
  控制器、Mihomo DNS、运行时规则匹配、真实叶子节点、机场出口和目标站点。
- 健康探测显式通过 `127.0.0.1:7890` mixed-port，确保检查当前节点和规则，而不是
  Veer 自身被排除在 TUN 外后的宿主直连。
- Mihomo 仓库新增 `/dns/query` 与 `/rules` 强类型读取；规则匹配遵守控制器 index
  顺序，支持 Domain、DomainSuffix、DomainKeyword、GeoSite 和最终 Match。
- 分类器按最早故障层输出 `SYSTEM_NETWORK`、`VPN_TUN`、`CONTROLLER`、`DNS`、
  `RULE`、`PROXY_EXIT`、`TARGET_SITE` 或 `HEALTHY`，避免下游失败覆盖根因。
- 前置层失败时，下游检查标记为 `SKIPPED`，不再产生一串误导性失败。
- `diagnose` AI 操作现在执行真实诊断；“诊断/排查/打不开/网络不通”等明确指令
  本地解析，无需 LLM。主页面日志逐项展示八层状态和细节，最终回复使用诊断结论。
- Debug 构建支持仅显式 ADB 可用的机场出口和目标站点探测故障注入。

自动化验证：

```text
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintDebug --console=plain
```

结果：Debug 单元测试、Debug/Release 构建和 Android Lint 全部通过。新增测试覆盖
八类分类优先级、DomainSuffix 控制器顺序匹配、GeoSite 服务映射和本地诊断意图。

Android 16 模拟器端到端验证：

1. “诊断 www.gstatic.com”以 `source=local` 执行，底层网络、TUN、控制器、DNS、
   DomainSuffix 规则、香港叶子节点、机场出口和目标站点全部通过，返回
   `DIAGNOSE,HEALTHY`。
2. 热加入 `DOMAIN,www.gstatic.com,REJECT` 后，诊断准确匹配控制器第 0 条规则并
   返回 `DIAGNOSE,RULE`；节点、出口和目标探测跳过。删除规则后无残留。
3. 诊断 `nonexistent-veer-test.invalid` 时，Mihomo `/dns/query` 返回失败状态，
   分类为 `DIAGNOSE,DNS`，机场出口仍独立验证可用。
4. 注入机场出口探测失败时，节点控制信息仍可读取，分类为
   `DIAGNOSE,PROXY_EXIT`；目标站点检查因出口失败而跳过。
5. 注入仅目标站点失败时，DNS 和机场出口均通过，分类为
   `DIAGNOSE,TARGET_SITE`。
6. 同时关闭模拟器 Wi-Fi 与移动数据后，物理网络检查失败并优先分类为
   `DIAGNOSE,SYSTEM_NETWORK`；恢复网络后 VPN 可重新启动。
7. 安装最终 Debug 包后曾在启动首轮准确报告香港节点/出口暂时超时，15 秒后主页
   自动刷新为互联网可用；最终 VPN `Running`、控制器可用、HK 出口、0 条 AI 规则，
   `千速云` 保持“自动选择”。

结论：诊断器能以实际运行证据区分系统网络、TUN/内核、DNS、规则、机场出口和目标
站点故障，并通过 AI 入口返回可操作的中文结论。

### 第 11 项：自动恢复策略

状态：已通过。

实现摘要：

- 新增独立的 `AutoRecoveryManager`，只处理“控制器可用但代理出口连续失败”这一
  明确故障边界；底层网络、TUN 和控制器生命周期继续分别由连接监视器与 watchdog
  管理，恢复器不直接调用 JNI、创建 TUN 或启停 Veercore。
- 出口探测连续失败 2 次才进入恢复，避免单次抖动触发节点切换；正常观测会清零
  连续失败计数，并记住最后一个健康叶子节点。
- 恢复时读取运行配置的最终默认策略及 Mihomo 实时路由快照，对健康候选执行有界
  并发延迟探测，优先最后健康节点和低延迟节点，逐个切换并验证真实代理出口。
- 候选全部失败时恢复事务前 Selector 选择，记录降级状态并保留健康的 Mihomo/TUN；
  连续失败计数清零后重新观察，避免把机场瞬时抖动误判成核心崩溃并自动关停 VPN。
- 若探测域名被当前运行规则明确 `REJECT`，自动恢复会被抑制，避免把用户规则当成
  节点故障；控制器不可达时也让位给现有 watchdog。
- Debug 构建增加可控的“恢复成功、候选耗尽、出口健康”探测模式，仅供 ADB 端到端
  验证；Release 使用真实 mixed-port 网络探测。

自动化验证：

```text
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintDebug
```

结果：Debug 单元测试、Debug/Release 构建和 Android Lint 全部通过。新增测试覆盖
连续失败阈值、健康重置和非法阈值拒绝；现有诊断、watchdog、配置与 AI 测试全部回归
通过。

Android 16 模拟器故障注入：

1. 注入前两次出口失败、第三次恢复：日志先出现 `proxy exit failed 1/2`，随后
   `千速云` 从“自动选择”切换到探测健康的香港叶子节点，控制器 `/proxies` 与日志
   选择一致，VPN 保持 `Running`。
2. 注入所有出口与候选均失败：恢复器在第 2 次失败后尝试 1 个受限候选，确认失败后
   恢复原 Selector，记录 `selectionRestored=true`；引擎继续保持 `Running`，
   不再因数据面瞬时失败释放前台服务和 TUN。
3. 加入 `DOMAIN,www.gstatic.com,REJECT` 并保持失败注入：恢复器持续报告
   `probe target blocked by rule #0`，不切换节点、不停止 VPN，服务保持
   `Running`；测试后规则已热删除。
4. 清除全部故障注入后重新启动，恢复 `千速云=自动选择`。真实 mixed-port
   `https://www.gstatic.com/generate_204` 返回 HTTP 204；主页显示 VPN Running、
   控制器可用、互联网实际可用、HK 出口和 0 条 AI 规则。

结论：代理出口故障能在防抖后自动选择健康替代；无可用候选时恢复用户原选择并安全
释放 TUN；用户规则、系统网络或控制器故障不会被错误归入节点恢复路径。

### 第 12 项：定时刷新订阅

状态：已通过。

实现摘要：

- 引入 WorkManager `2.11.2`，在应用初始化时注册唯一的 24 小时周期任务，设置
  2 小时 flex 窗口、联网约束和 30 分钟指数退避；重复启动应用只更新同名任务，
  不会叠加多个调度。
- `SubscriptionRefreshWorker` 串行刷新所有 HTTPS 订阅；同一进程内另有互斥锁防止
  手动/调试任务重复提交。整批只有失败时最多退避重试 3 次，之后保留失败历史并等待
  下一个周期。
- 后台刷新完整执行下载、解析、规范化和配置生成，只有全部验证成功后才原子替换
  profile 文件；解析或验证失败不进入持久化路径。
- 活动 VPN 运行时只暂存已验证的新 profile，不修改当前 `ConfigManager`、Mihomo
  或 TUN；下一次 VPN 启动在 `ConfigManager.prepare()` 之前读取最新持久化配置，
  使更新在安全重连边界生效。
- 新增最多 50 条原子 JSON 刷新历史，记录更新时间、结果、worker 重试次数和节点、
  策略组、规则的增减摘要；不保存订阅 URL。错误摘要会删除 URL 和常见凭据参数。
- Profiles 页面展示最近 5 条刷新历史及差异；Debug 构建提供显式立即调度与
  “无效刷新不覆盖”验证入口。

自动化验证：

```text
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintDebug
```

结果：Debug 单元测试、Debug/Release 构建和 Android Lint 全部通过。新增测试覆盖
配置差异的增减/不变计算，以及历史错误对 URL、token 和 key 的脱敏。

Android 16 模拟器端到端验证：

1. VPN 已为 `Running` 时触发真实订阅立即刷新；刷新前后应用 PID 均为 `19716`，
   同一个 `VeerVpnService` 始终为前台服务，日志没有 `Stopping`、`tearDownCore`
   或 TUN 重建。
2. Worker 返回 `updated=1 unchanged=0 failed=0`；历史记录结果为 `UPDATED`，
   节点/组/规则数量差异均为 0，配置哈希从旧值变为新值，Profiles 页面显示同一条
   更新时间和差异摘要。
3. 安装并启动最终 Debug 包后，启动日志中的 base config 哈希前缀
   `5327ca84384d` 与后台刷新后的 profile 哈希一致，证明暂存版本在下一次安全启动
   被采用。
4. 在 VPN `Running` 时向同一 profile 注入未闭合 YAML；解析返回失败，验证文件记录
   `failed=true unchanged=true`，失败前后已生成配置逐字节相同，VPN 前台服务仍在。
5. WorkManager JobScheduler 状态中存在 24 小时周期窗口；刷新历史 JSON 不含订阅 URL。
6. 最终主页显示 VPN `Running`、Mihomo 可用、互联网实际可用、HK IPv4/IPv6 出口、
   0 条 AI 规则；通过 mixed-port 请求 gstatic 返回 HTTP 204。

结论：订阅可由系统可靠定时刷新并退避重试；后台更新不打断当前代理，验证失败不覆盖
可用配置，成功版本在下一次安全启动生效，且用户能查看持久化刷新结果与差异。

### 第 13 项：订阅信息与敏感数据安全

状态：已通过。

实现摘要：

- 解析标准 `Subscription-Userinfo` 响应头中的 upload、download、total 和 expire，
  将其作为可选、可向后兼容的 `SubscriptionUsage` 写入 profile metadata。
- Profiles 页面显示已用/总量/剩余流量；供应商提供 expire 时显示到期时间并对已
  到期状态使用错误色，不提供时不猜测日期。刷新暂时缺失响应头时保留上次有效值。
- API Key 不再写入 BuildConfig/APK。运行时 Key 使用 Android Keystore 中不可导出的
  AES-256 GCM 密钥加密，SharedPreferences 只保存 IV 与密文。
- 升级时自动读取旧明文 Key、加密写入新字段并立即删除旧字段；清除操作同时删除新旧
  字段，避免迁移残留。
- `VeerLog` 在写入 ring buffer、Logcat、磁盘和 UI Flow 前统一脱敏 Bearer、`sk-`
  Key、token/key/api_key/secret/password 以及完整 URL；导出文件因此只包含已脱敏内容。
- 刷新历史继续只存 profile ID、显示名、差异和脱敏错误，不持久化订阅 URL；Profile
  UI 只显示订阅主机，不显示私密路径或查询参数。

自动化验证：

```text
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintDebug
```

结果：单元测试、Debug/Release 构建和 Android Lint 全部通过。新增测试覆盖标准流量
头、异常/负数字段、无关响应头、日志中 API Key/Bearer/凭据/URL 的脱敏，以及普通
诊断文本保持不变。

Android 16 模拟器端到端验证：

1. 升级前 SharedPreferences 只有旧 `deepseek_api_key`；启动新包后 UI 仍显示 Key
   已保存，存储键变为 `deepseek_api_key_encrypted`，旧字段被删除，偏好文件中无
   `sk-` 明文。
2. 当前真实订阅响应包含 `Subscription-Userinfo`。刷新后 profile metadata 记录
   已用 `245315285409` 字节、总量 `386547056640` 字节、剩余
   `141231771231` 字节；供应商未返回 expire，因此到期字段保持 null。
3. Profiles 页面显示 `Traffic: 228.5 GB / 360.0 GB · 131.5 GB remaining`，只展示
   订阅主机，不展示完整订阅地址。
4. 向统一日志入口注入假 API Key、Bearer 和私密 URL 后导出调试包，验证文件返回
   `redacted=true`；密钥、Bearer 值和 URL 均未出现。
5. 对工作区执行实际 Key 和订阅私密路径扫描，结果为 clean；`git diff --check`
   无格式错误。
6. 最终 VPN `Running`、Mihomo 可用、互联网实际可用、HK 出口、0 条 AI 规则；
   mixed-port 真实请求返回 HTTP 204。

结论：订阅流量信息可以安全持久化和展示；API Key 已从 APK/明文偏好迁移到 Android
Keystore；所有日志与导出目标共享同一脱敏边界，仓库和设备明文存储均未发现真实凭据。

### 第 14 项：自动化测试矩阵

状态：已通过。

实现摘要：

- 完成 `LifecycleFaultTest` 的 10 条 Android 仪器测试，覆盖并发启停、启动 JNI
  卡死、启动失败、JNI panic、停止 JNI 卡死、连续重启 goroutine 稳定性、错误态
  可见性、状态轨迹和 teardown 期间延迟网络回调。
- 修正 gomobile 数值反射兼容性：Go 的 `int32/int64` 统一按 `Number` 读取，避免
  Debug AAR 能力被错误判定为不可用。
- 为 Debug Veercore 补齐 `before_shutdown` 卡死注入与释放接口；Release 构建保留
  同名空实现，不引入运行期开销。
- 修复启动 JNI 超过外层停止超时后的真实生命周期漏洞：外层先强制关闭 TUN 并到达
  `Stopped`，JNI 最终返回后由原启动协程在 `NonCancellable` 区域串行执行第二次
  Veercore 清理，防止活跃 Go executor 泄漏到下一次连接。
- 修复停止 JNI 超时的终态覆盖：一旦 5 秒 JNI latch 超时，保持不可恢复 `Error`，
  不再被显式关闭路径错误覆盖成 `Stopped`，从而禁止同进程危险重连。
- 快速失败用例在发送启动 Intent 前订阅 Error，完整的瞬时 Starting/Error 顺序由
  `PhaseTrace` 断言，消除 StateFlow 合并造成的观察竞态而不放宽行为要求。
- 显式关闭完成后立即发布真实 `Stopped`，短暂保留已完全排空的 Service 供连续重启
  复用；超过窗口再交由 Android 销毁。

自动化验证：

```text
cd go_core && go test ./...
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintDebug
adb shell am instrument -w -r \
  -e class com.yamax.veer.testing.LifecycleFaultTest \
  com.yamax.veer.test/androidx.test.runner.AndroidJUnitRunner
```

结果：

- Go 包检查通过。
- Debug 单元测试、Debug/Release APK 构建和 Android Lint 全部通过。
- Android 16 arm64 模拟器仪器测试 `OK (10 tests)`，0 失败、0 跳过。
- 连续 5 次真实 Veercore Start/Stop 后 goroutine 数在 10 秒排空窗口内回到基线
  `+2` 容差内，没有累积泄漏。
- 启动卡死用例先在 2 秒外层超时后关闭 TUN，再释放注入点；测试观察到第二个
  `Stopped` 和恰好一次 `Veercore.stop()`，证明 JNI 返回后的 runtime 已真正排空。
- 停止卡死用例命中 5 秒 JNI latch，状态为 `Stopping → Error`，未出现
  `Stopping → Stopped`；释放注入点后孤立线程退出。

Android 16 模拟器最终运行验证：

1. 测试完成后强制停止测试进程并重新启动应用，活动订阅与 profile hash 保持不变。
2. API Key 已重新写入 Keystore 加密存储；偏好文件仅有
   `deepseek_api_key_encrypted`，未发现 `sk-` 明文。
3. VPN 恢复为 `Running`，Mihomo 控制器可用，主页报告互联网实际可用、香港出口、
   0 条 AI 规则。
4. 主机通过 ADB 转发访问控制器 `/version` 成功；经模拟器 Mihomo mixed-port
   请求 `https://www.gstatic.com/generate_204` 返回 HTTP 204。

结论：发布前自动化矩阵已覆盖当前最危险的 VPN/JNI 生命周期边界，所有注册用例实际
执行且通过；模拟器最终恢复到可联网的正常运行态。

### 扩展 AI 规则回归（2026-07-28）

状态：已通过。

覆盖场景：

- 单域名直连、单域名拦截、域名指定日本节点。
- “节点太卡了换一个”按实时测速切换默认 Selector。
- Netflix 日本 + YouTube 美国、OpenAI + GitHub 美国两组 LLM 多操作计划。
- DisneyPlus、Telegram 等服务名到 Mihomo geosite 的规范化与实际流量匹配。
- 两域名批量直连、重复规则去重、同 matcher 在 REJECT/DIRECT 间安全改写。
- 用户要求当前订阅不存在的英国节点时，明确拒绝且不静默替换为美国等其它地区。

测试中发现并修复：

- LLM 曾把 DisneyPlus 英区静默替换成美国节点，并生成当前 geodata 不支持的
  `GEOSITE,disneyplus`。现在执行 LLM 前先检查用户明确要求的所有地区是否有可用
  节点；缺失时返回“计划未执行”，规则存储与实时规则表均不变。
- Disney+、DisneyPlus、迪士尼统一规范化为 Mihomo 支持的 `GEOSITE,disney`；
  ChatGPT 统一为 `GEOSITE,openai`。其它格式安全的 geosite 标签仍可使用，不因
  固定白名单阻断 Telegram 等服务。
- System instruction 明确禁止把用户指定地区替换成其它可用地区。

端到端结果：

1. `example.com` 实际命中 DIRECT 并返回 200；`ads.example.net` 实际命中 REJECT。
2. `wikipedia.org` 实际命中日本节点并返回 200。
3. Netflix 命中日本节点返回 302；YouTube 命中美国节点返回 204。
4. DisneyPlus 规则为 `GEOSITE,disney`，实际命中日本节点并返回 200。
5. OpenAI 与 GitHub 均命中美国节点；GitHub 返回 200。
6. Telegram 由 LLM 生成 `GEOSITE,telegram`，实际命中美国节点并返回 200。
7. 英国节点缺失场景在预执行阶段失败，控制器规则的规范化快照哈希保持不变。
8. 测试结束后删除全部 11 条测试规则并逐条确认 `runtimeReload=true`，恢复
   `千速云=🇭🇰香港 04`；主页显示 0 条 AI 规则，VPN/控制器/互联网均正常，
   gstatic 真实代理请求返回 HTTP 204。

质量门禁：

```text
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintDebug
```

结果：全部通过。

### Release 发布加固（2026-07-28）

状态：已通过。

实现摘要：

- 禁用 Android 系统备份，避免订阅元数据、运行配置和应用状态被系统备份或迁移到
  其它设备；Release 合并清单确认 `android:allowBackup="false"`。
- Release 启用 R8 代码压缩、资源收缩和映射文件生成。
- 保留 gomobile 生成的 `veercore` JNI 接口，防止反射入口或 native 方法名被裁剪；
  保留 SnakeYAML 的反射表面，防止订阅解析在优化包中失效。
- 同时生成优化后的 APK 和 Android App Bundle，供本地验收与后续商店按 ABI
  分发。

测试中发现并修复：

- 首次优化版 Release 能启动，但真实订阅在 `SafeConstructor` 阶段返回
  `Malformed YAML: unknown parse error`。Debug 单元测试无法复现，确认是 R8 对
  SnakeYAML 反射路径的 Release 专属破坏；加入 keep 规则后，同一订阅成功导入
  33 个节点、3 个策略组和 514 条规则。

端到端结果：

1. 本地调试证书签名后的优化 Release APK 在 Android 16 arm64 模拟器安装并启动。
2. 真实订阅下载、解析、持久化和激活成功。
3. Veercore 配置校验和 JNI 调用未被 R8 破坏；VPN 到达 `Running`，Mihomo 控制器
   可用，应用内互联网检查成功。
4. 控制器 `/version` 返回 Mihomo `1.10.0`；经 mixed-port 请求 gstatic 返回
   HTTP 204。
5. 通用 Release APK 约 249 MiB，AAB 约 118 MiB；AAB 可让商店避免向单台设备
   下发全部 ABI。

结论：当前 Release 收缩配置已通过真实订阅和代理运行验证，不再只依赖 Debug
构建结果。

### 下一项：按 CPU 架构分别发布 APK（同时提供 Universal）

状态：构建、签名门禁与 arm64 动态验收已通过；x86_64/armv7 动态验收待设备。

目标：

- 为侧载和 GitHub Release 分别提供 `arm64-v8a`、`armeabi-v7a`、`x86_64`
  三种单架构 APK。
- 继续提供包含全部架构的 Universal APK，方便无法判断设备架构的用户直接安装。
- 商店发布继续使用 AAB，由应用商店按设备架构生成并分发优化后的 APK。

计划产物：

```text
Veer-v{version}-arm64-v8a.apk
Veer-v{version}-armeabi-v7a.apk
Veer-v{version}-x86_64.apk
Veer-v{version}-universal.apk
Veer-v{version}.aab
Veer-v{version}-SHA256SUMS.txt
```

实施步骤与逐项验证：

1. 在 Gradle Release 配置中启用 ABI splits，显式包含 `arm64-v8a`、
   `armeabi-v7a`、`x86_64`，并开启 Universal APK。
   - 验证：一次 Release 构建同时生成 4 个 APK 和 1 个 AAB。
   - 验证：所有产物使用相同的 `applicationId`、`versionName`、签名证书和代码。
2. 统一输出文件命名，将版本号和 ABI 写入文件名；生成 SHA-256 校验清单。
   - 验证：校验清单覆盖所有 APK 和 AAB，逐个执行校验均通过。
3. 检查每个 APK 的 native library 内容。
   - `arm64-v8a` APK 只能包含 `lib/arm64-v8a/`。
   - `armeabi-v7a` APK 只能包含 `lib/armeabi-v7a/`。
   - `x86_64` APK 只能包含 `lib/x86_64/`。
   - Universal APK 必须同时包含以上三种 ABI，且不得包含项目未支持的 `x86`。
4. 对每种可用测试环境执行安装和启动验证。
   - arm64 模拟器/真机验证 `arm64-v8a` 和 Universal APK。
   - x86_64 模拟器验证 `x86_64` 和 Universal APK。
   - 32 位 ARM 设备或对应测试环境验证 `armeabi-v7a` APK。
   - 每次验证均需完成订阅导入、profile 激活、VPN `Running`、控制器
     `/version` 可用以及真实代理 HTTP 204。
5. 在发布流程中同时上传 4 个 APK、AAB 和校验清单。
   - Release 说明明确推荐现代 Android 手机下载 `arm64-v8a`。
   - `x86_64` 标注为模拟器/少数 x86 设备版本。
   - Universal 标注为兼容性版本，并明确文件体积最大。
6. 将 ABI 构建纳入持续集成门禁。
   - 验证各产物可解析、签名有效、ABI 内容正确。
   - 保留 R8 mapping 文件，并确保单架构与 Universal 使用同一次源码构建。

验收标准：

- 4 个 APK、AAB 和 SHA-256 清单可由单个 Gradle/发布命令稳定生成。
- 单架构 APK 不携带其它架构的 Veercore，显著小于 Universal APK。
- 所有架构版本功能一致；Universal 不作为单架构验证失败时的替代品。
- 至少 arm64 与 x86_64 完成自动化运行验证；armeabi-v7a 在正式发布前完成真实
  32 位运行环境验收。

2026-07-29 执行结果：

- `-Pveer.abiSplits=true` 只在发布流程开启，日常 Debug 仍输出
  `app-debug.apk`；一次 split 构建生成 arm64-v8a、armeabi-v7a、x86_64 和
  Universal 四个 APK。
- `tools/release/package_release.sh` 用两个隔离的 Gradle invocation 依次生成
  split APK 与 AAB，规避 AGP 9.2.1 在资源收缩开启时不能同时构建多 APK/AAB
  的限制。
- 输出按版本与 ABI 确定性命名，并生成、立即回验
  `Veer-v1.0-SHA256SUMS.txt`。单 ABI native 目录与目标完全一致，Universal
  仅包含三种受支持 ABI。
- 未配置密钥时全部文件带 `-unsigned`；签名字段不完整时配置阶段失败；
  `VEER_REQUIRE_SIGNED=1` 会拒绝未签名集合。一次性仓库外测试证书验证了四个
  APK 同证书、AAB 签名和严格签名门禁。
- arm64-v8a APK 与 Universal APK 均在 Android 16 arm64 模拟器安装运行，
  进入 `Running`，控制器返回 Mihomo 1.10.0，Cloudflare/gstatic 均返回
  HTTP 204。
- 当前本机只有 arm64 AVD；x86_64 和 armeabi-v7a 已完成静态 ABI/清单校验，
  动态运行验收不得用 Universal 替代，保留为发布前硬门禁。

### UI 操作逻辑 P0（2026-07-28）

状态：已通过。

- 先完成独立设计文档 `docs/UI_OPERATION_LOGIC_PLAN.md`，再按文档实施。
- 首页互斥的启动/停止按钮已合并为唯一上下文主按钮；无配置时直接引导导入。
- 首个有效配置导入后自动激活，已有活动配置时仍保持显式切换。
- API Key 设置与运行日志默认折叠；AI 前置条件和最近结果在输入区附近反馈。
- 通知权限和 VPN 启动改为顺序操作，避免同时弹出多个系统窗口。
- 新增主按钮与 AI 就绪度单元测试；Debug/Release/AAB/Lint 门禁全部通过。
- Android 16 arm64 模拟器从干净数据完成真实订阅导入、自动激活、Key 加密保存、
  VPN 启动、Mihomo 1.10.0 控制器和 HTTP 204 验证。

后续 P1 包括互斥的导入方式选择、统一应用内导航、AI 操作历史/撤销和完整可访问性
验证，具体范围以 `docs/UI_OPERATION_LOGIC_PLAN.md` 为准。

### 节点一键测速（2026-07-28）

状态：已通过。

- 节点页新增全局“一键测速”，跨策略组去重后并发检测所有真实叶子节点。
- 并发限制为 4，单节点超时 3 秒；实时展示进度、成功数和失败数。
- 每个结果同步回填到所有引用该节点的策略组，批量操作不会切换当前节点。
- 测速中禁止刷新、节点切换、自动选择和重复测速；VPN 停止时取消任务。
- 真实订阅识别 31 个唯一节点，最终测得 10 个可用、21 个超时或失败。
- 新增批量测速纯逻辑测试，完整 Debug/Release/AAB/Lint 门禁通过。

## 性能专项（2026-07-29）

核心性能基线、竞品差距和分阶段执行顺序见
[CORE_PERFORMANCE_OPTIMIZATION.md](CORE_PERFORMANCE_OPTIMIZATION.md)。

- 已加入 debug-only ADB 性能 runner，输出启动 CSV 与完整 JSON。
- 已完成 5 轮启动、后台 CPU/内存和控制器体积基线。
- Dashboard 刷新改为生命周期感知，后台 CPU 样本下降约 81%。
- 首份结果见
  [PERFORMANCE_BASELINE_2026-07-29.md](PERFORMANCE_BASELINE_2026-07-29.md)。

### Veercore 进程隔离与事件驱动 Dashboard（2026-07-29）

状态：已通过。

- `VeerVpnService`、TUN、socket protection 与 gomobile 核心迁入
  `:veercore`；UI 只持有状态镜像。
- 状态、启动阶段、连通性、流量、路由、日志和规则热重载通过有上限的
  same-UID IPC 传输，不传订阅、凭据或完整代理树。
- UI 进程死亡不影响 VPN；核心异常退出在保留用户连接意图时自动重启，
  显式停止不会误恢复。
- Dashboard 使用 1 秒流量-only IPC、路由/规则事件刷新与 30 秒公网兜底；
  后台暂停全部 UI 刷新。
- Android 16 arm64 验收覆盖 UI/core 进程死亡、主动停止、快速重连、
  真实 HTTP 204、日志 IPC、远程故障注入与 AI 规则跨进程热重载。
- 最终源码在跨进程通知合并修复后完成 18/18 仪器测试；停止闸门会忽略清理期间
  到达的网络丢失回调，启动进度测试会等待独立 IPC 状态流最终同步到 `IDLE`。
- 最终 `testDebugUnitTest`、Debug、AndroidTest、Release APK、Release AAB 与
  `lintDebug` 门禁全部通过；模拟器恢复 `Running`，控制器返回 Mihomo 1.10.0，
  Cloudflare 与 gstatic 经 mixed-port 均返回 HTTP 204。
- 优化后的 30 秒前台 CPU 为 UI 0.499%、Veercore 0.665%、合计 1.164%；
  完整结果见性能基线文档。

Release 签名接入与分架构发布机制已完成；正式分发仍需在受保护环境提供生产
密钥。下一轮硬件验收为 x86_64/armv7 运行环境、physical Pixel 与
MIUI/HyperOS 的进程恢复、待机和功耗矩阵。

### SI-09：IPv6 局域网绕过（2026-07-29）

状态：已通过。

- 把 Android 路由决策抽为可在 JVM 测试的 `VpnRoutePolicy`，统一生成 IPv4 与
  IPv6 include/exclude 计划。
- API 33+ 在双栈默认路由之上排除 RFC1918、`fc00::/7` 与 `fe80::/10`；
  API 29–32 使用精确补集，IPv6 为 9 个互不重叠 CIDR，不再同时添加 `::/0`。
- 单元测试验证关闭绕过、API 33 exclude 计划、API 29–32 补集覆盖量、边界地址
  和无重叠性质；IPv6 组播仍按现有策略走 TUN。
- Android 16 实机态 LinkProperties 显示 `fc00::/7 throw`、
  `fe80::/10 throw` 与更具体的 TUN `/126` connected route；VPN 正常进入
  `Running`。
- Mihomo 1.10.0 控制器返回 HTTP 200，Cloudflare 与 gstatic 经 mixed-port
  均返回 HTTP 204，证明路由修复未破坏公网数据面。

### SI-10：IPv4 链路本地与组播绕过（2026-07-29）

状态：已通过。

- 在同一 `VpnRoutePolicy` 中加入 `169.254.0.0/16` 与 `224.0.0.0/4`，
  让本地链路访问以及 mDNS/SSDP 等组播发现留在物理局域网。
- API 33+ 的 exclude 计划由 5 段扩为 7 段；API 29–32 IPv4 精确补集由
  31 段更新为 40 段，且不会额外加入 `0.0.0.0/0`。
- 单元测试验证五个 IPv4 排除块、公共/CGNAT 边界、覆盖量与无重叠性质。
- Android 16 LinkProperties 实际显示 `169.254.0.0/16 throw` 与
  `224.0.0.0/4 throw`，连同 RFC1918 和 SI-09 的两条 IPv6 throw route。
- VPN 正常进入 `Running`，Mihomo 控制器为 200，Cloudflare/gstatic 均为
  HTTP 204。

### P0：应用分流（Per-App Proxy，2026-07-29）

状态：已通过。

- 根据 `PROJECT_ANALYSIS.md` 的首个高优先级缺口，实现全应用、仅代理所选应用、
  绕过所选应用三种互斥模式。
- 策略使用版本化 JSON 原子保存；`:veercore` 在建立 TUN 前读取快照，不依赖
  不可靠的多进程 `SharedPreferences` 缓存。
- 应用页提供图标、名称、包名、系统应用标记、搜索、当前结果全选和清空。
- 运行中保存自动触发服务内快速重连；未连接时明确提示下次连接生效。
- `ONLY_SELECTED` 的有效列表为空时核心安全回退到全应用模式；已卸载应用保留并
  标记不可用，避免静默改变用户选择。
- Android 16 系统 `dumpsys connectivity` 验证：
  - 仅代理 Chrome 时 VPN 只包含 Chrome UID 10162/20162。
  - 绕过 Chrome 时 VPN UID 补集排除 Chrome 与 Veer UID 10242/20242。
  - 恢复全应用后只排除 Veer；VPN、控制器和实际互联网均健康。
- 两次运行中保存都复用同一 Veercore PID，旧核心 teardown 为 10–19 ms。
- 新增 6 个策略/存储单元用例；完整单元测试、Lint、Release APK/AAB 与
  Android 16 仪器测试 18/18 通过。

详细设计和验收记录见 [PER_APP_PROXY.md](PER_APP_PROXY.md)。

下一项：按报告进入真机 ROM 兼容性验收。该项需要 Pixel 与 HyperOS/MIUI
实体设备；设备接入前可先完善兼容性检查清单与厂商后台限制引导，且不把模拟器
结果冒充 ROM 真机结论。

### 真机 ROM 兼容性首轮验收（2026-07-30）

状态：HyperOS 核心链路已通过；跨 ROM 与解锁 UI 继续开放。

- 在 Xiaomi Mi 10S、HyperOS 1.0、Android 13/API 33、arm64-v8a 上完成覆盖安装、
  VPN/TUN、Controller、真实公网、进程隔离、Doze/后台、Wi-Fi 恢复与三种
  Per-App 模式。
- 完整 `LifecycleFaultTest` 为 14/14，通过时间 53.639 秒；快速
  “停止→立即启动”专项约 4.7 秒。
- 真机发现并修复旧 STOP 销毁新 START、health-check 让 Stop 继承不可达探测
  超时、URLTest 临时 HTTP 池以及 DoH `persistConn` 跨代际累积。
- 最终通过 Go 测试、JVM 单元测试、Lint、Debug 和 R8 Release 构建。
- 锁屏设备无法可靠完成首次授权、OEM 设置引导和中文输入交互；当前蜂窝链路也
  不具备可重复验证条件，因此均明确保留为未覆盖项。

详细矩阵见
[ROM_COMPATIBILITY_TEST_2026-07-30.md](ROM_COMPATIBILITY_TEST_2026-07-30.md)。

后续顺序：

1. 后台限制检测与普通用户引导已实现，并通过锁屏真机状态/Intent 验证；解锁后
   补可见 UI 与人工开关流程验收。
2. 补 Pixel AOSP 基准和 Wi-Fi/蜂窝往返。
3. 补 ColorOS/OriginOS，再进入 8 小时锁屏与功耗 soak。
4. 实时日志查看器已完成并通过模拟器/锁屏真机核心链路验证。

### HyperOS 后台运行保护引导（2026-07-30）

状态：实现、自动化与锁屏真机验证已通过；解锁 UI 验收待补。

- 公开状态覆盖电池优化豁免、Android 后台限制、standby bucket 与系统省电模式。
- Xiaomi/Redmi/POCO 统一识别为需要额外核对的 MIUI/HyperOS 家族。
- 首页风险卡片不会声称能读取厂商私有开关；明确提示用户检查“自启动”和
  “无限制后台运行”。
- 设置导航优先进入 HyperOS 自启动/省电页，不存在时回退 Android 电池优化列表
  和应用详情；不申请静默白名单权限。
- 真机识别为 `XIAOMI / ATTENTION`，标准电池优化已豁免，Android 未报告后台受限；
  三个设置入口均成功解析。
- 新增纯策略单元测试和 Compose UI 仪器测试。锁屏/Dozing 真机在 Compose rule
  建立前按前置条件明确跳过，避免等待焦点；解锁设备上再执行可见交互断言。

设计与验收记录见
[OEM_BACKGROUND_GUIDANCE.md](OEM_BACKGROUND_GUIDANCE.md)。

### P0：实时日志查看器（2026-07-30）

状态：已通过。

- 新增独立日志页面，统一展示 UI 与 Veercore 的有界内存日志。
- 支持来源、级别和关键字组合筛选，以及实时/暂停、手动刷新和最新优先。
- 复制和 SAF 导出只处理当前筛选结果，并在输出前执行第二次集中脱敏。
- 页面仅在前台且未暂停时每秒刷新，不建立新的跨进程长连接。
- Android 16 arm64 完整仪器套件 18/18 通过；HyperOS 真机生命周期矩阵
  14/14 通过，并验证 Running、Controller HTTP 200、代理公网 HTTP 204。
- 真机导出快照包含 224 条脱敏日志（UI 24、Core 200）；设备锁屏导致可见
  Compose 交互明确跳过，解锁人工验收继续留在 ROM 清单。
- 同轮修复了 Android 16 新 Start 复用已排空 Service 的代际竞态、gRPC 客户端
  Close 后重建传输，以及 DoH 关闭时的晚到连接注册。
- 完整 Go、单元测试、Lint、Debug、AndroidTest 和 R8 Release 门禁通过。

详细设计和验收记录见
[REALTIME_LOG_VIEWER.md](REALTIME_LOG_VIEWER.md)。

下一项：实现自定义 DNS 设置界面。配置必须按 profile 隔离，保存前完成协议和
地址验证，运行中变更必须走现有安全重连/LKG 回滚链路；跨 ROM 与蜂窝门禁继续
并行等待可用硬件。

### P1：自定义 DNS 设置界面（2026-07-30）

状态：已通过。

- 首页和 profile 卡片均可进入；支持活动和非活动 profile。
- 支持普通 IP DNS、DoH、DoT、TCP、UDP、QUIC、`fake-ip` / `redir-host`
  以及 IPv6 DNS 响应控制。
- Bootstrap 只接受 IP；端点协议、主机、路径、端口、凭据、数量和长度均在
  保存前验证。
- profile 存储拆分为 raw、base 和 effective 三层；订阅刷新保留覆写，
  “跟随配置”恢复最新 base 的精确字节。
- 运行中的活动配置保存复用安全停止/启动协调器；失败回滚同时恢复策略、
  有效 YAML、metadata hash 和 active hash。
- Android 16 实际验证自定义 DoH、恢复订阅默认值和一次原生启动失败回滚；
  三条路径最终均为 Running，Controller/DNS/代理公网为 200/200/204。
- Android 16 arm64 完整仪器套件 19/19；HyperOS 真机生命周期矩阵 14/14，
  恢复后同样为 Running、200/200/204。
- Debug 单元测试、Lint、Debug、AndroidTest 和 R8 Release 干净门禁通过。

详细设计和验收记录见
[CUSTOM_DNS_SETTINGS.md](CUSTOM_DNS_SETTINGS.md)。

下一项：实现 Android Quick Settings Tile。快捷开关必须复用现有显式
Start/Stop 命令，正确处理未授权 VPN、无活动 profile、Starting/Stopping、
不可恢复 Error 与 Android 后台启动限制，不能在 TileService 中直接拥有或调用
Veercore。跨 ROM 与蜂窝门禁继续并行等待可用硬件。

### P1：AI 操作历史与快捷模板（2026-07-31）

状态：已通过。

- 新增最多 100 条的 app-private JSON 历史，按 profile 记录 prompt、LOCAL/LLM/SYSTEM
  来源、结果、实际规则和可撤销快照；不存储 API Key，且应用备份保持禁用。
- 再次执行重新进入完整 AI 解析和预验证链路，不直接执行历史中的过期节点计划。
- 规则存储和 Selector 选择均保存前后状态；撤销前必须与 after 快照一致，否则拒绝
  覆盖后续修改。撤销提交异常时执行反向补偿，并定向关闭受影响旧连接。
- AI 输入为空时显示四个可审阅模板；模板只填充输入框。首页展示最近 3 条，可展开
  到 10 条，并明确来源、结果、规则、再次执行与撤销状态。
- 171 个 Debug 单元测试、Lint、Debug、AndroidTest、R8 Release 均通过；HyperOS
  真机完成冲突拒绝和两级逆序撤销，保数据 instrumentation 19 项正常结束。

下一项：实现独立设置页面，集中 API Key、DNS、Per-App、后台保护、主题与关于入口，
保持设置本身不直接拥有 VPN/JNI 生命周期。

### P1：独立设置页面与三档主题（2026-07-31）

状态：已通过。

- 新增统一设置页，分为 AI 助手、网络与分流、外观、后台运行保护和关于；API Key、DNS、
  Per-App 与后台保护从首页迁移，首页仅保留高频运行入口。
- Key 不回显已有值，替换/清除继续复用 Keystore 加密存储；主页在恢复时重新读取可用状态。
- DNS 入口绑定活动 profile，应用分流摘要明确 ALL/ONLY/BYPASS 方向和应用数量。
- 主题新增 SYSTEM/LIGHT/DARK 持久化状态流，所有 Activity 共享且可即时切换；设置页不调用
  Veercore，不改变运行时所有权。
- 175 个 Debug 单元测试、Lint、Debug/AndroidTest APK、R8 Release 均通过；Android 16.1
  arm64 设置专项及完整 20 项 instrumentation 通过。HyperOS 保数据安装后 VPN 和八项网络
  诊断恢复健康，临时诊断历史已清理。

下一项：提取硬编码 UI 字符串并建立中英文资源结构；随后迁移到单 Activity + Compose
Navigation，减少页面切换闪烁。
