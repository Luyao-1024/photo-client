# M10 导入与媒体准备

## 职责与范围

将用户授权文件/目录变成受管完整照片；portable_image实现位于photo-core的纯Rust media模块，通过MediaCodec port组合，不绑定platform-linux crate，后续平台可配置复用。保存来源映射、准备上传缩略图与逻辑路径。首版没有外部源目录持续监听、相机自动备份、RAW/HEIC/视频完整支持，也不改写来源文件。

## 接口与数据

```text
preview_import(grant, options) -> PreviewSummary + draft_id
accept_import(draft_id, scope_choice, context) -> ImportBatchId
cancel_import(batch_id) / retry_import(item_id)
import_status(batch_id) -> counts + item_errors
prepare_local_media(SourceReader, limits) -> VerifiedVersion
```

Preview 仅列出可读来源摘要、预计项目数/大小（未知则明确未知）、格式/路径冲突；不建立 dirty。接受时通过M14有效配置流程登记范围/来源，持久import_batch/items与对应config_generation及明确scope_choice；取消选择器不产生事实。

来源 identity 是 source_adapter + source_id + source_key，不是文件名或 hash。每个 source_key 维护已导入 entry、来源指纹与内容 hash。相同来源未变再次导入为 AlreadyImported；不同来源即使内容 hash 相同也不自动合并成同一照片身份。

## 流程与状态

`Accepted → Enumerating → Copying → Inspecting → Thumbnailing → Publishing → LocalReady → PendingUpload`。失败保留逐项状态，其他项目继续。只计 LocalReady 为导入完成；上传完成单独计数。

1. 枚举显式根，跳过链接、工作目录和不支持文件，逐页持久 import_items；枚举中断记录尚未结束，不能称整个批次完成。
2. 打开来源，记录可用指纹；流式复制至同文件系统 staging，并计算实际 SHA-256。
3. 来源支持二次指纹时复制后核对；不稳定返回 SourceChanged。无法证明快照的来源必须由适配器提供稳定 Reader 或重试，不能使用 size/mtime 假装字节稳定。
4. 内容 sniff 和有界解码，处理 EXIF 方向；生成规范 JPEG/PNG 缩略图，保留原字节。
5. 原图与缩略图验证后，通过 M09 的本地发布提交 LocalReady；仅在用户批准范围内登记 create 义务。
6. 发布后旧来源消失不删除受管副本；导入取消不自动删除已经提交的照片。

本地新 entry 即使未允许上传也可 LocalReady，但不进入 create dirty。以后范围接受时 actor 显式登记相应义务；不能在后台扫描中自动扩大允许范围。

## 逻辑路径与格式

目录导入默认保留用户所选根之下的相对路径；单文件导入默认 `Imports/<batch-local-date>/<basename>`。先按服务端路径约束验证，非法名字明确要求用户改名/跳过，不静默替换云端逻辑路径。冲突时提供保留双方的明确重命名建议，接受后提交。

首版 JPEG/PNG/WebP；输出缩略图建议长边 1024，实际限制与服务能力取较小值。原图方向不被重编码修正，缩略图处理方向后须清除误导性的方向标记。多帧格式或解码不支持为 UnsupportedMedia，不仅凭扩展名接收。

Linux profile单图解码预算初设128 MiB、全局在途192 MiB，最多2个codec worker；所有预算取当前profile配置；先 inspect 尺寸，按解码器能力缩采样，预算超出拒绝并说明。最大文件大小与服务能力取小值；只做本地导入时也遵守本地媒体预算，不能分配无界缓冲。

## 异常与恢复

复制完成但还未发布的 import_item 记录 staging/version 归属；重启核验完整文件后续做，未完整 part 重拷。已发布但 import 状态未显示时按 entry/version 事实幂等结算，不能重复创建照片。

SourceMissing/GrantExpired 不自动生成云端删除。规范缩略图丢失由本地媒体修复入口在后台重新生成，上行路径只 deferred。修复要证明原图摘要仍匹配该受管版本。

## 验收

- T10-01：取消预览不建 dirty，接受仅作用于明确范围。
- T10-02：来源在复制期间变化被发现，源文件始终不改写。
- T10-03：同来源重导幂等、不同来源同 hash 不冒认同身份。
- T10-04：方向、路径冲突、非法名字、解码预算与不支持格式可观察。
- T10-05：导入中断后续做，无重复 entry 或越权上传。
