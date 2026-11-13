# Veer macOS AI Editor — Open Design Prototype

## Deliverable and boundary

Create a new, clearly named Open Design project: **Veer · Liquid Glass AI Editor**.
Build a high-fidelity, interactive desktop design prototype, not production SwiftUI.
Do not overwrite an existing Open Design project or change the Veer application.
All data and AI results are simulated. No remote API calls, real credentials,
subscriptions, complete proxy configurations, VPN, controller, or live networking.
UI language: Simplified Chinese. Preserve Veer brand and green accent.

## Product and visual direction

An AI-assisted editor for independent Mihomo rules snippets. Users manually
register allowed policy groups and declared regions, enter a service-routing
instruction, inspect destinations and changes, confirm the draft, undo, export.
Borrow Clash-Client's macOS sidebar, generous spacing and quiet organization;
do not copy its proxy connection dashboard or introduce a Start VPN button.

Use macOS-style system typography, window traffic lights and native-looking
navigation. Default canvas: 1320 × 900 logical pixels, sidebar about 210 wide.
Support 1080 × 700 with scrolling and no overlapping controls. Page inset 32,
section spacing 16/24, content panels about 20-radius. Neutral surfaces, restrained
green tint. Keep rule text and Diff solid, readable and selectable. No full-screen
glass, gradients, decorative metric cards, marketing hero, or excessive shadows.

Liquid Glass belongs to the operation layer: pill/circular utility buttons,
primary generation/confirmation actions, toast. Combine a restrained translucent
fill, backdrop blur, subtle highlight and clean border; this is a web approximation
of native Liquid Glass, not an assertion of a native implementation. Provide
opaque fallback under reduced transparency and legible dark appearance.

Remove the redundant top title strip. Keep traffic lights and sidebar toggle in
window chrome; page title and utility actions belong to the content header.
Undo/check/export buttons need tooltips and accessible labels.

## Navigation and layout

Sidebar brand: Veer. Sections: 编辑 (AI 工作台, 规则稿), 配置 (策略组, AI 设置).
Bottom privacy note: 不读取节点配置或订阅密钥. Treat privacy as a boundary,
not an audited security claim. No connection badge or traffic chart.

Workbench: a practical two-column layout with independent scrolling.
Left: registered policy groups (flat rows with name and declared region), and
editable rules snippet with monospace text. Right: multiline AI instruction,
small example actions, generation action, then review summary and expandable Diff.
Maintain one shared draft across all pages; changing navigation must not reset it.

Default populated mock groups: 日本出口 / 日本, 美国出口 / 美国, 香港出口 / 香港.
Also support DIRECT and REJECT. Region label: 声明地区，未实测.
Default draft: DOMAIN-SUFFIX,example.com,DIRECT and MATCH,DIRECT.

## Primary flow

1. Type or select “Netflix 走日本，ChatGPT 走美国” (also understand the mock
   examples “Netflix go hk”, “ChatGPT go us”).
2. Generate preview; show a brief cancellable simulated loading state.
3. Preview lists explicit service → destination mappings, never just “Netflix”.
   Example: Netflix → 日本出口（日本）；ChatGPT → 美国出口（美国）.
4. Explain validation: 出口在登记列表中；规则格式检查通过（原型模拟）；
   地区为用户声明，未验证实际可达性. No “connection succeeded” claims.
5. Expand YAML Diff, with +/− prefixes, readable neutral code text and muted
   line backgrounds; color is not the only difference cue. Proposed rules go
   before MATCH,DIRECT. Example Netflix domains: netflix.com, nflxvideo.net;
   ChatGPT: chatgpt.com, openai.com. Label service coverage 示例，非完整规则集.
6. Primary action “确认到规则稿”; secondary “放弃预览”. Candidate is not written
   into the shared draft until explicitly confirmed. Editing the instruction,
   groups or draft invalidates stale candidates and requires a fresh preview.
7. Confirm changes the draft and enables undo; toast “已确认到规则稿，尚未应用到代理”.
8. Undo restores prior draft; export downloads only the current rules snippet.

“节点太卡了换一个” must not fabricate latency measurements or select a node.
Show inline scope explanation: 当前只编辑规则，不能检测延迟或切换运行中的节点.
Unknown region or missing destination blocks confirmation and suggests registering
a matching group. Arbitrary unsupported instructions show a clear recoverable
message rather than silently routing to a default provider.

## Other screens

- 规则稿: one shared editable code area, check/undo/export, unsaved changes cue.
- 策略组: add/remove group and declared region. No node password/server fields.
- AI 设置: clearly labelled mock provider endpoint/model fields, masked demo
  API-key placeholder only, explanation that real native app uses Keychain.
  Never request, display, persist or transmit a real key. Prototype shows “演示模式”.

## Feedback and accessibility

Success/info toast clears after 4 seconds, errors after 8 seconds, loading until
finished/cancelled. New message resets timeout and stale timers cannot remove
new feedback. Toast overlays near the bottom, never a permanent full-width row;
close action available. Important errors also remain inline at the relevant input.
One primary action per stage; disabled buttons explain why. Avoid focus loss
when feedback appears. Keyboard focus visible; inputs genuinely editable with
Chinese punctuation. Escape closes temporary overlays; Command+Enter generates
preview. Dark/light toggle and reduced-motion/opaque-material fallback available.

## Verification and handoff

Verify mock generate → review → confirm → undo → export flow, missing-group
handling, stale-candidate invalidation, toast dismissal, sidebar state retention.
Inspect desktop light/dark and narrow layout in a single bounded verification
pass, fix concrete defects, and do one final confirmation. Do not polish endlessly.
Use Open Design's documented preview/screenshot tools if available. Return the
project identifier, artifact identifier/path, preview URL and verification results.
Do not invent URLs or claim unperformed tests. Keep all created files inside the
new Open Design project. Record design/prototype limitations in that project.
