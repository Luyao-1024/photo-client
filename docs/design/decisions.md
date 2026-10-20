# 统一约定与设计决策

版本：1。所有模块必须遵守本页；接口示例是项目设计，尚非可调用 API。

## 决策

| 编号 | 已定决定 | 原因与约束 |
|---|---|---|
| D01 | Flutter UI，独立 Rust 核心，FRB 薄桥接 | 复用同步正确性；核心不导入 GTK、GIO、Flutter 类型 |
| D02 | 一个本地 `client.sqlite`，一个 DbActor writer，所有账户内容按 account_id 分区 | 账户切换和配置可原子提交；跨账户关系用复合外键禁止 |
| D03 | 受管媒体采用不可变本地版本，数据库指针是可见版本提交点 | Flutter 与 Rust 无法共用旧 GTK 的线程读锁；不覆盖正在读取的旧文件 |
| D04 | 云端逻辑路径、本地物理路径、来源 URI、照片身份分开 | 提前处理 Android URI 与 Windows 文件名差异 |
| D05 | 原图、规范缩略图持久保存；尺寸缓存可重建 | 可见性与恢复不依赖系统保留缓存 |
| D06 | 同时一个当前账户；每账户一个初始 zone job | 首版控制产品范围；数据结构支持多个 job，UI 不提前开放 |
| D07 | 首版源文件/目录显式导入，不监听源目录，不修改源文件 | 控制副本语义；手机来源也可接同一导入管线 |
| D08 | 首版在线写操作为新建照片、收藏修改；同步接收已知元数据及云端删除 | 云端路径改名、主动隐藏/回收站/永久删除、编辑、来源自动备份后续开放 |
| D09 | HTTP 与持久化分层，wire JSON 不进入同步持久状态 | 所有恢复证据为标量和关联行；未知字段类型阻塞并可重取 |
| D10 | 平台 profile 选择已注册适配器；实际能力采用交集 | 配置不制造操作系统能力；planned 平台禁止发布构建 |
| D11 | 首版关闭同步保留配置、基线和待办，只停止新运行 | 与旧应用“关闭会清历史”的操作区分；重置同步历史不在首版 UI 开放 |
| D12 | 不做空闲远端轮询；启动只恢复已持久化的工作，手动同步可拉新变化 | 保留清晰调度边界；自动同步仅对已批准上传义务触发 |
| D13 | 先稳定的保守进度确认，再优化上行续批 | 不因已收到一个成功响应就直接跳到服务器最新 token |
| D14 | 所有参数、分页和响应都带当前上下文；UI 缓存按账户和代际分区 | 账户切换、重配置、重新排序不能混入旧结果 |
| D15 | 以100,000张边界验收，窄索引驻Rust，窗口DTO到Dart | 帧预算/内存/首屏/同步并行一起测，见M16 |
| D16 | 液态玻璃是统一材质系统，实时模糊只覆盖有限chrome | 明暗/无障碍/轻量回退与full性能都验收，见M17 |

D03 是对总方案“发布适配与读取保护”的具体落实：发布新目录，保留旧完整目录，用读取句柄固定旧版本；不沿用覆盖源路径的发布实现。D11 是明确的新产品操作定义；实现时不得复用旧全局关闭的清历史路径。

## 标识与时间

| 类型 | 表达与归属 |
|---|---|
| AccountId、JobId、EntryId、LocalVersionId | 客户端 UUID，存 TEXT；路径段只使用客户端生成的安全 UUID |
| RemoteUserId、PhotoId、MasterId、AssetId | 服务端不透明标识；从不直接拼接到物理路径 |
| Account identity | 规范化 endpoint origin + 服务端 user UUID；用户名只作显示 |
| Scope | account_id + namespace + zone/owner + database_generation；namespace 字段为独立列 |
| ProcessId、RunId、CommandId | 客户端 UUID；进程、同步轮次、用户命令分别独立 |
| Epoch | 进程内当前账户选择代际；不替代服务端 generation |
| ConfigGeneration | 每个 job 的递增整数，持久化；有效配置变更后递增 |
| 类别版本 | metadata/content/delete 三组 local_version 和 ack_version 单调递增 |
| ContentGeneration | 服务端照片内容代际；与 LocalVersionId、database_generation 不可互换 |
| 修改事件 | UTC 毫秒、稳定 device_id、event_id；按三元组排序，沿用已有类别规则 |
| 超时与保活 | 单调时钟；墙上时钟只用于事件时间与用户显示 |

FFI 数字计数必须在 Dart/Rust 两侧做范围校验。版本计数超过可表达范围时阻止写入并报告内部错误，不能环绕。

## 共同请求上下文

```text
Context = { process_id, account_id?, epoch, job_id?, config_generation? }
Mutation = { context, command_id, expected_entry_versions?, payload }
Result = { context, committed_revision, outcome }
```

account_id 仅在启动、登录草稿和全局外观设置中可缺省；所有内容/同步 API 强制非空。全局外观设置使用确定目标值与配置版本，不通过重复 toggle 重放。

一般 UI 修改的成功由 actor 事务提交决定。网络成功不等于本地确认成功。旧上下文返回 StaleContext，重取状态后由用户或受控调度重试；界面不得自动重放删除等意图。

## 完成、待办与错误

`LocalReady` 表示本地完整副本可读；`Synced` 另要求对应云端基线已确认、三类别无未确认义务、无资源/发布/冲突待办。离线导入可以 LocalReady 且 PendingUpload。

错误共同字段：code、category、retry_action、account_id/job_id/entry_id（适用时）、安全的 message_key/args、diagnostic_id。错误不携带 Authorization、原始密码、完整 capability URL 或未经清理的 HTTP 正文。

| 类别 | 处理 |
|---|---|
| UserAction | 重新登录、调整范围/空间；不自动重试 |
| Transient | 本轮有界网络重试；耗尽后保存待办，不启动无限后台循环 |
| ItemFailure | 本轮跳过该照片，独立照片继续 |
| ProtocolSafety | 停止受影响轮次，保留证据 |
| StaleContext / Cancelled | 不呈现为单张业务失败；已发出请求进入结果核对 |
| Internal / Storage | 明确失败；保留既有文件和事务一致性 |

具体重试入口由 M14 定义；错误类别本身不产生新的持久任务队列。

## 模块依赖与事务归属

M01 定义生命周期/域类型；M02/M03 提供平台；M05 实现存储；M06 只作传输；M04/M07/M08/M09/M10/M11 为应用服务；M12 暴露能力；M13 消费 DTO；M14 组织调度和日志；M15 负责交付证据；M16 拥有原生浏览索引/缓存预算；M17 拥有材质系统/特效预算。

M06 不引用 SQL 或 UI。M05 不调用网络、编解码或平台凭证 UI。M07/M08/M09 通过 actor 命令提交事实。文件操作不可在 SQL 事务内等待。事件只在提交后发布，取消订阅不回滚已提交事务。
