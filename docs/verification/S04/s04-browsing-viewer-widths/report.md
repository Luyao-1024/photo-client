# S04 真实浏览与查看器 · 三宽度真实旅程验收

- 阶段：`S04 / 真实浏览与查看器`
- 计划版本：`local-first plan_version=2, phase=local`
- 技术门槛：`passed`（`report.json.gate_status = PASS`）
- 用户体验确认：`not_recorded`
- 构建摘要：release bundle；原生库 SHA-256 与 S02/S03 同批（Rust 未变）
- 环境：每旅程独立 Xvfb；宽度 390x844 / 800x600 / 1440x900（runner `--window-size`）；数据根 `/tmp/s04-final4/data-root-*`；夹具同 S03 的 `fixtures/`

## 阶段检查项

| 编号 | 实际操作/命令 | 结果 | 可观察事实 | 原始证据 |
|---|---|---|---|---|
| L04-01 | 三宽度 provision 旅程 | PASS | 网格由真实 FFI/SQLite 分页查询填充：total=6、page_size=100、渲染瓦片=6；瓦片 key 与数据库行 id 一一对应 | width-*/journey-width-*.log |
| L04-02 | 查看器真实输入序列 | PASS | 点瓦片打开→ArrowRight 到下一数据库行→previous 按钮回锚点→滚轮缩放 100%→221%→缩放按钮 125%/100%/156%→真实拖拽平移（矩阵位移 153.8px）→沉浸开关→Escape 回网格；三宽度均通过 | width-*/journey-width-*.log、05-immersive-x11.png |
| L04-03 | 收藏/元数据/重启 | PASS | 收藏后 favorites-only 原生查询 total=1 且 id 一致；详情对话框显示真实路径/字节数/尺寸；重启后（reopen 旅程）收藏与 LibraryId 保持且查看器仍解码真实像素 | reopen/journey-reopen.log、10-restart-favorite-x11.png |
| L04-04 | 390/800/1440 宽度 | PASS | 三宽度全流程完成、10 份截屏/宽度非空白；搜索“large”仅返回当前查询结果（total=1）；紧凑布局底部导航可用。hover 不误切相册属 S06（尚无手动相册） | width-390/800/1440 子目录 |
| L04-05（补充） | 外部删除源文件 | PASS | 删除 gamma.webp 后行仍索引；查看器显示不可用占位（broken_image_outlined）不崩溃；其余照片仍真实解码 | missing/journey-missing.log、20-missing-source-x11.png |

## 缺陷与未执行项

| 缺陷/检查项 | 严重性与影响 | 复现/原因 | 修复/重验入口 | 是否阻断 |
|---|---|---|---|---|
| 窗口级全屏 | 未执行 | 需窗口管理器；Xvfb 无 WM | 应用内沉浸浏览已验；窗口全屏留 S10/S11 与真实桌面 | 不阻断 |
| 沉浸按钮曾被 Stack 绘制顺序遮挡 | 已修复 | Positioned 子项在 Column 之前绘制导致不可命中 | 移至 Stack 末位；旅程 `viewer-immersive-toggle` 回归 | 已修复 |

## 结论与下一步

- 技术结论：S04 文档门禁四项 `passed`，补充项 L04-05 `passed`。
- 用户体验结论：`not_recorded`。
- 下一阶段：S05 十万图库前置性能（夹具 1千/1万/5万/10万）。
- commit/push/远端CI/安装：本地 commit 已推送 GitHub 公共仓库；无远端 CI；安装验收留 S11。
