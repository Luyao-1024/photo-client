# M02 平台配置与能力

## 职责与范围

定义构建 profile 的字段、校验、代码生成和运行时能力合并；业务层只消费能力，不读取任意 YAML。Linux active（设计目标，不代表已实现）；Android、Windows planned。

拟定入口：`tools/platform`。本轮示例在[profile 合同](../contracts/platform-profiles.json)，不存在可运行工具。

## 接口与数据

profile 字段：schema_version、profile_id、platform、status、flutter_target、rust_target、adapters、limits、ui、packaging。未知字段拒绝，重复键拒绝，标量类型严格；没有任意 shell、动态库路径、凭证或远端脚本字段。

| 字段 | 决定 |
|---|---|
| status | active/planned；普通 build/run/package 只接受 active |
| profile_id | Linux 首个为 linux-x86_64；不等同操作系统名 |
| adapters | 六个稳定注册 ID：storage/source/secrets/scheduler/codec/instance_lock |
| limits | 传输/解码并发、总/单项解码MiB、图片/viewer缓存MiB、窄索引MiB、DTO行数和磁盘缓存MiB；均正整数；original并发≤transfer，单项解码≤总解码，平台默认值见profile合同 |
| ui | adaptive、keyboard_mouse、touch；adaptive 必须 true |
| packaging | format；必须属于已实现目标，planned 可只作设计声明 |

工具规划接口：validate(profile)、describe(profile)、generate(profile)、build(profile,mode)。build 先 validate，再生成规范化描述，调用固定参数数组，避免将 profile 拼接为 shell 命令。

生成 `build_profile.g.dart` 与 Rust `build_profile.rs`，共同包含 profile_id、schema_version、profile_digest 和 bridge_protocol_version；生成文件不作为第二份手改配置。digest 来自排序字段后的规范化结构，不含机器路径。

## 流程与状态

`Parsed → SchemaValid → TargetValid → AdaptersResolved → Generated → Built`。任一步失败均停止后续，不能降级为另一个平台。

实际能力为 profile 允许能力 ∩ 已编译适配器能力 ∩ 运行时探测结果。各能力返回 supported、reason_code、constraints；触摸布局能力与操作系统后台执行能力独立。

Linux Secret Service 不可用时仍可离线读已有图库，但 persistent_sessions=false，新的在线连接要求明确的本次会话模式或修复凭证服务；不自动写明文 token。

运行时用户设置不能改变 rust_target、加载未编译插件或打开 planned 平台功能。模拟手机宽度只改变布局，不伪造 Android 权限与来源能力。

## 平台接入规则

Linux x86_64 在 Linux 构建，Windows 在 Windows 构建，Android 在具备对应 SDK/NDK 的已验证宿主构建。交叉编译属于后续经验证 profile，不暗示任意宿主可构建所有目标。

Android/Windows 激活需 M03 适配器、runner、依赖锁定、M15 平台验收均完成；改 status 一行不能满足门槛。运行时适配器缺失返回 CapabilityUnavailable。

## 异常与恢复

配置错误先于打开数据库报告，提供字段路径和允许值。生成摘要不一致返回 BuildProfileMismatch；不可自动重写现有用户 schema。运行期能力降级发 CapabilitiesChanged 并停止相关新操作，已经提交的本地义务保留。

## 验收

- T02-01：planned、宿主不符、未知适配器、错误数值/字段均被拒绝。
- T02-02：Dart/Rust 配置摘要一致，人工改生成文件会在检查时发现。
- T02-03：配置开启但运行期不可用的能力保持关闭且有原因。
