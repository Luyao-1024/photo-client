# M04 账号与会话

## 职责与范围

拥有登录草稿、服务身份验证、会话凭证引用、当前账号选择与重新登录。仅普通照片账号建立同步关系。首版不提供注册、管理员控制台或密码管理。

## 接口与数据

```text
begin_login(endpoint, username, password) -> LoginDraftSummary + draft_id
accept_login(draft_id, zone, upload_scope) -> AccountSummary + Context
discard_login(draft_id)
switch_account(account_id, expected_epoch) -> Context
reauthenticate(account_id, username, password)
sign_out(account_id) -> SignOutReport
list_accounts() / get_current_account()
```

LoginDraftSummary 仅含 endpoint、user_id/显示用户名、可用 zone 和能力摘要；不返回 token/password。草稿 secret 存 Rust 内存，短时过期或取消后释放。不得声称 Dart 输入字符串可以完全零化；保证不持久化、不日志和不放入错误对象。

账户唯一键 endpoint_origin + remote_user_id；用户名可变化。连接 pinned scope 独立存 namespace、zone/owner、database_generation、协议版本、能力和限额。credentials_ref 唯一，不复用其他用户的会话。

## 流程与状态

账户在线状态为 SignedOut / Authenticated / Expired / Revoked / CapabilityBlocked；选择状态和同步运行状态独立。已保存身份可保留离线图库，任何网络访问仍需有效会话。

登录：规范化 origin → 登录 → 同会话能力探测 → 验证身份/照片权限/zone → 暂存草稿 → 用户接受 → 保存凭证 → actor 提交账户与 job 配置 → 激活当前上下文。取消草稿不切换账户、不暂停旧任务。

凭证服务与 SQLite 不是单个事务。提交前将拟写凭证引用登记到 `credential_intents`，随后写 SecretStore，再在 actor 中绑定 reference 并关闭意图。崩溃后根据意图与真实账户引用判定绑定完成或清理孤儿；不枚举删除其他应用凭证。SecretStore 写成功但 DB 失败必须有可重试清理证据。

接受首个账号默认“仅接收”；范围可为none、明确来源或全部受管照片(all_managed)，后者也包含已接收的云端照片。只有接受范围后才允许对应照片的新建/修改上行；受管导入批准会通过配置事务登记来源与范围。旧草稿身份或 pinned generation 发生变化时重新验证，不能默默接受。

切换先安全停止旧账户的新准入；已发出操作保留在旧账户分区，可在再次使用旧账户时核对。旧租约最佳努力释放，失败不能解释为释放已确认。选中账号和 epoch 变更后再加载新图库，UI 清空旧选择/预览/查询缓存。

重新登录必须核对 remote_user_id 与原连接相同，成功后通过凭证意图切换引用并废弃旧会话。身份不符保持旧配置，返回 IdentityMismatch。

退出登录停止该账号运行、撤销远端会话（有界最佳努力）并删除本地凭证，保留本地照片与义务，标记 SignedOut。远端撤销结果未知必须如实记录；本地禁用会话先于发出后续请求。首版不开放删除账号数据或自动转移照片到另一账户。

## 安全边界

默认 HTTPS；literal loopback HTTP 只用于明确开发 profile。拒绝 URL userinfo、路径前缀、query/fragment 和跨源重定向。资源请求同时使用正确账号 Bearer 与能力，token 不进入页面路由或 SQLite。

会话到期没有自造 refresh-token 流程；进入需重新登录。密码只用于本次登录。离线不显示已验证在线成功，不因凭证服务临时锁定清空历史。

## 异常与恢复

认证失败不区分未知用户/错误密码；网络失败保留登录草稿可编辑但不自动重发密码。服务代际变化进入 ScopeChanged，暂停在线写入，保留本地数据和 issued 证据，由重新建基线流程处理。

凭证删除失败留下 `credential_intents` 清理义务；UI 显示本地已停止会话，不能重新启用该 reference。切换中的最新有效选择可覆盖旧选择请求，旧结果不更新 UI。

## 验收

- T04-01：取消/失败登录不影响旧账户与运行。
- T04-02：同 endpoint 不同用户完全隔离，重登身份不符拒绝。
- T04-03：凭证写与 DB 提交各崩溃窗口可恢复，无明文持久化。
- T04-04：切换/退出后迟到网络响应无权修改新账户。
- T04-05：管理员登录成功仍不能创建照片同步 job。
