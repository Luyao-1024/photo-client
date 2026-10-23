# 本地图库升级与真实环境启动

更新于 2026-10-21。开发阶段允许实现数据库升级；版本不匹配时不得删除图库重建。

## 本次故障

真实图库位于 `${XDG_DATA_HOME:-$HOME/.local/share}/photo-client/library`。现有数据库的 `user_version` 为 1，包含 366 项媒体；当前核心预期版本为 3，但此前仅支持 v2 → v3，因此打开真实图库时返回 `SchemaUpgradeRequired`。设置无法读取/保存，新增目录扫描也随之失败；界面的“检查文件访问权限”不是本次故障的真实原因。

已实际检查图片目录的访问权限：376 个文件均可读取，未对照片目录修改权限，也未以临时图库或 fake gateway 代替真实环境。

## 升级行为

- 正常打开时取得图库实例锁，通过 SQLite backup API 将包含已提交 WAL 数据的一致备份写入图库 `backups/`。备份文件名包含旧版本、目标版本、时间与唯一 ID；权限为 0600。备份失败则不开始升级。
- 支持 v1–v6 → v7。v1 补齐 `media.original_uri`、`media.trashed_at_ms`；补齐偏好、相册偏好、媒体详情、文件发布记录、排除目录和待清理记录等表及相关索引。v5/v6/v7 依次补齐通用元数据义务、多账号上传范围和内容/删除义务。
- 将旧 `app_settings` 的主题、材质与语言转入 `local_preferences`；已有新偏好不覆盖。旧 `plain` 材质归一为 `auto`，`zh-CN`/`en-US` 等语言值转为客户端支持的语言代码。
- 结构修改、偏好转换、外键校验、迁移记录和版本更新处于同一个事务。失败会回滚并保留备份；不会删除或重新生成图库身份、原有媒体记录、收藏及相册关系。升级代码不改写原始照片。
- 已是当前版本的图库直接打开，不重复升级或生成备份；比当前客户端更新的版本返回 `SchemaTooNew`，不自动降级或清库。

实现位于 `crates/photo-core/src/local_library/migrations.rs`，由 `LocalLibrary::open` 调用。

## 验证记录

只运行了与升级相关的 6 项检查：v1 数据/偏好/原文件保留与再次打开、v2 已保存偏好保留、升级失败回滚、备份失败不写库、首次初始化中断恢复、拒绝未来版本数据库。未运行全量用例。

真实环境使用原样命令 `./tools/run_app dev`，不传 `--headless` 或独立 `--data-root`：数据库已从 v1 升级至 v3，自动备份保留 v1 数据；图库身份和原有媒体记录保留，真实目录扫描后媒体数量增至 369。SQLite 完整性检查通过，外键检查无异常。通过运行中的客户端确认核心为 ready、图库已初始化、无图库错误且设置读取失败标记已清除；用户随后确认恢复正常。

本次备份保存在真实图库 `backups/library-v1-before-v3-1792583848984-edff24f6-e234-492f-8184-b9cd50f2699b.sqlite`。备份不进入 Git。

## 日常启动约定

dev、release 和人工验证均使用真实桌面、用户文件及真实设置。只有运行自动测试用例时才允许独立数据根、Xvfb 或打桩服务。完整启动命令及定向测试规则见根目录 [AGENTS.md](../../AGENTS.md)。

## 2026-10-22：v1/v2/v3/v4 → v5

通用元数据同步新增 `media_sync_state`、`cloud_metadata_operations` 与 `cloud_account_scope`，将 v4 的收藏专用布尔 dirty 迁移为通用操作状态、版本和编辑事件。现有账号、同步 token、绑定、上传意图及图库身份保留；旧 `favorite_dirty` 列移除，旧客户端由版本检查拒绝写入。

升级继续先用 SQLite backup API 备份，再在单个事务中执行表变更、数据迁移、偏好保留与版本更新。失败回滚，备份失败不写库；原照片文件不改写。本轮仅在隔离自动测试中升级，未启动应用升级真实图库。

v4 没有保存用户当次编辑事件，不能恢复精确的历史修改时间。对于既有 dirty 行，迁移使用该行最后记录的更新时间、安装来源和新迁移事件 ID，保留待办；后续新修改均使用实际本地编辑事件。既有未完成新增保留 `dirty=1`。

定向覆盖 v1/v2/v3 数据与偏好保留、v4 dirty/账号/token/绑定保留、备份原版本、升级失败回滚、备份失败不写库及首次初始化中断恢复。未来版本写保护另做定向检查；不运行全量用例。

## 2026-10-22：v5/v6 → v7

v6 补齐多账号与上传范围：`cloud_accounts` 增加 `upload_scope`、`is_active` 与唯一活动账号索引，`cloud_bindings` 增加远端元数据事件列，新增 `cloud_upload_albums`。

v7 补齐内容替换与永久删除义务：`media_sync_state` 增加 `path_dirty`、内容与删除各自的版本/确认版本/编辑时间/来源/事件列；`cloud_metadata_operations` 增加 `is_trashed`；新增 `cloud_content_operations`（冻结 generation、条件 revision、原图/缩略图摘要与捕获版本）和 `cloud_delete_operations`（冻结两记录 revision、删除事件与捕获版本）。元数据与内容共享 `dirty=2` 但版本独立，永久删除使用 `dirty=4` 并保留本地墓碑直到云端确认。

升级继续先备份再在单个事务中执行表变更、数据迁移和外键校验。v6 已由真实图库升级验证：备份为 `backups/library-v5-before-v6-1792668540858-5e3e4b9b-6f23-41bf-b4b6-3ca4998bca26.sqlite`。v7 在真实图库启动 Release 时完成升级：`user_version=7`，新表存在，备份为 `backups/library-v6-before-v7-1792674724831-27b533e6-ab26-4f39-ae15-9f6ca055215f.sqlite`；原有照片、绑定和账号保留。定向迁移用例覆盖 v1/v2/v3/v4/v6 到 v7 的数据保留、备份与失败回滚，不运行全量用例。

## 2026-10-24：v1–v7 → v8

v8 为 `cloud_accounts` 增加 `download_root` 列：云同步下行改为把照片按云端相对路径下载进用户选择的真实目录，每个账号各自记录该目录（见[云同步 MVP](../cloud-sync-mvp.md)）。列可空，空值表示尚未选择下载目录，同步以稳定错误码 `DownloadRootMissing` 拒绝运行；选择后经 `set_download_root` 校验（绝对路径、可创建、不得位于应用数据根内）并注册为普通 `linked_directory` 来源。

升级沿用同一模式：先以 SQLite backup API 写备份，再在单个事务中执行 `ALTER TABLE`、版本记录更新与外键校验，失败回滚。既有账号、绑定与同步状态原样保留；旧版受管 `cloud/` 布局中已下载的照片按开发阶段约定不做迁移，继续按原路径可浏览，直到执行“清理缓存与云端数据”一并移除。定向迁移用例覆盖 v7 → v8 加列、账号与数据保留、备份与回滚（`tests/local_library_migration.rs`），不运行全量用例。
