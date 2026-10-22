# M08 上行与租约

## 职责与范围

从 sync_entries 推导上行任务，管理租约、保活、阶段、已发出操作、回执恢复与有效成功确认。当前 UI 产生 create、favorite/回收站 metadata 修改、内容替换、路径修改与 delete；绑定照片的编辑、改名、移动、回收站/恢复和永久删除都进入上行义务，没有只读限制。

## 接口与数据

```text
run_uplink(context, job, budget) -> UplinkReport
reconcile_issued(context, operation_id) -> KnownResult | StillUnknown
prepare_operation(entry, captured_versions) -> PersistedOperation
confirm_operation(CurrentProof, ResultEvidence) -> ConfirmationOutcome
```

CurrentProof 包括当前账户/配置/轮次、有效租约保守期限、已验证门槛和类别版本；RecoveryProof 额外要求旧请求身份、完整服务端结果与当前有效轮次重新准入。旧租约失效后的晚响应不能直接作为恢复证明。

资源准备先保存 PreparingAssets 意图与稳定 operation_id/版本捕获；资源描述齐备后将完整 request_set、顺序动作、条件 revision、类别事件和 canonical hash 原子冻结为 Prepared。只有此后才能发出 records/modify。PreparingAssets 仍不是“记录变更已发出”；上传会话身份另行持久保存并查询。

已发出操作保存 operation_id、atomic=true、规范逻辑请求结构、request_hash、捕获类别版本/事件、准备的本地版本、phase 与资源会话 ID。leaseToken、临时 URL、临时 receipt 不持久保存。

## 流程与状态

轮次：`Receiving → Acquiring → CatchingUp → Freezing → Delete → Modify → Create → Settling → Completed/Partial/Deferred`。任意失锁进入不可逆 Aborted。

1. 正常下行并结算本轮范围内发布/冲突。
2. 获取租约一次；失败本轮上行跳过，保留 dirty，不抢锁循环。
3. 独立保活；持锁检查 appliedToken 与服务器进度。落后则继续持锁下行，完成后重检。
4. 检查本地 ReadyProof，冻结本轮合资格 entry/版本视图；快照只在内存，不另建 dirty 队列。
5. 优先核对既有 issued 结果。确认“未知结果”已解决后，才允许为相同义务创建新 operation_id。
6. 按 delete→modify→create 前进，服务端和本地阶段都验证；本轮不倒退到已结束阶段。
7. 准备结构化 issued 事务先于发出请求；逐项解析完整原子结果。
8. actor 比较当前 proof/版本，确认匹配类别的 ack，重算 dirty。后来的修改保持 pending。
9. 释放租约，记录完整/部分/延后；剩余义务交 M14 决定续批。

批次先沿用最多 5 张带资源照片、20 张纯元数据/删除的预算；同时服从服务端 maxOperations，成对照片所需记录数单独计算。8 个成功批次后让出调度；遇失败/延期不自旋。

首版每次新轮次重新完成下行门槛，不直接把 modify 响应中的服务器最新 token 当作 appliedToken。后续如优化 AdoptConfirmedHead，须单独证明整批/整轮已确认且无未处理变化，再修改设计和验收。

## 上传准备与类别规则

- create/content-change 在导入或接收阶段已准备同源规范缩略图；内容替换上行先校验当前受管原图与缩略图，摘要必须与冻结的 operation 一致，不一致则放弃操作并重新捕获，不临时解码原图补缩略图。
- 缺少规范缩略图为 Deferred，保留 dirty、不创建 issued、不记单项业务失败、不消耗资源照片名额；转交本地媒体修复。
- favorite/回收站/恢复元数据修改不读原图、不上传资源、不更新 contentGeneration；仅收藏或回收站变化不重写云端路径。
- 改名/移动相册更新云端相对路径；路径由来源/相册与安全文件名重新计算，并随元数据操作携带。
- 纯删除不要求缩略图；照片两记录的原子删除形状仍由服务端合同决定。永久删除在确认前保留本地墓碑（dirty=4）和绑定，远端已不存在同样视为完成。
- Prepared 状态且有持久“不曾发出”证据可放弃后重新准备；一旦进入 Dispatched，即便无响应也视为可能提交。

## 异常与恢复

明确失锁或保守期限到达：取消在途正文和后续准备，所有未完成项 LeaseLost，不清 dirty；已确认成功不回滚。保活网络超时不延长权限。

单项配额、资源或版本问题记录在 entry，当前 run 后续不重复处理该项，独立照片继续。401、scope mismatch、lease/protocol failure 为轮次错误。

响应未知：通过无须租约的提交事实/会话状态读取核对，但本地清义务必须在当前合法上下文以 RecoveryProof 提交。未找到 receipt 不能单凭这一点重建 operation_id；同一逻辑请求在合法新租约下重放时保持原 UUID，并按服务端幂等合同刷新临时证明。

本地版本变化后仍可登记旧操作成功的云端身份/基线；只 ack 捕获的版本，不清新版本。旧 config 的未知结果保存到原 job，不拿它直接改新范围或另一个账号。

## 验收

- T08-01：双设备仅一方上行；获取失败不清 dirty 或本轮抢锁。
- T08-02：锁内补拉/保活/阶段顺序正确，downlink 不被 namespace 租约阻塞。
- T08-03：响应丢失重启核对同 UUID；旧 fence 晚响应不确认。
- T08-04：上传时新收藏修改保留；原子结果缺项/逐项失败不报成功。
- T08-05：单图失败隔离，缺缩略图 deferred 不占批次。
- T08-06：元数据修改无文件上传，批次/记录预算准确。
- T08-07：内容替换冻结 generation/摘要，上传期间的新编辑不被旧确认清零。
- T08-08：永久删除保留墓碑直到 Delete 确认，远端已不存在也完成清理。
