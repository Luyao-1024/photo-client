# 开发进度记录

## 2026-10-21 用户指定停止点

按用户要求，完成HEIC解码依赖打包与真实窗口复核后结束本次修改。HEIC已显示、缩略图与预览已生成、原文件SHA-256未变；[本项证据](../verification/local-features/heic/report.json)。剩余验证、已知静态检查问题、Release构建和后续UX用例安排已保存到[后续验证清单](pending-verification.md)。未提交、推送或部署。

## 2026-10-21 本地功能与UX扩展

用户限定：当前仍为第一阶段，不新增任何同步功能；优先完成功能，后续再完善测试，尤其不新增UX自动化用例。

本轮代码、运行检查与剩余验收边界见[交付记录](local-feature-delivery.md)。已实现的搜索、相册、文件管理和编辑不再按下文旧记录视为“尚未实现”。下文S02–S04是当时版本的验收历史，未执行的旧子项与最终性能门槛不会自动转为通过。

---

日期：2026-10-20 暂停 → 2026-10-20/21 恢复。状态：**按用户要求恢复开发**，完成恢复入口第 1–3 步（FRB 绑定再生、原生 gateway 接通本地接口与真实选择器/`--data-root`、隔离临时库真实旅程），并执行 S02–S04 真实端到端旅程。未使用用户照片完成自动验收。

## 已完成共用工程检查点

S01 技术验收已通过：两次 Linux release 构建、真实 Xvfb 窗口、UTF-8 往返、事件顺序、正常关闭、配置摘要/协议错配拒绝与重复构建一致性。证据：[S01 报告](../verification/S01/s01-linux-local-foundation/report.json)。

组件层证据（暂停前，仍有效）：S02 `local_library` 4/4、S03 `media_local` 18/18、S04 widget 28/28、`cargo check/fmt/clippy` PASS。这些是各自层级证据，不累加为端到端通过。

## S02–S04 真实端到端旅程（本次恢复）

通过 `tools/journey run --evidence-dir <fresh> --skip-build` 执行（隔离 Xvfb 显示 + xdotool 真实输入 + 真实 SQLite/FFI/文件/缩略图）。证据：[journey 报告](../verification/S02-S04/local-journey/report.json)，关键截图同目录（`01-grid.png`、`02-viewer-favorite.png`、`10-restart-favorite.png`）。

- 9 个 run 全 PASS：provision（扫描/网格/查看器/收藏）、hold + probe-rejected（单 writer 数据根锁）、probe-independent（独立数据根并发）、reopen + 390x844/800x600/1440x900（重启保留）、missing（源缺失不阻断）。
- 9 项 check PASS：L02-01、L02-02、L03-01、L03-02、L03-03、L04-01、L04-02、L04-03、L04-04。
- 扫描计数与 fixture 清单一致（发现 6 / 跳过 2 / 失败 1）；源文件字节与 mtime 未变（`source_facts.unchanged = true`）。
- 重启锚点正确：library_id、opened_count=6、收藏路径在 reopen 后保持一致；收藏经全新 favorites-only 原生查询验证。
- **gate = INCOMPLETE**：8 个子项无法端到端驱动，诚实记为 NOT RUN —— L02-03、L02-04（仅组件测试）、L03-01-dialog（真实 GTK 选择器）、L03-02-rescan、L03-03-bounds、L03-04、L04-02-viewer-gestures、L04-04-hover。

旅程中修复的真实缺陷：
1. `xdotool click` 零时长按压不被手势竞技场识别为 tap（hover 生效但 click 无效）→ [helper](../../tools/local_journey.py) 改为 mousedown/保持/mouseup 的真实按压时长。
2. provision 的 `opened_count` 记录的是扫描前空库，导致 reopen 锚点错配（expected 0 got 6）→ [journey](../../app/lib/selftest/local_journey.dart) 在网格步后把锚点更新为扫描后库状态。
3. 查看器缩放下界声明 0.5 但 InteractiveViewer 对满视口子节点钳制在 fit(1.0)，致 zoom-out 按钮"启用但无效" → [viewer](../../app/lib/ui/local_photo_viewer.dart) `_minScale` 改为 1，widget 测试下界同步为 100%。
4. （此前）RuntimeController 关闭死锁（先取消永不完成的 FRB 流）与 trace 的 IOSink StateError 已修复。

补充 widget 测试：新增 `viewer_zoom_test.dart`（3 项：缩放边界/沉浸/连发一致性）与 `responsive_widths_test.dart`（3 项：三分辨率全流程 + hover 不改变状态）。`flutter test` 全 35 项 PASS；`flutter analyze lib test` 0 问题。

## 当前未完成

- 上述 8 个 NOT RUN 子项仍仅组件级覆盖：真实 GTK 文件/目录选择器、重复源 rescan 去重与中途取消、256/512/1024 缓存匹配与解码优先级/有界队列、解码期间源变更、全屏查看/缩放平移/快速切换锚点、hover 不激活与焦点/触控目标、L02-03 跨库外键与命令作用域、L02-04 事务失败与迁移中断保留。**gate 保持 INCOMPLETE**。
- reopen 查看器截图中图像主体偶发空白（截图早于异步解码完成）；不影响基于 DB/查询的断言，记为证据质量问题。
- 十万图库性能、组织/搜索、文件管理、本地编辑、监听恢复、综合性能/玻璃 UX、Linux 安装交付未完成；云同步继续留二期。

## 下一步入口

1. 决定是否为 8 个 NOT RUN 子项补端到端手段（真实 GTK 选择器需驱动真实对话框；缓存边界/手势需测量手段），或按验收规则在接受当前覆盖的前提下记录并关闸。
2. 关闸后才进入 S05 十万图库前置性能。

没有创建提交、推送、远端 CI 或部署；没有修改相邻 PhotoViewer 和 SyncServer 项目。
