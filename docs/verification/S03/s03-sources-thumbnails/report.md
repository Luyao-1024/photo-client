# S03 来源与缩略图 · 真实旅程验收

- 阶段：`S03 / 来源与缩略图`
- 计划版本：`local-first plan_version=2, phase=local`
- 技术门槛：`passed`（`report.json.gate_status = PASS`）
- 用户体验确认：`not_recorded`
- 构建摘要：release bundle；原生库 SHA-256 见 report.json `evidence.artifacts`
- 前置阶段：S01（工程）、S02（本阶段同批数据根复用其旅程驱动）
- 环境/数据根/数据集：每旅程独立 Xvfb；数据根 `/tmp/s03-final7/data-root*`；夹具 `fixtures/`（6 图＋notes.txt＋broken.jpg＋link.png）与 `fixtures-bulk/`（另 2500 张 16x16 PNG）

## 阶段检查项

| 编号 | 实际操作/命令 | 结果 | 可观察事实 | 原始证据 |
|---|---|---|---|---|
| L03-01 | provision 旅程：真实 add-folder → 递归扫描 → 首批可浏览 | PASS | 6 发现/2 跳过/1 失败；8 个源文件 sha256+size+mtime 扫描前后完全一致；首批（全部 6 张）立即可查询并渲染 | journey-provision.log、01-grid-x11.png |
| L03-02 | changed 旅程（外部改写 beta.jpg 后重扫）＋ cancel 旅程（2506 项） | PASS | 重扫 before=after=6 无重复；beta.jpg 升 content_version 2、缩略图换 `…/2/thumbnail-512.jpg`、解码 1024x768；取消旅程扫描先于取消请求完成（`outcome` 记录），库保持 2506 且重扫后仍 2506、无重复行 | journey-changed.log、journey-cancel.log、40-changed-source-x11.png |
| L03-03 | 缓存档位与可见窗口解码 | PASS | 256/512/1024 三档文件尺寸与源宽高比/EXIF 方向逐一复核（256x192、512x384、1024x768；oriented.jpg 512 档为 341x512）；2506 项库仅 24 个缓存目录＝24 个可见瓦片；10 份渲染截屏非空白；峰值 RSS 484272 KiB | report.json evidence.thumbnail_classes / bulk / rendered、30-bulk-grid-x11.png |
| L03-04 | `cargo test -p photo-core --test media_local` | PASS（component） | `source_size_or_mtime_changes_reject_stale_work_and_preserve_existing_cache` ok（解码/发布期间的源变化拒绝旧结果并保留旧缓存） | cargo-media_local.log |

## 缺陷与未执行项

| 缺陷/检查项 | 严重性与影响 | 复现/原因 | 修复/重验入口 | 是否阻断 |
|---|---|---|---|---|
| 交互式 GTK 选择对话框自动化（补充探针） | 中：L03-01 的“真实点选”一半依赖脚本化 picker | Xvfb 下 GTK 文件选择器位置输入后列表/确认按钮状态不可靠，xdotool 键入确认不稳定；探针 150s 超时 | `journey-picker.log`、report.json evidence.picker_dialog；对话框截屏仅存于本地证据目录（含用户主目录条目，不公开） | 不阻断文档门禁（补充项），需真人/AT-SPI 复核 |
| 取消“中途停止”的应用级观察 | 低：夹具扫描过快，取消请求落在完成后 | 2506 张 16x16 PNG 扫描 <1s | 组件测试已确定性覆盖取消语义 | 不阻断 |
| GPU/合成桌面视觉 | 未执行 | Xvfb 软件渲染 | S10 | 不阻断 |

## 结论与下一步

- 技术结论：S03 文档门禁四项 `passed`（L03-04 为组件级）。
- 用户体验结论：`not_recorded`。
- 下一阶段：S04（已完成，见其报告）；之后 S05 十万图库性能。
- commit/push/远端CI/安装：本地 commit 已推送 GitHub 公共仓库；无远端 CI；安装验收留 S11。
