# S02 独立本地图库 · 真实旅程验收

- 阶段：`S02 / 独立本地图库`
- 设计版本/计划版本：`local-first plan_version=2, phase=local`
- 实现状态：`implemented`（应用级旅程）＋组件级回归
- 技术门槛：`passed`（`report.json.gate_status = PASS`）
- 用户体验确认：`not_recorded`
- 验证人/时间：Codex 自动验收，2026-10-20（Asia/Shanghai，UTC 报告时间见 report.json）
- 构建摘要：release bundle `app/build/linux/x64/release/bundle`；原生库 SHA-256 `8a2152dbbf397fd64dd088ab7b7ff70b01e4b84bb9003788668d1120c13bd5f7`（与 bundle 内安装件一致，见 report.json `evidence.artifacts`）
- profile digest：`7d53d9326d3afebc855e822b4b243c29f6e3482c9445fb44cb284f5087801280`
- 前置阶段及报告：S01 `docs/verification/S01/s01-linux-local-foundation/report.json`
- 环境/数据根/数据集：每次旅程独立 Xvfb（见 report.json `evidence.displays`）；数据根 `/tmp/s02-final3/data-root`（隔离临时目录，权限 0700）；数据集为 `fixtures/` 内合成图片（6 张 JPEG/PNG/WebP，含 EXIF 方向 6 一张、坏图与符号链接各一），未使用用户照片

## 本次交付

真实窗口旅程驱动（`app/lib/selftest/`）接通正式 FFI/SQLite/文件路径：`--local-journey` 复用产品 UI 与 `NativeCoreGateway`，X11 真实输入（XTest/xdotool）经文件握手注入；`--data-root` 支持隔离数据根。

```text
实际启动命令：./tools/acceptance run --stage S02 --integration --mode release --evidence-dir <fresh>
实际验证命令：python3 -B -m unittest discover -s tests/platform -p 'test_*.py'
产物及SHA-256：见 report.json evidence.artifacts（native/bundle/locks/bindings/profiles）
```

## 阶段检查项

| 编号 | 实际操作/命令 | 结果 | 可观察事实 | 原始证据 |
|---|---|---|---|---|
| L02-01 | provision → reopen → `unshare -rn` reopen，同一数据根 | PASS | LibraryId `753afd4b-…`、6 张、收藏 `large.jpg` 在重启与无网络命名空间内均保持；重启未重扫 | journey-provision.log、journey-reopen.log、journey-reopen-offline.log |
| L02-02 | hold 持有数据根期间并发 probe-open | PASS | 同根第二进程被 `LibraryAlreadyOpen` 拒绝；另一数据根独立打开（`45415dc3-…`，0 项） | journey-hold.log、journey-probe-same-root.log、journey-probe-other-root.log |
| L02-03 | `cargo test -p photo-core --test local_library` | PASS（component） | `foreign_source_and_invalid_batch_roll_back_counts` ok；应用层无跨库写入口 | cargo-local_library.log |
| L02-04 | `cargo test -p photo-core --test local_library` | PASS（component） | `one_writer_per_data_root_and_future_schema_is_not_reset` ok | cargo-local_library.log |

## 功能编号与回归

| 场景 | 首次/回归 | 结果 | 证据 |
|---|---|---|---|
| 真实扫描入库（6 发现/2 跳过/1 失败） | 首次端到端 | PASS | journey-provision.log facts.scan |
| 收藏写入与 favorites-only 查询一致 | 首次端到端 | PASS | facts.favorite（query_total=1） |
| 1440x900 真实窗口渲染（RepaintBoundary 与 X11 截屏双份） | 首次端到端 | PASS | 01-grid-x11.png、05-immersive-x11.png、10-restart-favorite-x11.png |
| S01 冒烟/平台测试回归 | 回归 | PASS | tests/platform 73 项 unittest 通过（含 S01 合同） |

## 性能与视觉

- 峰值 RSS（KiB）：provision 610940、reopen 510928、offline reopen 502820、hold 397856、probe 约 181000（report.json journeys[].peak_rss_kib）。
- 视觉：Xvfb 软件渲染（Impeller OpenGL-ES/Skia 回退），截屏为真实窗口像素；**GPU/真实合成桌面视觉验证 NOT RUN**。

## 缺陷与未执行项

| 缺陷/检查项 | 严重性与影响 | 复现/原因 | 修复/重验入口 | 是否阻断 |
|---|---|---|---|---|
| `RuntimeController` 先取消事件流再关原生会话导致关闭挂起 | 高：真实窗口关闭/旅程退出挂死 | FRB 流任务只在收到 `closed` 事件后结束 | 已修复为先 `gateway.shutdown()` 再取消订阅；本阶段旅程与 widget 测试回归通过 | 已修复，不阻断 |
| L02-03/L02-04 仅有组件级证据 | 低：应用层无跨 LibraryId 表面 | 契约如此 | 若后续暴露跨库 API 需补应用级检查 | 不阻断 |
| GPU/合成桌面视觉、安装打包 | 未执行 | Xvfb 无合成器；S10/S11 范围 | S10/S11 | 不阻断本阶段 |

## 结论与下一步

- 技术结论：S02 应用级门槛 `passed`；组件项以 component 级别记录。
- 用户体验结论：`not_recorded`。
- 下一阶段：可进入 S03（来源与缩略图）真实验收。
- 需重验：本阶段证据基于 commit `772720e` 之后的接线修复；后续若改动 `runtime_controller`/gateway 关闭路径需重跑本阶段。
- commit/push/远端CI/安装运行：本地 commit 已创建并推送至 GitHub 公共仓库 `Luyao-1024/photo-client`（main）；无远端 CI；未做安装验收。
