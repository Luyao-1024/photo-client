# M15 工程、验证与交付

## 职责与范围

确定实现工程边界、Linux 构建产物、阶段验收与证据格式。Android/Windows 只定义激活门槛，不能用 Linux 编译替代目标平台运行验证。

## 接口与数据

根 Cargo workspace 与 `app/` Flutter 工程分开管理。Rust crate 确定为 photo-domain、photo-core、syncserver-client、photo-bridge、platform-linux。

photo-domain 拥有无平台域类型和 ports；其余 crate 引用这些合同。photo-core 通过 ports 接受平台实现，组合根在 photo-bridge，避免平台与核心之间产生循环依赖。

依赖方向：

```text
photo-domain <- syncserver-client
photo-domain <- photo-core -> syncserver-client
photo-domain <- platform-linux
photo-bridge -> photo-core + platform-linux + photo-domain
Flutter -> 生成绑定 -> photo-bridge
```

Tokio/HTTP/SQLite 按目标启用 feature；同步核心不引入 GTK/Blueprint/GStreamer。Linux Flutter runner 自身系统依赖单独列入打包清单。禁止依赖 `../photoViewer` 的整个 crate；按许可和来源记录移植模块及测试场景。

## 流程与状态

以下L0–L3是概括；实际执行采用[14步开发计划](../development-plan.md)和[逐步验收手册](../stage-acceptance.md)，S00为设计准备。S03/S04先验证玻璃与十万图库，S05–S08再接真实下行，S09–S12完成导入上行/配置，S13/S14综合验收与打包。

| 阶段 | 必须交付 | 阻止进入下阶段的条件 |
|---|---|---|
| L0 | Linux 窗口、FRB 双向调用/事件、配置校验、根锁/数据库/平台 ports、关闭恢复 | 工具链不完整、摘要不一致、writer/生命周期不明确 |
| L1 | 普通账号登录、真实下行、双资源发布、图库/查看器、恢复 | 假数据替代实际服务器、半资源可见、错误推进 applied |
| L2 | 显式导入、租约上传、收藏、旧新客户端互操作 | 丢 dirty、响应未知重复新建、旧 fence 成功、越权范围 |
| L3 | 三宽度交互、异常旅程、十万图库性能/玻璃UX样本、Linux release bundle | 仅调试运行、未验证打包依赖或没有真实输入证据 |

L0 选择实际可安装且经构建验证的 Flutter stable/FRB v2/Rust 版本，提交 pubspec.lock、Cargo.lock 和工具链约束；本设计不写一个未经本机验证的“最新版本”。Flutter/原生依赖安装属于开发环境准备，不属于本轮设计验证。

拟定实现检查：Rust fmt、Clippy、受影响单元/集成测试；Flutter analyze、test；FRB 生成一致性；release Linux build。命令须随实际 workspace 固化到 CI，尚无工程时不执行空命令冒称通过。

开发中先运行新增/直接相关检查。完整 gate 在正式交付候选或远端推送前对最终代码树执行；报告本地构建、测试、远端 CI、打包运行、push 分开。

## 验收与性能

[验收矩阵](../acceptance.md)是测试场景的唯一编号登记，模块页只引用编号。新代码须将关键场景落实到真正路径，不能只调用 handler 后手改 DB 为成功。

协议旅程起临时真实 SyncServer、两个测试用户/客户端及临时媒体目录；不接触生产库或真实照片。旧 PhotoViewer 互操作另用隔离数据目录，保存操作顺序、revision/摘要和资源计数证据。

Flutter 组件测试覆盖布局/状态；应用集成测试驱动真实 click/tap/keyboard/resize，至少包含打包后的启动、登录、导入、收藏、暂停和恢复。Linux 390/800/1440 宽度、文本放大、鼠标/键盘与缓存内存样本分别记录。模拟触摸/宽度不能证明 Android 原生体验。

M16的1千/1万/5万/10万数据集和M17的明暗/三材质/full与auto滚动是L3强制交付，不能后置为“未来优化”。

元数据性能样本明确 100 条“照片逻辑项”可能涉及多种 records；以有效配对投影计数，不能将 100 个任意 record 当 100 张照片。对已完整本地资源，记录 HTTP→持久化→应用→checkpoint 的每批耗时，目标每批≤1秒；至少10批，环境/构建模式/失败样本公开。原图传输另测吞吐/内存，不能套用该目标。

## 打包和升级

Linux 首个支持 profile 是本机 Fedora x86_64；产物为 release bundle 及启动入口，附运行依赖、版本、profile digest、构建 SHA/校验和和验证记录。没有启动器/依赖清单的孤立二进制不算可安装交付。

依赖扫描检查动态库及运行路径，测试在用户应用目录安装运行；不得因开发机恰有某个库就宣称 bundle 自包含。Flatpak/RPM 与多发行版支持后续单列，不默认承诺。

升级先备份并验证迁移；旧二进制不能打开较新 schema 写入。首版不做自动更新。Git 初始化/commit/push 仅在对应任务范围内执行，本轮设计文档不建立远端或推送。

Android 激活必须有 SDK/NDK 构建、arm64 真机、URI/权限/凭证/后台预算/停止恢复/手机平板输入；Windows 激活必须有目标系统构建、凭证/文件占用/路径大小写/打包与恢复。二者 profile 与实际能力都通过后再标 active。

## 异常与恢复

工具链或原生插件无法满足合同，先记录最小复现和设计调整，不能把协议恢复逻辑搬进 Dart 以绕过编译问题。发行依赖缺失属于交付失败，不用开发环境截图替代。

## 验收

- T15-01：依赖图无应用/平台反向耦合，生成绑定和 profile 可复现。
- T15-02：真实双客户端旅程、故障注入与旧客户端互操作有独立证据。
- T15-03：100 照片批次端到端计时与资源吞吐分开，结果不冒称已达标。
- T15-04：打包产物实际安装运行；planned 平台不出现支持标志。
