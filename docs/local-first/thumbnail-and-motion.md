# 缩略图裂图修复与动态图片实现记录

日期：2026-10-22。范围：本地缩略图生成、缩略图缓存规格、动态照片与动图播放。未新增账号、同步或云端能力。

## 裂图根因

现象：网格与查看器胶片条里，大尺寸照片显示为裂图图标。

根因不是取图失败，而是 Rust 核心的缩略图准入预算拒绝了大图：`prepare_thumbnail` 先按原始分辨率估算解码内存，超过 128 MiB 预算就直接返回 `DecodeBudgetExceeded`，缓存目录被建出来却没有缩略图文件，界面于是显示裂图。真实图库 391 项里有 46 项命中，其中包含全部小米动态照片（`MVIMG_*.jpg`，4096×3072 且尾部追加 MP4，文件 16 MB 以上）与两张 upscayl 放大的 PNG（9040×13136、10580×4428）。视图切换只是让这些照片进入视野，所以表现为"切到年/月视图才看到裂图"。

## 重构前的缩略图规格（已逐项核对旧客户端与旧缓存）

| 项目 | 重构前（旧 GTK 客户端） | 重构后（修复前） | 现在 |
|---|---|---|---|
| 缓存档位 | 256 / 512 / 1024 | 256 / 512 / 1024 | 不变 |
| 网格档位选择 | 按模式固定：年=256、月=512、日=512 | 按瓦片设备像素选最小可用档 | 不变，且不会放大 |
| JPEG 质量 | 90（旧缓存量化表实测 (3,2)） | 85 | 回到 90 |
| JPEG 解码 | libjpeg-turbo IDCT 缩放解码 | 全分辨率解码 | 预算内全解码，超预算走 IDCT 缩放 |
| 缩放滤波 | 双线性 | 面积滤波 | 不变 |
| 透明像素 | 合成到白底 | 直接丢弃 alpha | 回到合成白底 |
| 视频缩略图 | ffmpeg 取无损帧后再存 q90 | ffmpeg 直接存 MJPEG（实测 q75） | 无损帧 + 统一 q90 |

## 修复实现

- `crates/photo-core/src/media/scaled.rs`（新增）：JPEG 用 `jpeg-decoder` 的 IDCT 缩放解码（1/8、1/4、1/2），PNG 用 `png` crate 逐行流式解码加箱式滤波，两者都不再按原始分辨率分配内存。
- `crates/photo-core/src/media/thumbnail.rs`：预算内保持原来的全解码路径（画质最好）；超预算改走有界解码，不再拒绝大图。保留 256 Mpx 源像素上限，异常输入仍返回 `DecodeBudgetExceeded`。质量常量提到 90，透明合成白底。
- `crates/photo-core/src/media/external.rs`：视频缩略图改为 ffmpeg 输出无损 PNG 帧，再统一由 q90 编码发布。
- 缓存档位加入修订号 `cache/<媒体 id>/<内容版本>/r<rev>/thumbnail-<档位>.jpg`；`LocalLibrary::open` 会清理旧修订号目录，编码器一改，旧条目自动重建而不是被复用。

## 动态图片实现

对齐重构前客户端的动图体验：

- 动态照片（JPEG + 追加 MP4）：网格角标、查看器"播放动态照片"按钮原已存在，本次补上**设置项"立即播放动态照片"**（照片与视频分类，默认关闭，与旧客户端默认值一致），打开动态照片时可直接播放片段。
- 动图（GIF）：重构前会把每一帧解码出来在查看器里循环播放；重构后只显示首帧。本次补齐：`crates/photo-core/src/media/animated.rs` 把动图逐帧解码成缓存里的 JPEG 帧（沿用旧客户端的 300 帧 / 64 Mpx 上限与 20 ms 帧时长下限），`AnimatedImageStage` 按原始节奏循环播放，帧清单落盘后复用，不重复解码。

## 验证

- Rust：`cargo test -p photo-core --test media_local`（20 项，含"大图仍能产出缩略图""透明合成白底"）、`--test media_animated`（6 项）、`--test local_library`（5 项，含"旧修订号缩略图被清理、预览文件保留"）全部通过。
- Dart：`flutter test test/animated_stage_test.dart`、`test/appearance_settings_test.dart`、`test/presentation_test.dart` 通过；`flutter analyze` 无问题。
- UX 全旅程：`python3 -B tools/ux_cli.py run --evidence-dir <dir> --mode release --skip-build` 68/68 步、11/11 项通过，其中新增 `ux-motion-auto-play-preference` 步骤覆盖新设置项与自动播放，`ux-media-kind-heic-and-gif` 追加了动图帧落盘断言。证据见 [motion-thumbnail](../verification/local-features/motion-thumbnail/report.json) 与同目录截图、日志。
- 真实环境：以真实图库启动 Release 客户端，46 张大图全部生成缩略图（缓存修订目录 `r3`），旧 `r2` 条目被清理；新缩略图量化表实测 (3,2)，即质量 90。

