# M09 资源传输、本地发布与回收

## 职责与范围

拥有资源任务、流式摘要、不可变版本目录、发布意图、读取固定版本和 GC。M07/M08 提供逻辑义务和确认条件，本模块不自行清 dirty 或跳水位。

## 接口与数据

```text
fetch_pair(entry, target, cancel) -> VerifiedVersion
upload_prepared_pair(operation, lease_proof) -> PublishedDescriptors
prepare_publication(context, captured_versions) -> PublicationId
publish(publication_id) -> CommitResult
acquire_media(context, entry_id, purpose) -> MediaLease
release_media(lease_id)
recover_publications(account) / collect_retired_versions(budget)
```

每个 LocalVersionId 是本地 UUID；远端 photo ID 和 contentGeneration 只作数据库字段。版本目录包含受控命名 `original`、`thumbnail.jpg/png` 和受控扩展名，原始显示名不进入物理布局。

规范缩略图与原图放持久目录；256/512/1024 等尺寸衍生缓存放 cache，以 account/entry/localVersion/size/codecVersion 定位。所有路径在受管根校验，不让远端字符串跳出数据根。

## 流程与状态

资源：`Needed → Transferring → Verified → Published`；可 Interrupted/Failed/ExcludedPolicy。照片发布：`Prepared → FilesReady → Promoted → Committed`；失败为 Retryable 或 ConflictProtected。

下载：取新描述/能力 → 同账号同源流式写 `.part` → 校验实际长度和 SHA-256 → 写规范资源 → flush 稳定文件。首版断线后保留已完整校验角色；未验证 part 从头重下，下载 Range 续传可后续独立启用，不能当上传续传。

上传：从稳定受管版本只读 → 预留会话 → 流式上传 → 读取 Published 状态/服务端摘要 → 获取新 descriptor → M08 成对记录提交。服务器验证字节，不以本地 hash 自行宣布 Published。

本地发布顺序：

1. 两角色与尺寸缓存准备完成，检查 entry/配置/本地内容捕获仍匹配。
2. actor 保存 publication_intent，记录新旧版本和预期条件。
3. 所有持久文件完成 flush；staging 版本目录与 final 位于同文件系统。
4. 原子提升到新 UUID 目录并同步父目录；目标已存在时核对既有版本证据，不覆盖。
5. actor 再次检查上下文/类别条件，原子创建或更新 media_items.current_version_id，更新基线/义务并结算 intent。
6. 提交后发 LibraryChanged/SyncChanged；旧目录转 retired 候选，仍有引用时保留。

新远端照片在第 5 步之前没有 media_items 行。已有照片继续显示旧指针。不同 generation 的缩略图与原图不能共用同一个完整版本。

若发布期间用户仅改变收藏，保留新收藏并只提交可兼容的资源变更；若内容或删除类别已变化，不能覆盖用户新版本，转冲突保护。条件兼容规则由 actor 明确判断，不只检查一个总版本号。

## 读取与 GC

MediaLease 固定 LocalVersionId 和本地路径，引用计数位于 Engine 内。Flutter 图像 provider 必须让句柄覆盖加载、解码、ImageCache 存活及 viewer 使用期；解除 provider 时先处理在途读取，再释放，不能 widget build 一次后立刻释放。

GC 仅回收无当前指针、无 confirmed/issued/resource/publication/conflict 引用、无活跃 MediaLease 的 retired 版本；保留至少 24 小时宽限。账号切换释放 UI 旧句柄；进程退出清理内存 pin，下一进程先完成恢复再 GC。

删除失败保留目录和 cleanup_error，稍后重试；不能通过清 DB 行来“解决”Windows 文件占用。缓存可先淘汰，不把仍被引用的规范原图当缓存处理。

## 异常与恢复

| 崩溃位置 | 次启处理 |
|---|---|
| intent 前，仅 staging | 有 import/resource ownership 则续做；无归属且超宽限才清理 |
| intent 已存、未提升 | 检查 Verified 文件，恢复提升或保留旧指针并报错 |
| 已提升、未 SQL 提交 | 按持久捕获重新校验；合法则提交，否则保护为冲突/待办 |
| SQL 已提交、事件未发 | 指针是事实；重启快照恢复展示，intent 幂等结算 |
| 文件被外部删除 | 可见条目标为 RepairRequired，不虚报 Synced，安排明确修复 |

空间不足停止准备新资源，不删除当前完整版本腾空间。摘要错误隔离损坏 part，并有界重取；重复失败保留安全错误码。

## 验收

- T09-01：任一角色缺失/摘要错/代际错都不能发布。
- T09-02：逐个崩溃窗口恢复，更新失败保持旧完整指针。
- T09-03：Flutter/核心持有旧版本时 GC 不删除，释放后可回收。
- T09-04：缓存清理、文件缺失、磁盘满、提升失败都不产生假完成。
- T09-05：已验证资源复用不重复下载，未验证 part 不冒充完成。
