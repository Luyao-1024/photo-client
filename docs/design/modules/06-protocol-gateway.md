# M06 SyncServer 网关

## 职责与范围

`syncserver-client` 只负责 HTTP、wire DTO、服务端能力映射和错误归一，不引用 SQLite、Flutter、图库实体或调度器。

协议来源为[服务端契约索引](../README.md#协议所有权)。这里命名的 Rust 接口是客户端抽象，不另定义 HTTP 路由或字段。

## 接口与数据

```text
AuthGateway.login/logout
SyncGateway.capabilities/list_zones/snapshot/query_type/zone_changes
SyncGateway.acquire/renew/check_progress/advance_phase/release
SyncGateway.modify/operation_status
AssetGateway.reserve_upload/session_status/upload/describe/download
UsageGateway.storage_usage
```

输入为 TypedEndpoint、SessionProvider、PinnedScope、ZoneRef、操作请求和 CancellationToken。身份 token 由会话提供器注入，不让调用方自由指定其他账号 Authorization。

返回 ParsedResponse<T> 包含请求诊断 ID、HTTP 状态、逐项/逐 zone 业务结果、限额和服务端时间（适用时）。不能以 HTTP 200 覆盖元素错误。摘要在边界转换为 `Sha256([u8;32])`，DB 采用规范 hex；Base64 仅 wire/typed BYTES 字段使用。

请求默认控制 JSON 上限 1 MiB，并与探测能力的上限取较小值；响应按已知接口设有界上限，超限不落无界缓冲。资源 body 流式传递，不转换为完整 Vec。

## 流程与状态

连接：验证 origin → 认证 → 检查 service/protocol/checksum/用户权限 → 建立 pinned scope → 选择 zone。后续响应不能悄悄覆盖已固定身份或 database_generation。

控制请求默认连接 10 秒、单次 30 秒；资源传输使用连接超时、无进度超时和调用方剩余预算，不给所有大文件强加同一个 30 秒总时限。保活单独控制通道，不被原图并发槽占满。

请求按类型区分：读操作可本轮最多 2 次延迟重试；逻辑写入由 M08 的已发出操作与会话状态决定重试，HTTP 层不自动重发。429/503 尊重有界 Retry-After 和轮次剩余预算。401 不自动重放密码登录。

签名资源 URL 必须同配置 origin；拒绝跨源/重定向与混用账号。租约证明只发送至合同要求的接口，不出现在 debug URL。TLS 证书验证默认启用，不提供首版“忽略证书”开关。

查询 token、marker、revision 各有包装类型。不能把空字符串当最后页 marker；不能把 database token 当 zone appliedToken。解析未知可选 DTO 成员可兼容，已知枚举/必需字段不认识则报 ProtocolUnsupported。

## 适配决策

required capabilities 来自迁移后的类型映射，功能按版本与 capability bit 双重校验；不按 stage 文本推断能力。管理员得到明确的 NoPhotoLibrary。

资源描述的 URL/receipt 可过期，只驻留内存；持久状态记录 asset_id、角色、摘要、大小和会话 ID。重建 wire 请求时重新获取临时证据，逻辑幂等内容保持不变。

storage_usage 仅当前账号，按服务端分类显示；调用方不能传任意 user_id 查询另一账户。服务端 unavailable 与本地空间不足是不同错误。

## 异常与恢复

错误保留 HTTP/服务端 code、条目定位与 retry_action，不保留原始 body 或 URL。UnknownOperation 不等于“肯定未写入”；M08 按操作状态与资产会话进一步核对。

过期 token 进入 M07 的保留本地义务重建流程；generation 改变进入 ScopeChanged。版本冲突进入协调，不在网关实现最后写入覆盖。

## 验收

- T06-01：HTTP 200 中逐项失败正确分发，未知必需字段/类型不误认成功。
- T06-02：跨源 URL、重定向、错账号能力被拒绝且无凭证泄漏。
- T06-03：写请求无传输层盲重试，读重试有次数和时间上限。
- T06-04：摘要编码、token 类型、能力/管理员边界符合当前服务端。
