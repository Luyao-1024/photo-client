# 模块详细设计索引

> 范围已更新：一期纯本地、云同步二期。当前执行以[本地一期计划](../local-first/README.md)为准；本页云同步内容保留作二期设计参考，S01工程基础可复用。

设计版本：1。日期：2026-10-20。状态：云同步分期已被本地优先版本2取代；当前功能开发按用户要求暂停，详情以本地一期记录为准。

本目录细化[总体架构](../cloud-sync-architecture.md)，先确定模块合同和验收，再开展应用开发。第一阶段仅交付 Linux；Android、Windows 设计平台边界与接入门槛，不列为已支持平台。

## 阅读与实施顺序

先读[统一约定与决策](decisions.md)、[14步开发计划](development-plan.md)和[分步验收手册](stage-acceptance.md)，再读对应模块。L0–L3是总体阶段，S01–S14是实际逐步交付/验收单元，S00只代表设计准备。下表编号同时用于接口归属和验收追踪。

| 模块 | 详细设计 | 拥有的数据/行为 | 阶段 |
|---|---|---|---|
| M01 | [运行时与领域边界](modules/01-runtime-domain.md) | 核心生命周期、身份、代际、并发、退出 | L0 |
| M02 | [平台配置与能力](modules/02-platform-configuration.md) | profile、构建验证、能力合并 | L0 |
| M03 | [平台适配器](modules/03-platform-adapters.md) | Linux 存储/凭证/文件/媒体接口，后续平台合同 | L0 |
| M04 | [账号与会话](modules/04-accounts-security.md) | 登录草稿、当前账号、切换、会话存储 | L0–L1 |
| M05 | [数据库与事务](modules/05-database.md) | schema、唯一写入、约束、迁移、索引 | L0–L2 |
| M06 | [SyncServer 网关](modules/06-protocol-gateway.md) | 类型化协议适配、传输、错误分类 | L1 |
| M07 | [下行与冲突协调](modules/07-downlink.md) | 快照、增量、投影、ingest/applied、冲突 | L1 |
| M08 | [上行与租约](modules/08-uplink.md) | dirty、阶段、回执、成功确认 | L2 |
| M09 | [资源与本地发布](modules/09-assets-publication.md) | 流式传输、不可变版本、发布恢复、GC | L1–L2 |
| M10 | [导入与媒体准备](modules/10-media-import.md) | 授权来源、导入、缩略图、范围 | L2 |
| M11 | [图库查询与操作](modules/11-library.md) | 分页、查看、收藏、逻辑分组、计数 | L1–L2 |
| M12 | [FFI 与事件](modules/12-ffi-events.md) | Dart/Rust DTO、请求、订阅、资源句柄 | L0–L2 |
| M13 | [Flutter 界面与交互](modules/13-flutter-ui.md) | 页面、响应式布局、导航、无障碍 | L0–L3 |
| M14 | [调度与诊断](modules/14-scheduling-diagnostics.md) | 触发、取消、重试边界、日志、诊断 | L0–L3 |
| M15 | [构建、验证与交付](modules/15-delivery-validation.md) | 工程依赖、验收、Linux bundle、后续平台门槛 | L0–L3 |
| M16 | [十万张图库性能](modules/16-performance.md) | 窄索引、任意位置窗口、缓存与帧/内存预算 | L0–L3 |
| M17 | [液态玻璃 UX](modules/17-liquid-glass.md) | 材质 token、状态/动效、可读性、实时模糊预算 | L0–L3 |

## 设计合同

- [本地数据库设计 SQL](contracts/local-schema.sql)：结构合同，用内存 SQLite 验证；不是应用迁移，也不会在用户数据目录执行。
- [平台配置示例](contracts/platform-profiles.json)：用 JSON 演示最终 YAML profile 的同一字段模型；属于设计样本，不是已实现的构建配置。
- [液态玻璃设计 token](ux/glass-tokens.json)：明暗主题、材质质量、动效与预算的设计样本。
- [模块与验收登记](contracts/design-manifest.json)：记录模块、依赖、测试编号和文件路径，供文档一致性检查。
- [阶段合同与状态](contracts/stage-plan.json)：14个开发点、60条含设计准备的检查项和79项首次完整归属；此处为旧分期记录；当前以本地一期状态为准。
- [阶段报告模板](templates/stage-report.md)：技术验收和用户体验确认独立记录。
- [统一验收矩阵](acceptance.md)：每个测试编号的场景与可观察结果；本轮的文档/SQL检查不代表应用测试通过。
- [设计合同检查器](contracts/validate_design.py)：只读取文档、验证样本并建立内存SQLite，不是应用实现。
- [设计核查记录](review.md)：契约来源、检查结果和开发入口。

## 协议所有权

服务端 wire 契约只由相邻 SyncServer 拥有。本文档写客户端映射、状态机、数据库及 UI，不复制第二份接口协议。

入口：[认证](../../../syncserver/docs/contracts/authentication.md)、[快照](../../../syncserver/docs/contracts/snapshots.md)、[记录](../../../syncserver/docs/contracts/records.md)、[照片](../../../syncserver/docs/contracts/photo-records.md)、[资源](../../../syncserver/docs/contracts/assets.md)、[上行协调](../../../syncserver/docs/contracts/upload-coordination.md)、[配额](../../../syncserver/docs/contracts/storage-quota.md)。

## 设计完成与开发边界

设计基线完成要求：17 个模块都有职责、接口、状态/流程、异常恢复和验收；跨模块术语一致；本地链接有效；SQL 能建立结构且约束与索引经样本验证；profile 示例符合平台能力规则；所有验收编号登记完整。

以上条件满足后按S01进入L0；先完成S03/S04本地玻璃与十万图库验证，再在S05接入真实登录。每点放行需满足分步手册，不能直接跳到L3总验收。以后如实际构建或互操作证明设计不成立，应先改受影响合同及测试预期，再改实现；不把预留能力的声明当作已经实现。
