# GTK → Flutter 性能迁移核对记录

核对日期：2026-10-22。旧实现来自同一工作区 `../photoViewer`，现实现为 `client`。记录的是本次已审阅的缩略图、浏览、扫描、元数据和同步热路径；不能据此推导整套应用所有场景都已做性能验收。

## 实现对照

| 旧应用策略和证据位置 | 当前落点 | 验证依据 |
| --- | --- | --- |
| JPEG libjpeg-turbo IDCT 缩放，`src/core/thumbnails/jpeg_turbo.rs`、`jpeg_scale_shim.c` | `photo-core/src/media/jpeg_scale_shim.c`、`scaled.rs`，原生缩放后受预算准入 | 实际 Release 样本计时；JPEG 方向/大图/只读源测试 |
| 内存/磁盘命中先返回，`thumbnails/cache.rs` | `thumbnail_loader.rs` 缓存命中绕过生成队列和状态写入，允许复用较大尺寸 | 忙队列下缓存快速返回、零记账写测试 |
| 优先级、在途去重、无人观察取消，`thumbnails.rs`、`queue.rs` | 前台/邻居封面/预热三级；多观察者共享，尚未入队的取消也生效 | 调度合并/晋升/取消用例；Flutter tile 复用用例 |
| 独立前台/后台/EXIF 缓存，`thumbnails.rs` | 路径池与解码缓存分开，512/64/768 项及独立字节预算；后台无重复解码晋升 | `thumbnail_image_test.dart`、`thumbnail_pipeline_test.dart` |
| JPEG 内嵌 EXIF 占位，`thumbnails/decode.rs` | 有界读取 IFD1，应用方向，不能覆盖已显示完整缩略图 | 真实 EXIF 小图核心用例及 Flutter 共享占位用例 |
| 可见 cell 每帧分批，`virtual_media_grid/factory.rs` | 每帧最多提交 24 个独立请求，回收 cell 不再提交 | 32 个请求只准入 24 个的定向测试 |
| 屏外只预解码已有缓存，`thumbnails.rs`、网格 range cache | 下一约两屏/最多 64 个已驻留 DTO、单路后台解码；不触发原图生成 | 核心 cache-only lookahead 测试；解码后台/晋升测试；尚无独立真实滚动帧率验收 |
| GTK 虚拟网格/渐进填充，`virtual_media_grid/*`、`media_grid/loading.rs` | 保留现有 Flutter Sliver 懒构建、分页 DTO；不需要迁入 GTK widget 填充代码 | 静态核对当前网格/分页调用；本次未跑全库规模矩阵 |
| 单 worker 空闲预热、100 ms 让步，`thumbnail_prewarm.rs` | 扫描暂停预热，单空闲 worker，逐项落状态，完成后休眠 | 预热收敛/失败收敛/完成后停止后台查询测试 |
| 跟随完整图库视口预热，`thumbnail_prewarm.rs` | viewport 媒体锚点按完整 live 排序解释，Month/Day 512、Year 256 | 核心锚点测试；Flutter 合并 viewport 指令测试 |
| 实际缓存核对和生成标记修复，`thumbnail_prewarm.rs` | 现有 thumbnails 表中按版本/尺寸/r4 记账，100 行核对，不抢占前台窄索引 | 丢失缓存修复、页/分组/标志同事务及索引隔离测试 |
| 原子发布、坏缓存修复，`thumbnails/cache.rs` | 原子 rename、源身份/mtime/size 检查，坏图片一次自动失效再生成 | 核心坏缓存/指纹/原子发布/符号链接测试 |
| 孤儿回收、容量限制，`thumbnails/cache.rs` | 异步维护 2 GiB；保留回收站/云端成员及非缩略图媒体缓存；到限停止全库生成循环 | 容量收敛、清理保留预览/动图文件、旧修订清理用例 |
| 进度及生成速度设置，旧设置/预热 UI | 网格固定浮层、设置进度、失败和缓存上限；1/2/4/物理核心档位；完成停止轮询 | 进度完成隐藏、设置桥接与核心状态用例；运行日志 |
| 原图就绪前保留缩略图，`ui/viewer/stage.rs` | `ProgressiveImage` 根据实际解码帧揭开静态层；失败可保留预览 | 延迟解码/错误/路径切换 Flutter 用例 |
| 视频/动态照片先显示静态图，`ui/viewer/stage.rs` | 暂停打开→首帧及实际纹理尺寸就绪→揭开静态层→播放，排除 Linux 初始化 1×1 空纹理；generation 阻止旧回调 | 可控异步会话测试；真实媒体 UX-11 结果见验证记录 |
| 动图先静态后播放，`ui/viewer/stage.rs` | 首帧解码才启动 timer，后续按帧延时 gapless，隐藏暂停 | 渐进动图测试；真实媒体 UX-11 结果见验证记录 |
| ±1 邻居、原图 OS 缓存提示、400 ms 预览等待，`ui/viewer/navigation.rs` | 邻居 DTO/缩略图预取；只读 fadvise；最新 token 保证画面/计数/胶片条同步 | viewer filmstrip、缩放、渐进图片定向用例 |
| 缓存详情、避免无关索引失效，旧 repository/viewer | 按媒体版本合并 metadata Future；收藏保留合法窄索引；分页/分组/标志同一读取事务 | 元数据缓存 2 例；browse 3 例 |
| 未变文件快速跳过和元数据批处理，旧 scanner/storage | 保留 stat-only 增量扫描，复用 256 KiB 头部和视频 probe；旧缓存清理离开同步打开路径 | incremental_scan 2 例；格式头部/EXIF 5 例 |
| 同步不生成上传缩略图、只用缓存，旧 native sync | 缓存缺失 deferred；后台 blocking 处理缓存读/转码；不建立上传操作 | cache-only upload 2 例、云端缓存显示 1 例、真实隔离服务器 deferred→resume 1 例 |
| 批量关系写入、分批上行、增量通知，旧 native sync | 下行 100 条事务、相同重放零写入；上行 20 元数据/5 照片让步，300 ms 合并通知 | 元数据事件/100 条耗时/相同重放零写入共 5 例；批次大小与通知为代码核对 |

