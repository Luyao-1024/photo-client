# M12 FFI 与事件合同

## 职责与范围

将 Rust 服务整理成稳定、异步、可取消的 Flutter API。bridge 只映射 DTO/错误和句柄，不实现 SQL、HTTP、dirty 或平台权限策略。

拟定 API 分为 BootstrapApi、AccountApi、LibraryApi、SyncApi、ImportApi、MediaApi、BrowseApi、AppearanceApi、DiagnosticsApi；具体方法分别来自所属模块，桥接层不扩大权限。

## 接口与数据

```text
initialize(BootstrapInput) -> BootstrapSnapshot
subscribe(SubscriptionFilter) -> {subscription_id, snapshot, event_stream}
command(CommandEnvelope) -> CommandResult
cancel_request(request_id) -> CancellationAcknowledgement
close_subscription(subscription_id)
shutdown(deadline)
```

协议版本首个为 1；Dart/Rust build_profile 摘要与 bridge_protocol_version 在初始化时核对。FRB 生成绑定随应用同版本交付，不承诺任意新旧动态库混配。

CommandEnvelope：request_id、Context、command_id（修改命令必需）、typed payload。结果含 Context、db_revision、typed outcome。ID 传字符串；计数/版本传经范围校验的整数；日期 UTC 毫秒由 Dart 转本地显示。

错误 DTO：code、category、retry_action、message_key、typed args、diagnostic_id；可选 entry/job。取消与过时上下文不混入普通单图失败提示。accessToken、密码、leaseToken、签名 URL 和数据库路径不进入通用 DTO/事件。

MediaLeaseDTO 可返回受管本地路径，这是给媒体 provider 的受限接口；不将绝对路径塞入常规图库列表。缩略图/原图不按全文件 Vec 跨 FFI 传输。M16的十万项窄键索引停留Rust，BrowseApi仅返回最多200项窗口和小型计数；AppearanceApi通过全局偏好提交材质设置，与账号同步配置分离。非路径平台来源通过 M03 Reader 消化成受管资源再显示。

## 流程与状态

订阅建立采用 actor barrier：先登记订阅与 revision 边界，再生成同边界快照，缓存边界之后事件，交付快照后按序放行。避免“先查后订阅”漏掉中间提交。

事件 envelope：process_id、subscription_id、event_seq、Context?、db_revision、kind、payload。event_seq 每个订阅单调递增；不当作服务器 cursor 或业务版本。

| kind | 内容与消费 |
|---|---|
| RuntimeChanged | 初始化、恢复、退出状态 |
| AccountChanged / CapabilitiesChanged | 清理旧账号页面状态、能力重新评估 |
| LibraryChanged | entry IDs 有界列表或 query_invalidated；UI 合并重查 |
| SyncChanged | 当前 job 状态/计数失效，不携带全库条目 |
| ImportChanged | batch/逐项摘要 |
| DiagnosticNotice | 安全错误码和诊断 ID |
| ResyncRequired | 消费太慢或丢事件；重新取 snapshot，不猜测缺失变化 |

队列上限 256。进度/计数失效事件按主题合并；不可丢的账号/生命周期边界在过载时以 ResyncRequired 替代并暂停增量投递，直到客户端重订阅。丢订阅不会丢持久状态。

## 取消与资源所有权

取消确认只表示“已收到停止请求”；已提交事务仍可能返回 Committed，已发出网络请求可能 UnknownResult。Dart 不把超时统一转为失败然后无条件重放。

Dart provider 对订阅、query_session、MediaLease 负责 release；Rust 句柄校验 process/epoch，禁止整数伪造句柄跨进程复用。账户切换先使旧句柄不可用于新查询，已有文件读取按 M09 释放，不能返回新账号数据。

编解码 provider 保持 lease 覆盖缓存与在途解码，LRU 淘汰后释放。shutdown 先取消订阅/请求，再关闭 Engine，不由 GC 的不确定时机完成正式退出。

## 异常与恢复

FFI panic 转 Internal 并记录诊断 ID；actor 无法继续时 RuntimeChanged=Failed，禁止继续 mutation。事件流断开 UI 进入重新连接/重取快照，不无限旋转重连。

FRB API 签名的实际生成能力在 L0 spike 验证；如 trait/stream 类型不被生成器直接支持，保留本合同语义并通过薄包装实现，不能让生成器限制改变同步确认规则。

## 验收

- T12-01：快照与订阅竞态不漏提交，溢出触发重同步。
- T12-02：旧 epoch 查询/句柄/事件不更新当前页面。
- T12-03：取消前后提交结果准确，command_id 防止重复修改。
- T12-04：媒体句柄和订阅释放可计数，无全库/原图大对象过桥。
