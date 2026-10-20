# M14 调度、配置生效与诊断

## 职责与范围

组织用户触发、本地义务触发、启动恢复、协作停止、配置生效与日志。持久事实来自 M05，不建立另一个任务/dirty 真相来源。

## 接口与数据

```text
request_sync(context, trigger) -> RunAdmission
pause/resume(job)
set_sync_enabled(enabled)
accept_configuration(job, expected_generation, changes)
notify_local_obligation(job, committed_revision)
export_diagnostics(selection) -> LocalArtifact
```

trigger 为 Manual、LocalQuiescent、Resume、StartupRecovery、ConfigAccepted、SuccessfulContinuation。每个 admitted run 有 run_id/配置捕获和触发原因；合并触发记录原因集合即可，不重复开启 coordinator。

## 流程与状态

Job 状态是 Disabled/Paused/NeedsLogin/Idle/Running/Quiescing/Blocked，SyncOverview 由实际义务推导，Idle 不等于全部完成。

本地批准变更 10 秒无新变更后触发，使用单调时钟和可重置 timer；订阅来源是事务提交事件。手动同步立即准入。启动仅发现已存在 dirty、未完成导入/资源/发布或 unknown issued 时恢复；空闲不定时轮询远端新照片。

每次循环首批下行再上行；成功且仍有本轮可执行义务时可继续，连续 8 批让出 executor 后再准入。失败/Deferred 不自动空转。纯下行资源已失败时保留待办，本次运行明确 Partial，等待用户重试、恢复或有效条件改变。

重试边界：本轮读请求和瞬态传输按 M06 有界重试；失败后的新轮次不由无限 timer 产生。凭证恢复、用户立即同步、显式继续、已接受范围变更可重新准入；缺缩略图修复完成可触发一次 LocalQuiescent。

暂停/关闭总开关拒绝新准入，取消在途准备/网络，安全结束短发布。保留配置/历史/dirty。Resume/开启后只对实际待办触发一次；没有待办时是否拉新由明确手动同步决定。

配置先编辑后生效：验证草稿 → actor 比较差异 → no-op 直接成功且不增代际 → 有效变更持久登记job_config_intents及来源行 → 旧轮 quiesce → 完成已有短发布/保存未知结果 → 增 ConfigGeneration → 激活新范围 → 若启用且未暂停则触发受影响 job。active配置在短提交结算前保持不变，pending意图阻止旧配置新准入；重启先结算发布再应用最新pending配置。快速多次接受将旧意图标superseded，按单调target_generation保留最新配置，不要求用户先暂停。

## 日志和摘要

Rust tracing 是核心单入口；Dart 使用同一 diagnostic_id/上下文输出 UI 日志，不二次打印敏感 DTO。日志输出本地滚动文件和开发控制台，与同步 SQLite 事务解耦。

初始日志策略：INFO 默认，文件总预算 64 MiB，最多保留 7 天，先触发者先清理；导出由用户明确操作生成本地脱敏包，不发送服务器。根路径/用户名/逻辑照片名默认散列或省略；密码/Bearer/lease/能力 URL 永不输出。

每批 INFO 包含 account/job/run/batch、direction、attempted/succeeded/failed/pending/deferred、bytes、http_ms/persist_ms/apply_ms/checkpoint_ms/elapsed_ms 和 outcome。outcome 为 complete（本轮义务结算）/pending（有未做工作）/partial（部分失败）/deferred（受条件延后）；不以日志里“完成”暗示整个图库一致。

overview 只因状态失效事件触发短读，窗口 300ms 合并；单图资源日志不能导致逐图全库 COUNT。库容量达到10万时额外记录窗口/索引/解码队列与M16预算；材质有效质量及M17自动降级轨迹必须进入性能诊断，不打印逐帧全量日志。指标与日志写失败不回滚已经提交的照片事务，明确上报 DiagnosticsUnavailable。

## 异常与恢复

网络离线只影响在线任务；离线浏览/本地导入按可用能力继续。失锁为协议安全停止，不归入普通退避重试。后台任务时间预算到达以 Interrupted/Deferred 结算，次启或合法系统触发续做。

Linux 首版应用关闭即停止工作，没有隐藏 daemon；planned Android scheduler 只接收已授权义务，不能扩大来源范围。诊断包排除凭证库、用户原图、完整 SQLite 数据库和远端能力字段。

## 验收

- T14-01：10 秒去抖、手动触发合并、无空闲轮询、失败不自旋。
- T14-02：有效配置自动生效；取消/无效/no-op 不停任务，旧代际不继续写。
- T14-03：暂停/开关保留义务，续批有界且错误不混入 complete。
- T14-04：INFO 批次字段齐全、导出脱敏、诊断失败不阻塞同步事务。