## 当前平台适配

GTK Texture 对应 Flutter 的 ImageStreamCompleter；GTK GridView/FlowBox 对应 Flutter Sliver。当前 JPEG q90、透明图平铺白底和最多 2000 项单次选择沿用重写后的契约。未引入旧应用的透明 WebP 输出或 runtime.json 配置接口；这些涉及格式/配置兼容，不能把它们写成已逐字迁移。核心优先级、缓存隔离、解码缩放、后台让步及渐进显示按当前平台实现。

双轴视口解码上限 4096 和独立 128 MiB 原图缓存用于约束大图内存；这不是大图满分辨率分块渲染方案。HEIC/视频生成仍依赖现有原生转换/抽帧，未宣称与 JPEG 同幅度提速。

## 实际性能数据

真实用户图库的只读源，256 档，Release `prepare_preview`，每样本三次中位数，缓存文件每次使用新路径；OS 页缓存未清空。范围为解码、缩放、编码和发布，不包含排队、桥接、Flutter 图片解码、布局和 GPU。原始带私有路径的样本表留在 `/tmp/photo-thumbnail-diagnosis/`，不纳入仓库。

| JPEG 尺寸 | 优化前 ms | 优化后 ms |
| --- | ---: | ---: |
| 1220 × 2712，约 0.35 MiB | 15.330 | 4.908 |
| 1220 × 2712，约 1.03 MiB | 23.308 | 10.009 |
| 1080 × 14369 | 1799.527 | 23.553 |
| 8192 × 8192 | 1317.462 | 40.993 |

早期真实图库曾观察到 498/498 个 r4 256 缓存就绪、失败 0。该观察不是当前 512 档全部完成的证明，也不是滚动帧率、P95 或 RSS 数据。

## 验证记录

只运行本次直接相关用例，没有运行全量 Flutter、Cargo 或完整 UX 矩阵。

- Rust：调度 12；browse/索引 3；元数据 5；上传缓存 2；云端缓存显示 1；增量扫描 2；旧修订清理 1；媒体安全/解码 9；头部/EXIF 5，均通过。真实服务器 deferred→resume 专项先前已通过。
- Flutter：渐进媒体、动图、查看器缩放/胶片条、背景、缩略图请求池/解码缓存、元数据缓存相关文件。首轮 34 通过、2 失败；修复释放后的迟到结果仍创建通知计时器后，请求池文件重跑 13 例通过，其余先前通过用例未扩大重跑。
- `flutter analyze lib` 及新增缓存测试文件：无问题。Python media scope 路由/防止首帧与动图假通过的定向检查 2 例通过。
- Release：经 `tools/platform` 构建成功。真实媒体专项最终 **UX-11 PASS**，耗时 32.3 秒；真实 FFI、mpv、HEIC、GIF、X11 输入。验证视频首帧就绪、播放位置推进、暂停/恢复、动态照片手动及自动播放、HEIC 像素、GIF 三帧及帧索引推进、移除来源后四个原文件内容哈希不变。报告：`/tmp/photo-performance-media-final-r4-20261022/report.json`。
- 专项初次失败保留在 r1/r2 日志：独立入口未等窗口初始化，以及隔离音频服务不可用。入口现在等待首帧光栅化、空库走既有“打开设置”按钮；仅自动 media scope 使用 OpenAL null 音频输出，仍解码真实视频/音频。此测试不证明扬声器有声。进一步排除 Linux 插件初始 1×1 空纹理后，重新构建并通过专项；渐进媒体 5 例和该文件 analyzer 也重新通过。
- 未执行：真实桌面 GPU/合成效果、滚动 FPS/P95、长期 RSS、大图库完整验收矩阵、远程 CI。

复现真实媒体专项（仅 UX-11，不运行完整矩阵）：

```bash
PHOTO_FLUTTER_ROOT=/home/luyao/.local/share/photo-client/flutter \
  python3 -B tools/ux_journey.py run --scope media --mode release \
  --evidence-dir /tmp/photo-media-verification-unique
```

正常启动最新代码仍使用 `./tools/run_app release --build --background`，读取真实桌面、真实设置和默认图库；不得套用上述自动测试的隔离数据与音频环境。

## 真实环境交付

最终使用 `./tools/run_app release --build --background` 重新构建并在真实 `wayland-0` 会话启动，默认真实图库，无替换 HOME/XDG/data-root，PID `1374890`，日志 `/tmp/photo-client-release.log`。图库有 498 个 active 项；启动后后台按新 Month/Day 策略补充 512 档缓存，256 档保持 498/498、失败 0；随后日志确认 `size=512 total=498 ready=498 failed=0 status=complete`。真实桌面启动和数据库/日志核对不代表已做 GPU 视觉验收。

本轮修改在 `main` 分支提交到本地；未推送。验证范围沿用上述定向检查，未因提交扩大测试范围。
