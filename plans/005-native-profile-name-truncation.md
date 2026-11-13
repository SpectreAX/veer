# 005 — 配置名交给系统文本截断

- **Status**: DONE
- **Scope**: MainView.swift 的 ProfileMenu 标签
- **Evidence**: fresh-cpu-summary.json、lightweight-final-comparison.json

## 问题与改动

CPU采样定位到 MainView.profileName 在分栏布局中重复调用 String.shortened，逐前缀调用 NSString.size(withAttributes:)。18次热循环的包含采样权重约250.8ms，其中shortened约239.8ms；两者是同一路径，不能相加，也不是函数精确计时。

改为保留完整名称，在原生Text内 lineLimit(1)、truncationMode(.tail)、maxWidth160/90。保留Menu.fixedSize、chevron、完整名称help/AX value，短名称自然宽度由系统决定。没有新增缓存、状态或测量循环。

## 验证

完整verify454通过。新隔离构建的40张相关静态图全部独立查看，含3页、两语言/两外观、窄/面板/宽窗及Latin长名；20张窄窗和36张标准窗动态中独立抽看12帧，无新Critical/Major。CUA在窄窗打开配置菜单，完整名称仍可查看。

Animation Hitches+Points of Interest同条件20次开合，排除前2后18次、含Native AnimationEnd后100ms收尾（上限下一次输入）：基线45次/749.99ms，004后27次/450.00ms，本轮最终14次/233.33ms。单轮对照支持改善，不能宣称所有页零卡顿或固定FPS。
