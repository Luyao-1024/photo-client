# M05 数据库与事务

## 职责与范围

拥有 `client.sqlite`、schema 迁移、单 writer actor、短读快照、索引与结构化恢复证据。设计结构以[SQL 合同](../contracts/local-schema.sql)为准；本模块解释语义，不复制另一份 DDL。

## 接口与数据

```text
Store.open(data_root) -> DbActor + ReadStore
DbActor.execute(Context, DbCommand) -> {db_revision, outcome}
ReadStore.query(AccountReadContext, QuerySpec) -> Page/Snapshot
Store.migrate(from, to) / verify_integrity()
```

| 表组 | 主要数据 |
|---|---|
| app_meta / schema_migrations / app_settings | schema、db_revision、device_id、当前账户、同步总开关 |
| accounts / credential_intents | 服务器用户身份、会话引用、跨系统凭证补偿 |
| jobs / job_capabilities / job_limits | pinned scope、配置代际、暂停、允许范围、实际接受的能力/上限 |
| job_config_intents / job_config_sources | 已接受但尚未生效的配置及来源集合，崩溃后安全继续 |
| media_sources / job_scope_sources / source_assets | 授权来源、显式范围、来源对象与受管 entry 对应 |
| sync_entries / entry_confirmed | desired 元数据、cloud 身份、dirty 与类别版本、已确认基线 |
| media_versions / media_items | 不可变资源版本和当前可见指针；未完整远端照片没有 media_items 行 |
| library_groups / library_memberships | 事务内维护的可重建窄读投影，根组/收藏/路径子树不全库扫描 |
| import_batches / import_items | 用户已接受的导入、逐项复制/准备状态；不是第二份 dirty |
| record_sets / sync_records / record_fields / record_list_values / record_assets / record_events | 接收、已发出和冲突所需记录的有类型结构，不落 JSON |
| receive_rounds / receive_streams / receive_pages / inbox_events / sync_progress | 共享快照、页事务、投影、ingest/applied |
| resource_work / issued_operations / issued_record_actions / issued_item_results | 字节传输义务、逻辑请求身份与未知结果 |
| publication_intents / conflicts | 本地版本提交意图、保护的冲突版本与决策 |
| runs / command_receipts | 轮次结果、UI 修改幂等确认 |

所有账户内容表以 account_id 组成主键/外键；entry 所属 job 不可被同账号其他 job 冒用。ReadStore 不暴露接收原始 SQL 的 UI 接口。账户列表只返回无内容摘要。

sync_entries.dirty_kind 为 clean/create/modify/delete，只是派生缓存；类别 local/ack 版本及本地删除意图是事实。每个变更/确认事务同时重算 dirty_kind。未允许上传且尚无云端身份的本地副本保持 upload_enrolled=0，不产生云端义务；dirty 推导必须包含此条件。不得出现“更新 dirty 但没版本证据”。SQL CHECK 管理值域，actor 管理跨字段业务一致性。

## 流程与状态

打开：取得根锁 → SQLite STRICT tables / WAL / foreign_keys=ON / synchronous=FULL → 检查版本 → 迁移事务 → foreign_key_check → 恢复命令。每个连接启用外键；只读连接不参与写入。

writer 队列上限 256，交互/恢复/同步分类调度；最多连续处理 16 个交互命令后让出给等待的同步命令。队列满返回 Busy，可取消等候，不在 Flutter 主线程等待。短读超时与结果页有界，禁止长读事务覆盖网络周期。

每次有效写事务递增 db_revision，并把同事务产生的领域事件写入内存提交结果；事务结束后才发布事件。进程在提交后事件发布前退出，重启全量摘要可恢复，事件流不承担唯一持久事实。

关键事务：

| 命令 | 原子写入 |
|---|---|
| AcceptAccount / SelectAccount | 账户引用、job、当前账号；凭证本体由补偿流程管理 |
| SetFavorite / AcceptScope | desired 值、类别版本/事件、配置意图/目标代际（仅范围变更）、command_receipt |
| SaveReceivePage | 页面、类型化记录、inbox、stream marker、可靠接收位置 |
| ProjectRemoteEntry | 成对校验后的待办、冲突决定、元数据合并；不清并发本地义务 |
| PrepareIssuedOperation | UUID、捕获版本、逻辑请求、资源会话身份，先于网络发出 |
| ConfirmOperation | 完整服务端结果、身份/基线、匹配类别 ack、dirty 重算 |
| PreparePublication | 新旧版本、预期类别/配置、文件发布意图 |
| CommitPublication | 可见指针、已确认资源状态、发布结算、待办完成、必要进度推进 |

网络、哈希、图像处理、SecretStore 和 fsync 都不在 SQLite 事务里等待。文件先完成 durable 准备，后提交数据库；依赖发布意图跨越两者的崩溃窗口。

## 索引和分页

SQL 合同包含账号/云端 photo 和 master 唯一索引、job/dirty、资源状态、发布 entry/state、接收 record 关联以及图库排序索引。

首屏使用 `library_memberships` 的组/排序复合索引；收藏有独立favorite前缀索引，路径子树用祖先组成员关系，不靠扫描字符串LIKE后再排序。当前可见性/收藏/排序变化与投影计数在同一个actor事务更新。普通窗口用键集读取，任意rank跳转由M16原生窄索引提供ID，再按主键批取。展示总数与同步总数分别查询，禁止把“有 media_items 行”直接计为云端完成。

schema_migrations 是新客户端自身单调版本链。升级前检查可恢复备份空间，使用 SQLite backup API 生成一致性备份；不复制正在写的裸 DB 文件。迁移失败回滚，保留备份；较新 schema 拒绝旧二进制写入。数据损坏不自动清库或表重建。

## 证据保留与清理

已确认issued完整证据至少保留7天，且无恢复/冲突/发布引用后才按子表→请求/结果set→operation顺序清理；清理必须先解除外键引用。接收轮Applied并无资源/冲突引用后保留24小时诊断宽限，再清页/inbox/typed记录。未结算证据不因时间到期删除。

runs摘要保留30天且先确认无issued引用；command_receipts至少30天，过期重发仍受expected版本限制。退休身份与墓碑revision保存在sync_entries，不复用；远端删除结算后可释放entry_confirmed资源指针，旧文件再按M09回收。冲突保护版本不自动按时间删除。

## 异常与恢复

SQLITE_BUSY 本轮少量有界重试，耗尽报告 Busy；SQLITE_FULL/IOERR 停止新写并保持已有媒体版本。提交结果未知时按 command_id 或 operation_id 查询事实，不能盲目重复变更。

record_fields 接受已知 wire 类型及客户端内部 DELETE_FIELD 标记；后者仅用于 update 补丁的 null 删除，与字段缺省不同，不能出现在接收完整记录。record_events 保存每条记录的类别事件；issued_record_actions 固定操作顺序/动作/条件版本，确保在本地后续编辑后仍能重建原请求。

record_fields 只接受已知 wire 类型。未知类型保留可诊断身份、停止该页进度，升级后可重取；不把任意对象塞进 TEXT/BLOB 作为回退。

## 验收

- T05-01：跨账户/跨 job 外键被拒绝，账户内容查询强制作用域。
- T05-02：页事务失败回滚 marker 和所有行；确认事务不清后来的版本。
- T05-03：schema 迁移失败保留原库；较新版本拒绝旧客户端。
- T05-04：图库分页、dirty、资源、发布查询计划使用相应索引。
- T05-05：存储契约无 JSON/BLOB 文档列，typed 标量和列表可重建逻辑请求。