## 顺带修正的过期验收断言

两处 UX 旅程断言早于当前实现，与本次功能无关但会阻断旅程：

- "重新扫描"步骤仍期望 `discovered == 7`，但扫描在 dc7d832 之后改为增量：未变化文件只 stat 并计入 skipped。现在断言 `discovered == 0` 且 `skipped >= 7`。
- 旅程用 `photo-` 前缀查找网格瓦片，画布重构后窗口外壳也带 `photo-panel-clip` 键，导致选中的是外壳而不是瓦片。现在按媒体 id 形态精确匹配瓦片键。

## 图库重建（另一 worktree 改动数据库后）

用户报告：另一个 worktree 改动了数据库，当前数据库无法使用，要求删除后重新验证。

排查结论：数据库文件本身没有损坏（`pragma integrity_check` 返回 ok），而是那个 worktree 把 schema 升到了 **v4**，本客户端只支持 v3，按设计拒绝打开未来版本数据库（不做自动降级）。该数据库里 `albums` 表本来就是空的，侧栏相册是按来源文件夹从文件系统派生的，所以没有不可再生的相册数据丢失；会丢的只有媒体目录（可重扫）和偏好设置。

处理：

- 备份原文件到 `/tmp/library-v4-broken.sqlite`，删除 `library.sqlite` 及其 `-wal`/`-shm`。
- 客户端重建出 schema v3 的新库，自动发现两个来源（`~/图片`、`~/视频`），重扫后 `media`/`media_details` 各 392 行，与旧库一致。
- 偏好设置在删除前导出（12 项，含新增的 `autoPlayMotionPhoto`），重建后写回。
- 旧库遗留的 392 个缩略图缓存目录（媒体 id 已变）被清理，释放 37.3 MB；随后 165 个大文件（含动态照片、放大 PNG、视频）重新生成缩略图，全部为质量 90。

## 与远端 v4 云同步提交的合并

远端 `9337d24`（接入 sync-client SDK 完成云同步双向 MVP）把图库 schema 升到 v4，并新增了 5 张云同步表。本轮改动与它重叠在 `local_library.rs`、`tools.rs`、`media.rs`、桥接层与查看器上，合并时逐处解冲突：

- `local_library.rs`：保留远端的 `SCHEMA_VERSION = 4`、`EXTENSIONS`/`CLOUD_SCHEMA` 与 `cloud_store`，同时保留本轮的缩略图缓存清理钩子（`.inspect(prune_thumbnail_cache)`）与远端新增的 `closed` 标记。
- `media.rs`：保留本轮新增的 `animated`/`scaled` 模块与缓存修订号常量，叠加远端的 `inspect_file`。
- 桥接层缩略图接口：保留远端的"云端缩略图兜底"（本地生成失败时回落到服务器下发的缩略图），路径改用本轮的 `r<rev>` 修订目录。
- `tools.rs`：保留远端的来源 `kind` 字段与托管来源保护，叠加本轮新增的 `autoPlayMotionPhoto` 偏好与缩略图缓存清理。

### 数据库升级验证

合并后的客户端把真实图库从 v3 升到 v4，按项目约定先备份再升级：

- 升级前先在真实图库 `backups/` 写入一致备份 `library-v3-before-v4-1792608112163-2865938f-….sqlite`（679936 字节）。
- 升级后 `schema_version` 与 `user_version` 均为 4，新增 `cloud_accounts`、`cloud_bindings`、`cloud_records`、`cloud_sync_state`、`cloud_uploads` 五张表。
- 数据零丢失：图库身份 `39945e9b-…` 不变，392 项媒体、392 条 `media_details`、2 个来源、12 项偏好全部保留，收藏与回收站计数一致。
- 迁移用例 `local_library_migration` 9 项通过，含 v3→v4 升级、备份失败回滚与"未来版本拒绝旧写入"。

## 未执行项

- 没有做十万张图库规模下的帧时间与内存验收。
- 没有做安装/发布验收与完整媒体格式矩阵。
- 动图与动态照片的实机观感由用户复核；自动化证据来自 UX 旅程的隔离夹具。
- 数据库重建后未做"旧版本数据库升级"路径的重新验证（本次是被要求删除重建，不走升级流程）。
