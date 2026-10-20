# M16 十万张图库性能设计

## 职责与范围

把“10 万张以内浏览流畅”落实为架构约束、预算和可测门槛，按 **100,000 张**边界样本验收。拥有 BrowseIndex、窗口请求优先级、数据/解码缓存预算及性能指标；不改变同步正确性。

该模块在[开发计划](../development-plan.md)的S04设前置性能门槛，S13按功能候选重新完整验收；不能将前置夹具原型成绩转记为最终产品结果。

该模块与 M17 液态玻璃联合验收：默认玻璃模式也必须满足滚动指标，不能只测关闭效果后的性能。

## 接口与数据

```text
open_browse_query(context, filter, order) -> QueryHandle + InitialWindow
query_window(query_id, start_rank, count, basis_revision) -> WindowResult
seek_to_entry / seek_to_rank / seek_to_date(query_id, target)
apply_library_delta(committed_revision, changes) -> IndexRevision
update_viewport(query_id, range, velocity, request_generation)
performance_snapshot() -> Timings + CacheCounters + BudgetUse
```

QueryHandle 含总项数、查询代际、索引就绪状态和锚点，不携带全库照片对象。UI 最多持有 2,000 个 PhotoSummary；Rust 原生窄索引只保存 UUID/排序键，单活动查询与一个短时旧查询总预算 16 MiB。内存索引不是同步持久状态。

## 流程与状态

### 1. 查询投影与任意位置跳转

M05 同事务维护 `library_groups` 与 `library_memberships` 读投影：根组和逻辑祖先目录含可见 entry，保存窄排序键和 favorite，索引支持全部/收藏/路径子树。总数增量更新，不每次滚动 COUNT 全库；读投影可从 canonical entries + media_items 重建。

首屏先用数据库索引取 100 项。后台读取同一有界读快照的窄键，建立原生 BrowseIndex；不等全库元数据/缩略图加载完成才显示首屏。100,000 项索引目标 1 秒内就绪，读快照硬预算 2 秒，不跨网络等待。

BrowseIndex 采用排序小块（目标每块 512 keys）和块计数前缀结构：rank 定位、排序键定位和区间取 ID 都有界；插入批合并，块分裂只更新小型目录。禁止用大 OFFSET 实现滚动条跳到第 90,000 张；禁止在 Dart 建立 100,000 个 MediaItem。

有效数据库增量按批更新原生索引，保留当前 anchor EntryId；顺序/成员变化增加 query view_revision，纯图标状态不重建整个索引。构建期间的提交增量有界缓冲，完成后补齐再交换；积压超过 2,000 条则取消旧构建并按新 revision 重建，保持已有窗口可用。

原生索引重建和读投影重建不是每次启动的强制全库扫描；只按必要查询建立窄键，持久投影结构校验失败才后台重建。图库页内全量重新排序或同步读取全库都禁止。

### 2. 虚拟布局和窗口数据

网格使用虚拟 Sliver/Grid builder 与固定比例 cell；总逻辑项数可为 100,000，真正构建/布局的 widget 仅覆盖可见区域和有限 cache extent。不得包成 shrinkWrap 全高度列表，不做整库 IntrinsicHeight、自动逐项尺寸测量或全局 setState。

初始窗口=当前 viewport + 滚动方向最多 1 屏，反方向半屏；慢速可扩到总计最多 4 屏，快速拖动收缩。每帧只采用最新 request_generation，远离 viewport 的排队请求取消，进行中的结果若过时只进入受控缓存，不触发旧 cell 更新。

布局列数变化通过小型几何计算重排当前 viewport，锚定同一 EntryId。照片 cell 以 EntryId/LocalVersionId 为 key，收藏变化只重建对应 cell 和有必要的摘要。

### 3. 缩略图与预取

优先级：当前 viewport > viewer 当前图 > 相邻一屏 > 远端同步/后台修复。只加载本地规范资源/尺寸缓存，不因滚动发原图网络请求。

按 cell 逻辑尺寸×DPR 选择 256/512/1024 尺寸，并传目标解码尺寸；照片角标不用原图采样/逐帧 GPU 回读。高分屏若缓存尺寸不足，先显示可用图，再本地有界提升，不冻结滚动。

内存解码图片 LRU 初始 128 MiB，页面元数据最多 2,000 项；viewer 另有 128 MiB 预算并只保留当前和有限相邻图。codec 总在途预算 192 MiB，单项不超过 128 MiB，最多两 worker；超大图先用已有规范缩略图预览，原图细看须通过预算验证。

磁盘衍生缓存默认总预算 2 GiB，按最近使用和版本淘汰；规范双资源不计入可删缓存。缓存命中只更新内存LRU，不逐次写SQLite；启动时尺寸缓存索引可后台分批扫描恢复，预算未知时暂停非必要缓存写入，仍可读规范缩略图。缓存维护后台增量进行，不在用户滚动时遍历全目录计算大小。

