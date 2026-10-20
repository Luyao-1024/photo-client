# 一期本地开发进度

日期：2026-10-21。状态：**S02–S04 原生端到端已接通并完成阶段验收**（S02 PASS、S03 PASS、S04 PASS；交互式 GTK 选择对话框自动化未通过，见“未验项”）。S05 及以后未开始。

## 本轮接通内容

| 归属 | 内容 | 检查 |
|---|---|---|
| 绑定 | 重新生成 flutter_rust_bridge 2.13.0 绑定，纳入 `local_library` API；`thumbnail` 增加 256/512/1024 缓存档位 | `cargo check/clippy -p photo-bridge`、`cargo fmt --all --check` |
| 原生 gateway | `NativeCoreGateway` 实现 `LocalLibraryGateway`（open/list/add/cancel/thumbnail/favorite/watch），`--data-root` 隔离数据根 | 真实旅程（见下） |
| 选择器 | `FileSelectorSourcePicker`（file_selector Linux 插件，bundle 内含 `libfile_selector_linux_plugin.so`） | 对话框可真实打开并有截屏证据；键入确认自动化未稳定（未验项） |
| 界面 | 网格按可视设备像素选择缩略图档位；查看器缩放按钮/快捷键/百分比、拖拽平移、沉浸浏览；runner 支持 `--window-size=WxH` | widget 测试 28/28、真实窗口旅程 |
| 验收工具 | `app/lib/selftest`（真实窗口旅程驱动：X11 输入握手、RepaintBoundary 与 X11 双截屏、阶段记录）；`tools/local_journey.py`（夹具、独立 Xvfb、xdotool 真实输入、记录解析）；`tools/local_stages.py`（S02–S04 阶段编排与报告） | `tests/platform` 73 项 unittest 通过 |
| 产品缺陷修复 | ① `RuntimeController` 关闭顺序：先关原生会话再取消事件流（否则真实窗口关闭挂死）；② 扫描结束后强制刷新（`refresh(force: true)`），避免读到提交前快照；③ 刷新不再被可能卡住的原生流取消阻塞，并加 20s 看门狗；④ 过期查询快照不得回写（revision 回退保护）；⑤ 查看器沉浸按钮置于 Stack 顶层保证可命中；⑥ 缩放指示跟随手势/滚轮缩放 | 真实旅程复现后修复并回归 |

## 阶段结果

| 阶段 | 门槛 | 关键事实 | 报告 |
|---|---|---|---|
| S02 | PASS | 无账号无网络建库；重启与 `unshare -rn` 网络命名空间内 LibraryId/数量/收藏保持；同根第二进程被 `LibraryAlreadyOpen` 拒绝、异根独立打开 | `docs/verification/S02/s02-local-library-journeys/` |
| S03 | PASS | 真实目录扫描 6 发现/2 跳过/1 失败，8 个源文件 sha256/size/mtime 前后一致；重扫不重复；外部改写源升至 content_version 2 且缩略图换版本目录；2506 项库仅解码 24 个可见瓦片缓存；三档缓存尺寸与 EXIF 方向在磁盘上复核一致 | `docs/verification/S03/s03-sources-thumbnails/` |
| S04 | PASS | 390/800/1440 三宽度完成“扫描→网格→查看→缩放/平移→沉浸→收藏→搜索→重启”全流程；删除源文件后仍索引、查看器显示不可用占位且不崩溃、其余照片正常解码 | `docs/verification/S04/s04-browsing-viewer-widths/` |

组件级证据（Rust）：`cargo test --workspace` 32 项通过；L02-03/L02-04/L03-04 在报告中标记 `evidence_level: component`。

## 未验项与限制（不伪报）

- **交互式 GTK 选择对话框**：对话框可真实打开（证据目录内 `picker-dialog-*.png` 截屏，含真实 GTK 文件选择器界面），但用 xdotool 键入路径并确认在 Xvfb 下不稳定（位置输入后列表/确认按钮状态不可靠），故“真实点选目录”的自动化记为未通过；L03-01 的选择路径使用脚本化 picker + 真实扫描/真实文件，选择对话框本身留给真人或 AT-SPI 会话复核。截屏含用户主目录条目，**不随仓库公开**。
- **窗口级全屏**：需要窗口管理器；Xvfb 无 WM，记 NOT RUN。应用内提供沉浸浏览（已验）。
- **GPU/真实合成桌面视觉**：NOT RUN（Xvfb 软件渲染）；液态玻璃真实材质验证留 S10。
- **取消扫描的应用级“中途停止”语义**：夹具扫描过快时取消请求落在扫描完成后（记录 `outcome: scan completed before the cancel request landed`）；取消语义的确定性证据在组件测试 `cancellation_before_start_and_at_first_batch_stops_discovery`。
- **hover 不误切相册、多选作用域**：属 S06（手动相册/多选尚未实现）。
- 十万图库性能（S05）、文件管理（S07）、编辑（S08）、监听恢复（S09）、综合性能与玻璃（S10）、安装交付（S11）未开始。

## 复现命令

```sh
export PHOTO_FLUTTER_ROOT=/home/luyao/.local/share/photo-client/flutter
./tools/acceptance run --stage S02 --integration --mode release --evidence-dir <fresh>
./tools/acceptance run --stage S03 --integration --mode release --evidence-dir <fresh>
./tools/acceptance run --stage S04 --integration --mode release --evidence-dir <fresh>
python3 -B -m unittest discover -s tests/platform -p 'test_*.py'
```

## 交付状态

- 本地 commit 已创建并推送：GitHub 公共仓库 `Luyao-1024/photo-client`（main）。
- 无远端 CI；未做安装/打包验收；用户体验确认 `not_recorded`。
