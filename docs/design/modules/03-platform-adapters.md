# M03 平台适配器

## 职责与范围

定义跨平台 ports，完成 Linux 实现设计，为 Android、Windows 约定等价语义。系统 API 细节留在适配器，核心以稳定引用和结果工作。

## 接口与数据

```text
AppStorage.resolve_roots() -> {data, cache, state, same_fs_staging}
InstanceLock.acquire(data_root) -> ExclusiveGuard
MediaSource.choose/ enumerate(grant, cursor) / open(source_ref) -> SourceReader
SecretStore.store/load/delete(credential_ref) -> SecretResult
MediaCodec.inspect/thumbnail/preview(reader, options, cancel) -> PreparedMedia
BackgroundScheduler.submit/cancel(trigger, budget) -> ScheduleResult
FilePublisher.promote_directory(staging, final) / durable_flush / retire
```

SourceRef 为适配器 ID + 不透明来源标识；SourceFingerprint 包含可用的 size、mtime、平台版本标识，仅用于来源变化探测，不冒充 SHA-256。SourceReader 支持顺序读、可选 seek、关闭和取消；不可 seek 的来源先流式复制至受管 staging。

每个 trait 方法必须说明是否阻塞、是否需要宿主主线程、错误分类和取消边界。选取器/权限 UI 在宿主线程；stream、哈希和编解码在后台。核心不持有裸 fd、JNI local reference 或 Flutter BuildContext。

## 流程与状态

### Linux

数据：XDG_DATA_HOME/`photo-client/client.sqlite` 和 `accounts/<AccountId>/`；状态日志：XDG_STATE_HOME/`photo-client/`；尺寸缓存：XDG_CACHE_HOME/`photo-client/`。未设置 XDG 时由平台适配器按桌面规范解析。仅数据根具备用户数据语义，缓存删除不删除原图。

目录创建采用私有权限；不跟随媒体导入中的符号链接，目录遍历不跨用户未选择的根。根锁使用持久锁文件和进程级独占锁；不以“文件存在”作为仍有进程运行的证明。

选择器使用 Flutter Linux 宿主文件/目录选择集成，返回授权路径；Rust 再次检查类型和可读性。源文件只读，不原地改写、不改 mtime、不移入垃圾箱。

SecretStore 使用 Secret Service，固定服务名与账户凭证引用作索引。锁定、无桌面总线、服务缺失分开报告，不在日志中回显 secret。所选 Rust/Flutter 插件版本在 L0 锁定并验证，协议不依赖某个插件的私有返回结构。

FilePublisher 仅在同一数据根文件系统提升目录；fsync/目录同步结果必须检查。缓存写入允许使用可重建策略。发行 bundle 仍可能包含 Flutter Linux runner 的 GTK 系统依赖，这与 Rust 核心是否独立分开验证。

### Android 预留

MediaSource 处理 Photo Picker/MediaStore 授权和内容 URI，不要求真实路径；长期访问授权可失效，来源不可读时保留受管副本与同步义务。存储使用应用私有持久目录，不把系统 cache 作为原图库。

SecretStore 的语义是用平台密钥保护持久令牌，不把 accessToken 当成“直接存进 Keystore 的任意字符串”假设。后台宿主调用同一核心，必须服从时间预算、取消、同进程注册中心和跨进程排他。权限与后台系统行为在接入时按官方文档/目标版本重新验证。

### Windows 预留

MediaSource 提供文件/目录选择和路径规范化；SecretStore 用系统凭证能力。数据根来自平台应用数据目录。发布为新版本目录，打开文件占用或防病毒干预导致删除/移动失败时可重试，不覆盖仍使用的旧目录。逻辑路径不使用 Windows 路径规则改写。

## 异常与恢复

标准适配错误：PermissionDenied、GrantExpired、SourceChanged、SourceMissing、SecretLocked、SecretUnavailable、InsufficientSpace、UnsupportedCodec、CrossDevicePromotion、AlreadyRunning、Cancelled。

同文件系统前提不满足时在准备前失败，不用跨文件系统 copy+delete 伪装原子提升。来源授权取消不产生导入条目；已完成受管复制后来源消失不撤销受管数据。

## 验收

- T03-01：Linux 路径/私有权限/进程锁正确，缓存清理不触及原图。
- T03-02：Secret Service 锁定或缺失时无明文回退。
- T03-03：非路径来源通过假适配器导入，证明核心无 POSIX 路径假设。
- T03-04：跨文件系统提升和文件占用失败可见且不丢旧版本。