### 4. 与同步、统计和玻璃共享预算

交互活跃时下调后台 codec 至最多 1 worker，暂停无关预取；控制请求/租约保活保留独立通道，不因滚动而丢锁。DB batch 有界，交互短读/写可插入，网络/解码不持数据库事务。

计数来自读投影和提交事件，300ms 合并展示；连续下行不能让每张照片触发全库 count/rebuild。降级只减少特效与预取，不减弱摘要/发布/dirty 确认。

## 性能验收预算

参考环境初步取当前 Fedora x86_64、Ryzen 7 4700G / Renoir 集显、约 16 GiB 物理内存。正式测试另记录磁盘类型、GPU 驱动、分辨率/DPR、显示刷新率和当时空闲内存；本次只核查到硬件，不是性能实测。

统一基准为 release/profile 构建、1440×900 逻辑窗口、DPR=1、60Hz；另测DPR=2、390/800宽度，并按同一60Hz帧/交互门槛单独判断；不能把更大像素负载默默混成同一组。有限支持环境若达不到，须明确修订支持矩阵/效果预算并重验，不静默放宽指标。

| 指标 | 首版目标与测量边界 |
|---|---|
| 首次可操作图库 | 正常 schema/无需大恢复：进程启动到有首屏数据≤2s；热启动≤800ms |
| 数据页 | 100 项窗口 DB+映射 P95≤50ms，不计照片文件读取 |
| 10 万项窄索引 | 后台就绪≤1s目标，UI 首屏不等待它 |
| 快速跳到末段 | 索引就绪后窗口元数据 P95≤100ms，首批已有本地缩略图≤250ms |
| 连续滚动 | 60s脚本×3轮；UI build 与 raster 各自 P95≤16.7ms、P99≤33.3ms；>33.3ms帧占比<1% |
| 输入反馈 | 收藏/导航/暂停可见反馈 P95≤100ms；不得出现>100ms主线程同步任务 |
| 稳态内存 | 浏览10万项RSS目标≤512MiB；并发同步/编解码峰值≤768MiB；另记GPU内存，不隐藏共享显存 |
| 长时间稳定性 | 10min往返滚动/切图/开关设置，缓存暖定后RSS末段增长≤10%，句柄无持续累积 |
| 同步并行 | 后台下行+上传时重复滚动；仍满足交互预算，否则明确回退后台预算并复测 |

FrameTiming 的 buildDuration/rasterDuration 分别评估，totalSpan 含管线等待，不把两阶段简单相加伪造掉帧。长帧占比以内侧 `max(buildDuration,rasterDuration)>33.3ms` 统一统计，另保留totalSpan和平台可用呈现时间；不将该内侧指标直接当成显示器实际掉帧率。截图不能证明滚动性能；平均 FPS 不能掩盖 P99 卡顿。

## 数据集与测量矩阵

数量为 1,000 / 10,000 / 50,000 / 100,000；覆盖根组、稀疏收藏、深目录、日期极不均匀、长中文路径、损坏/缺失缓存和不同宽高比。100,000 条都必须有独立身份/资源路径，足够多样缩略图，不能让全部 tile 共用一个 ImageProvider key 假装命中。

三种缓存条件分开：热内存；应用内存冷但磁盘缓存热；衍生磁盘缓存冷但规范原图/缩略图已就绪。OS page cache 冷测另列且只在隔离环境操作，不能全机清缓存干扰用户会话。

采集第一帧/窗口/解码时序、UI/raster 分布、取消/命中率、worker排队、RSS/显存、SQL计划和慢查询；性能报告连同玻璃模式/自动降级轨迹一起保存。目标失败必须记录，不以小数据量或 debug 体感替代。

## 异常与恢复

索引丢失可重建，canonical 数据不变。读投影重建期间保留旧完整版本或使用当前窗口保守查询；不能清库。预算不足收缩预取与解码并显示本地占位，等待当前请求，不将可见完整照片标同步失败。

## 验收

- T16-01：10万项首屏不全量载入Dart，widget/DTO/查询数量受预算限制。
- T16-02：根组/稀疏收藏/深路径均索引查询，末段跳转无大OFFSET。
- T16-03：60秒多轮滚动的UI/raster分布达标，冷/热缓存分别记录。
- T16-04：同步并行和DPR=2有独立样本，默认玻璃不能漏测。
- T16-05：10分钟操作后内存/句柄有界，无缓存或MediaLease泄漏。
- T16-06：索引构建/增量/重建保持锚点与身份，取消过时请求有效。

## 官方技术依据

本轮已读取官方说明核对惰性sliver和帧计时语义，SDK版本在L0实际锁定：

- `https://api.flutter.dev/flutter/widgets/SliverChildBuilderDelegate-class.html`
- `https://api.flutter.dev/flutter/dart-ui/FrameTiming-class.html`
- `https://docs.flutter.dev/perf/best-practices`
