# Veer OpenCode 参考交互原型

独立本地原型，非 SwiftUI 程序，也不是 OpenCode 的像素级克隆。构图与可折叠文件审阅参考固定 v2 源码；来源、许可、未观察项见 `../../docs/OPENCODE_UI_REFERENCE_2026-10-14.md`。

运行（无需安装依赖）：

```sh
cd /Users/spectreax/Developer/Veer/prototype/opencode-review
python3 -m http.server 4318 --bind 127.0.0.1
```

打开 http://127.0.0.1:4318/ 。测试：`node --test state.test.mjs`。

演示步骤：点击加号 → 从文件或 URL 载入内置示例 → 点击示例指令并发送 → 打开文件审阅 → 确认修改 → 查看规则稿 → 撤销。顶部外观按钮直接切换；场景菜单演示长文本和请求失败；忙碌时发送按钮变为取消。小于 1200px 时审阅替换对话区域，关闭审阅回到原对话。

所有状态均为合成演示。没有配置文件选择器、订阅下载、请求 API、密钥输入或持久化。CSP 的 `connect-src 'none'` 阻止页面连接编辑服务和 AI。URL 字段固定为不可访问的 `.invalid` 示例。导出只生成内置示例规则，不能被误认为真实完整代理配置。

玻璃按钮为 CSS 示意，原生版本仍需 SwiftUI 的平台材质。当前原型审阅前不改动程序。临时参考检出在 `/tmp/veer-opencode-v2-reference-20261014`，原型运行不依赖它。
