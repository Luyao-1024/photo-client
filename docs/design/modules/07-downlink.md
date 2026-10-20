# M07 下行与冲突协调

## 职责与范围

可靠接收共享快照和增量，将成对照片投影为结构化义务，协调远端与本地修改。M09 负责字节和可见版本提交；本模块拥有水位推进条件。

## 接口与数据

```text
receive(context, job, budget) -> ReceiveReport
project_round(context, round_id) -> ProjectionReport
can_apply_head(job, round_id) -> ReadyProof | PendingReasons
rebuild_metadata_after_expired_token(job) -> RecoveryPlan
```

ReceiveReport 区分 pages_saved、records_saved、photos_projected、resources_pending、conflicts_pending、ingest_position、applied_position。token 本体不通过常规 UI DTO 展示。

一轮拥有一个 receive_round，bootstrap 的两个类型共享 snapshotToken 和目标 zone token，各自 receive_stream/marker。页保存使用 `(round,stream,page_no)` 与请求游标摘要识别重放，inbox 按页/序号引用 typed record。

## 流程与状态

`Created → Receiving → Projecting → ResourcesPending → Applying → Applied`；可进入 Interrupted/Blocked。流结束与整轮 Applied 分开。

首次：服务端创建共享快照 → 接收 Master 类型各页 → 接收 Asset 类型各页 → 逐照片配对验证 → 安排双资源 → 每张完整后入库 → 检查全部义务 → 推进 appliedToken。

不等待整库资源完成才展示已完整的照片。Master 先到时只保存 pending record；Asset 先到/缺引用也不伪造照片。页面的记录和 marker 在同一个 SQL 事务保存，提交后才请求下一页。

增量：从已持久接收位置读取固定水位页，墓碑与活跃记录都入 inbox。元数据更新不安排无变化资源；内容变化只准备缺失或不匹配的资源；已验证本地资源通过明确摘要/代际证据复用，mtime 或任意 ETag 不作内容等价证明。

ingestToken 表示已可靠保存的协议位置；未结束分页的中间位置不能用于上行门槛。appliedToken 只在该固定水位的页完整、inbox 已投影、明确范围内发布/资源/冲突结算后推进。云端不透明 token 由网关与服务器解释，不按字符串大小比较。

## 合并与冲突决定

| 状况 | 处理 |
|---|---|
| 本地 clean，远端元数据变化 | 原子更新 desired 与 confirmed；资源不变 |
| 本地 dirty，远端仍为旧 baseline | 保留本地类别义务，更新可确认的不冲突事实 |
| 同身份同类别双端变化 | 按事件 `(time_ms,source,event_id)` 决定；内容败方完整字节进入受保护冲突版本 |
| 不同身份占用同逻辑路径 | 保存 PathIdentityConflict，不合并照片 ID、不覆盖 |
| 远端删除，本地 clean | 可见性撤下，记录 retired；旧完整文件按引用策略回收 |
| 远端删除，本地有未确认修改 | 按删除/内容事件协调，保护本地版本；无法证明安全时阻塞该 entry |
| isHidden=true | 首版不普通展示；记录已知的非公开状态，不自动取消隐藏 |
| isTrashed=true | 首版图库排除，保留资源及身份；兼容旅程未通过前阻止相关上行 |

隐藏/回收站作为已知受限可见状态可以完成协议投影；不需要向普通图库公开它们。对应资源若未下载，应按明确的“首版普通图库下载范围”记录 excluded_policy，不冒充 LocalReady 或 Synced。上行门槛声明该范围，并验证无未解决冲突；不能借此排除用户已选择但失败的普通照片。

不认识的记录类型、字段类型或必需引用形状为 UnsupportedRecord，阻止整轮 Applied，并保留可重新读取的位置。单条不受支持不可被静默跳过。

## 异常与恢复

进程退出后从已提交 stream marker 恢复；若 token 过期，废弃本轮接收游标并建立新快照，保留 dirty、已发出操作、完整本地版本、发布与冲突证据。旧 pending record 只在新快照已能接管义务后回收。

database_generation 变化不使用旧 receipts 或 cloud revisions 写新库；转为 ScopeChanged，保留本地完整副本，要求明确的重建关系流程（首版只提示，不自动重新上传全部照片）。

## 验收

- T07-01：分页期间新变化不混入当前快照，两个类型共享水位。
- T07-02：重复页不重复投影，半页失败不推进游标。
- T07-03：一个资源完成不能可见或推进 applied；已完成照片逐张展示。
- T07-04：并发收藏/内容/删除事件与路径身份冲突不漏本地修改。
- T07-05：token 过期保留 dirty/issued；未知类型不虚报完整。
- T07-06：隐藏/回收站不泄露进普通图库，excluded_policy 不伪装同步完成。
