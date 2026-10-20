# M11 图库查询与照片操作

## 职责与范围

提供可见照片、路径分组、查看器顺序、收藏和同步摘要。图库是受管完整副本的视图，不通过滚动或点击触发远端原图下载。

## 接口与数据

```text
query_library(context, filter, order, cursor?, limit) -> LibraryPage
query_groups(context, parent_path?, cursor?, limit) -> GroupPage
get_photo(context, entry_id) -> PhotoDetails
navigate(context, query_session, anchor_id, direction) -> PhotoSummary?
set_favorite(context, command_id, entry_id, expected_metadata_version, value)
get_sync_overview(context) -> SyncOverview
acquire_media(context, entry_id, size_or_original) -> MediaLease
```

PhotoSummary 含 account/entry ID、显示名、逻辑路径、拍摄/排序时间、favorite、LocalVersionId、metadata_version、local_availability、sync_badge；不返回远端 URL/token。PhotoDetails 增加原图尺寸、MIME、大小、来源摘要和可用操作。

filter 首版为全部/收藏/逻辑路径前缀；不开放任意 SQL 条件。limit 默认 100，最大 200。10万规模的 `open_browse_query/query_window/seek` 由M16补充，普通分页API与其共用同一读投影和过滤语义。prefix 按路径段匹配，`Trip` 不匹配 `Trips`；路径在协议层验证但不按操作系统自动大小写折叠。

## 流程与状态

可见集合必须有 media_items 指针、完整本地版本，且 desired_hidden=false、desired_trashed=false、desired_deleted=false。RepairRequired 可在故障状态展示明确不可读标记，但不能出现在正常完成计数中。

排序使用稳定 `(sort_time_ms, entry_id)`；无拍摄时间时采用首次导入/接收确定的时间，不在每次查询使用 now。cursor 包含账户/epoch/filter/order/anchor/query_id/view_revision，成员/排序改变后的过时请求返回 PageInvalidated；纯不影响排序的图标更新不使整库失效，UI 保留 anchor 并重读当前窗口，不能拼接不同查询的页。

query_session 不持有跨网络的 SQLite 读事务。查看器相邻导航沿同 filter/order 重新查询；anchor 被移除则找临近排序项，集合空则返回图库。当前展示 EntryId 与键盘导航目标分开，避免迟到解码显示错图。

can_favorite 由当前照片允许上行范围决定；仅接收或未覆盖照片时该操作不可用，并说明需调整允许范围，不产生无法同步却伪装成功的收藏。已允许范围即使离线仍可编辑并保留待办。

收藏先提交 actor，再更新 UI；可采用 pending 视觉，但失败回滚该 command 的临时态，不能改已提交事实。重复 command_id + 同输入返回原结果；不同输入重用同 ID 返回 CommandConflict。版本不符返回 StaleEntry 并刷新，不盲目 toggle 两次。

路径分组为 logical_path 的目录投影，空根以“未分组”显示。没有独立云端 album ID，不把本地展开/顺序偏好上传为相册协议。

## 计数语义

| 字段 | 条件 |
|---|---|
| visible_photos | 当前普通图库可见的完整/明确修复条目 |
| local_ready | 完整当前副本实际可读；与云端状态独立 |
| synced | 已确认身份与 generation、无类别义务、资源/发布/冲突未结算数为零 |
| pending_upload | 已授权上传且仍有未确认本地义务 |
| pending_download | 普通图库范围内缺资源或发布尚未结算 |
| deferred/failed | 有明确延后/失败原因，不能加进 synced |
| excluded_policy | 已知隐藏/回收站等不在首版普通下载范围；独立展示，不算 LocalReady |

计数使用已验证且未观察到失效的持久证据，不在每次查询中同步stat/哈希十万份文件；后台分批检查和读取失败会提交RepairRequired并纠正计数。

一张照片可有本地完整版本同时 pending_upload，不将各桶直接相加作为总数。可见/收藏/分组计数增量维护，overview 以一个短读快照生成，UI 不通过逐行 badge 自行累加全库。

## 异常与恢复

读取文件缺失提交 RepairRequired 的受控命令，先验证捕获 LocalVersionId 仍为当前，防止旧读取失败污染新版本。缩略图缓存缺失走本地重建，规范资源缺失才影响完整性。

隐藏/回收站/永久删除/改名/导出 UI 首版无入口；云端已知状态按 M07 接收。只有明确后续设计才能开放本地移除副本，不能让用户误以为删除本地文件等于删除云端。

## 验收

- T11-01：键集分页无稳定集合下的遗漏/重复，旧 cursor/账号结果被拒绝。
- T11-02：收藏命令幂等且版本校验，后来的修改不被旧结果覆盖。
- T11-03：路径段分组、稳定排序、查看器相邻导航与空集合一致。
- T11-04：LocalReady 与 Synced/Excluded/Deferred 计数互不冒充。
