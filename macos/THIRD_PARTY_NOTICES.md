# Third-party notices · 第三方组件声明

Veer bundles the components below. Each keeps its own license; the full license texts ship inside
the app at `Veer.app/Contents/Resources/licenses/`.

Veer 随应用打包以下组件，各自适用其许可证；许可证全文位于应用包内 `Veer.app/Contents/Resources/licenses/`。

## Mihomo v1.19.29

- Used as a separate program, `Contents/Resources/bin/mihomo`, that Veer starts and controls
  through its local HTTP controller. Veer does not link to it.
  作为独立程序使用：Veer 启动它，并通过本机 HTTP 控制接口控制它，不与其链接。
- License: GNU General Public License v3.0 (`licenses/mihomo-LICENSE`).
- Copyright: the Mihomo (MetaCubeX) and Clash authors.
- Corresponding source: built unmodified from tag `v1.19.29` (commit
  `e26714a181ac0e2fa803453c0a8e9a9ce94e31cb`) of
  <https://github.com/MetaCubeX/mihomo/tree/v1.19.29> by `scripts/build-mihomo.sh`.
  对应源码：由 `scripts/build-mihomo.sh` 从上述标签原样构建，未作修改。
- Written offer: for three years from the release of each version of Veer, anyone may request a
  copy of the exact Mihomo source used for that version from the copyright holder of Veer
  (SpectreAX, <https://github.com/SpectreAX>).
  自每个版本发布起三年内，任何人都可以向 Veer 的版权所有者索取该版本所用 Mihomo 的完整源码。

## Yams 6.2.2

- Used as a Swift library to read and write YAML.
- License: MIT (`licenses/Yams-LICENSE`).
- Source: <https://github.com/jpsim/Yams>.

## Natural Earth

- `Resources/Map/land-110m.json` is the 1:110m land layer of Natural Earth, simplified, used to
  draw the node map. Public domain. Made with Natural Earth: <https://www.naturalearthdata.com>.
- 节点地图的世界轮廓来自 Natural Earth 1:110m 陆地数据（公有领域）。

## Reference projects · 参考项目

FlClash (chen08209/FlClash) and Bettbox (appshubcc/Bettbox), both GPL-3.0, informed which
features Veer offers. No code from them is included.
FlClash 和 Bettbox（均为 GPL-3.0）只作为功能参考，Veer 不包含它们的任何代码。
