# M01 运行时与领域边界

## 职责与范围

拥有 Rust Engine 生命周期、域标识、资源配额、当前上下文和应用级排他；首版运行于 Flutter Linux 宿主。接口中没有 GTK、Dart isolate 或具体系统句柄类型。

拟定代码：`photo-core::{runtime,commands}` 与独立 `photo-domain`。依赖 M02/M03/M05，向其余服务提供 EngineHandle。依赖方向通过 trait 注入打破编译环；平台注册发生在组合根。

## 接口与数据

```text
open_engine(BootstrapOptions, PlatformPorts) -> EngineHandle + BootstrapSnapshot
engine.bootstrap_status() -> RuntimeStatus
engine.request_shutdown(deadline) -> ShutdownReport
engine.context() -> Context
engine.dispatch(DomainCommand) -> CommandResult
```

BootstrapOptions 含配置摘要、数据根、bridge 协议版本、运行模式；不含密码。EngineHandle 是不透明句柄，不能通过字符串路径再次打开第二个 Engine。

每个数据根最多一个进程持有 engine.lock；锁由平台实现提供。进程内重复初始化返回已初始化错误，不另建 Tokio runtime。后续 Android UI/后台入口使用同一注册中心；独立进程竞争锁时返回 AlreadyRunning，不绕开 writer 限制。

资源初值：网络资源传输最多 4 路、原图最多 2 路；编解码最多 2 路并受解码预算限制；SQLite 1 writer + 最多 2 短读连接。数值是初始调优参数，不是已测性能结论。

## 流程与状态

`Created → Opening → Recovering → Ready → Quiescing → Closed`，错误分为 FailedBeforeOpen 与 RecoveryBlocked。

1. 验证 profile/bridge ABI 和目录，取得根锁。
2. 打开数据库、校验 schema、完成迁移。
3. 为本进程生成 ProcessId；读取稳定 device_id 和当前账号配置。
4. 先结算发布与导入恢复证据，再应用已接受的pending配置，最后允许读取相应账号图库。
5. 将上次 Running 的 run 标记 Interrupted；未知网络结果保留供 M08 核对。
6. 发布 Ready/RecoveryBlocked 快照；M14 只接收准入后的触发。

某账户发布失败只阻止该账户的新同步与相关可见性推进；其他完整本地版本可在明确恢复状态下浏览。数据库损坏阻止正常打开，不能自动重建一个空库。

上下文切换先进入 QuiescingAccount、拒绝旧 epoch 新命令、停止网络与准备工作，完成已进入提交区的短事务/发布，再提交选中账号、递增 epoch，最后通知 UI 清理旧快照。切换本身不清待办。

退出分为停止准入、发取消、释放租约、等待短提交、结束读句柄、关闭数据库、释放根锁。默认给 5 秒协作期限；超期返回有未结算证据，宿主可退出，次启恢复。不能超期强行把任务标完成。

## 并发与边界

- 一个账号一个 active coordinator；多个手动触发合并为一次追加运行请求。
- DbActor 命令携带上下文；写入前再次检查账户、配置、类别版本。
- 阻塞文件/图像工作在有界 blocking pool；网络在 Tokio；没有工作线程等待 Flutter UI 才能释放数据库锁。
- 文件发布提交区可短暂拒绝取消；网络和缩略图生成始终可取消。
- 不在工作任务持有进程根锁之外再嵌套等待 UI；资源锁顺序固定为账户准入→entry 准备→短文件提升→DbActor，不在 SQL 内等待前级锁。

## 异常与恢复

AlreadyRunning 提示已有实例，首版不承诺窗口唤醒转发。ProfileMismatch/BridgeMismatch 在打开用户库前失败。目录不可写不退回临时目录保存正式数据。

panic 边界转换为 sanitized Internal 错误并阻止后续写入；无法保证恢复的 actor 崩溃需重新启动。未提交 SQL 回滚；网络请求是否提交由持久 issued 证据判断。

## 验收

- T01-01：同数据根第二次打开被拒绝，不产生第二 writer。
- T01-02：发布恢复先于首屏查询准入；Interrupted 不误报 Completed。
- T01-03：账号切换后旧响应/旧命令被拒绝。
- T01-04：退出期限耗尽保留证据，次启可恢复。
