# 云同步策略与重构前实现对照

日期：2026-10-22。旧实现基线：相邻 `../photoViewer` 的 `ab38626`。本轮对照当前 MVP 已提供的同步路径；缺少的旧产品功能在末节明列，不能据此声称全量功能等价。

| 策略 | 重构前依据 | 当前实现与本轮处理 |
|---|---|---|
| 本地修改与同步义务原子提交 | `core/db.rs::note_sync_change_in`、`sync/store/dirty.rs::mark` | 收藏值、通用 dirty、本地/元数据版本、编辑时间/来源/事件 ID 在同一 actor 事务中更新 |
| 通用操作状态 | `native_dirty`：0 clean、1 new、2 modified、4 delete | `media_sync_state.dirty` 使用相同状态；显式新增为 1，元数据修改为 2，确认最新版本后为 0；当前无云端永久删除入口，不产生状态 4 |
| 按分类版本确认 | `sync/store/runtime.rs`：捕获版本与 ack 版本 | 保存本地/元数据捕获版本，仅确认对应版本；上传期间 true→false→true 不会被旧 true 回调清零 |
| 编辑发生时间 | `EditEventStamp`、`native_metadata_edited_ms/source/event_id` | 用户操作时生成并持久化，SDK 请求携带 `_syncserver.metadataEvent`，验证返回事件；新照片发布后补传未确认本地事件，不能用服务端提交时间代替 |
| 同类别并发裁决 | `native/records.rs::latest_event`、`store/runtime.rs::local_event_wins` | 按 edited_at_ms、source、event_id 稳定比较；缺失远端事件保留已知本地事件；旧本地事件缺失时以时间 0 和持久化回退事件发送，避免伪造上传时刻；已有基线事件不能作为新云修改覆盖待办 |
| 未决请求 | `Issued`、`store/issued.rs`、`service/coordinator.rs` | `cloud_metadata_operations` 保存通用 UUID、条件版本、值、事件和捕获版本；Pending 不重发，Unknown 只重放原请求，Committed 核实整份返回再确认；只对明确 CONFLICT 重新观察，不把网络失败当未提交 |
| 统一传输边界 | `native/modify.rs` 经 SDK modify_exact | 当前经 SDK 的类型化 `ModifyRequest`/`RecordOperation`，保持固定 SDK 版本；移除收藏专用键，保留通用请求级幂等身份 |
| 跨重启的云端身份 | `NativePinnedScope` 的账号、命名空间和数据库代际 | `cloud_account_scope` 持久化租户、容器、环境、数据库和代际；账号身份校验后核对，变化返回 `CloudScopeChanged`，在接收/重放前停止；v4 历史账号首次通过认证后固定当前有效 scope |
| 接收与上传顺序 | 下行协调后进入租约 | 先恢复已发元数据请求，再完整下行，之后检查租约水位；NotCurrent 重新下行再尝试一次 |
| 接收完整性 | 记录对/generation 校验、资源核验后推进 applied | SDK 构图与摘要校验；原图/缩略图落定后推进 token，失败不推进；记录缓存可重放 |
| 新增恢复与媒体身份 | 已确认新增保留身份，剩余修改改作 update | 完整图匹配持久上传意图的 photo/master/generation，先恢复绑定再分类下载；源文件缺失也能恢复，保留原媒体 ID |
| 单一租约与阶段 | delete→modify→create，失锁停止 | 沿用 SDK 租约与阶段；新增后若有元数据事件未确认，释放新增租约、接收至当前水位，再进入新的修改租约 |
| 路径唯一性与只读绑定 | 照片身份优先于路径 | 完整图内事务批量改路径，支持交换/复用；远端删除保留绑定、文件和只读保护，不推导物理删除 |
| 显式上传范围 | 未选范围不等于全库 | 仅显式选择生成新增意图；已绑定照片后续元数据编辑进入其现有同步义务 |

## 仍属于 MVP 功能边界的差异

- 重构前支持内容替换、永久删除及更完整的分类合并；当前绑定照片仍为只读，产品仅允许收藏元数据修改，没有产生这些操作的入口。当前未声称实现内容/删除分类版本及事件的完整上传链路。
- 重构前有本地变更停止 10 秒后的后台调度和任务控制；当前仍为启动、登录和手动触发。没有将退出登录错误映射为“全局同步 Off”；退出仅清凭证并保留持久义务。
- 当前只支持一个数据目录绑定一个账号；没有旧版账号切换/多任务 UI。
- 当前新照片接收需要原图与缩略图均落地，没有旧客户端其他按需下载或复杂恢复 UI。
- 原始资源发布仍走 SDK 的照片发布接口与持久化 photo/master/generation/operation ID；本轮的完整冻结请求表适用于元数据修改，没有声称迁完旧版所有资源发布状态表。

以上为明确的功能范围差异。共同路径的正确性按旧版元数据事件、版本确认和未知结果恢复模型对齐；完整桌面功能等价仍需后续迁移与独立验收。
