# 照片画布与无白边玻璃：2026-10-21

后续外观以[全窗照片与完整透镜修订](photo-canvas-liquid-material.md)为准；下文保留第一轮设计及验证记录。

本轮根据真实桌面反馈调整 [上一轮玻璃 UX](glass-ux-unification.md)。目标是让材质服务照片浏览：窗口形成连续画布，照片保持清晰，导航与覆盖内容的控件通过透色和阴影形成层次。

## 布局与材质

- 侧栏贴合窗口，不再是带外边距的大圆角盒子。导航选中使用轻底色和短色标，去掉选中行描边；设置入口与其他导航行一致。
- 页头改为覆盖滚动内容的通栏玻璃，标题和项目数量明确层级。照片真实经过页头下方，不再只折射一块空白背景。文字放大时页头随之增高。
- 当前目的地的第一张照片提供低分辨率背景：只请求缓存的 256 缩略图，解码宽度限制为 256；对宽度最多 760 的静态图像做柔化、明暗遮罩和横向渐隐。照片网格不加模糊。翻页不会反复换背景；切换目的地、首图版本变化或首图删除时更新；空结果和回收站不保留上一目的地的背景。
- 移除 `GlassSurface` 的普通描边，关闭 Fresnel 与 rimLight。依赖 1.14.0 的 standard shader 仍硬编码 0.5 逻辑像素白边并叠加抗锯齿，故将材质背景向外扩展 2 逻辑像素，再用实际圆角矩形裁切；内容尺寸和命中区域不扩大。保留内部折射，未修改全局依赖缓存。高对比模式仍有明确轮廓和不透明面板，且不画照片背景。
- 半径统一为照片 4、控件 6、面板 10、弹窗 12；页头与导航为 0。查看器、胶片条、编辑面板及年月日工具条使用相同的面板半径。窗口控制去掉圆形底座。
- 日期分组标题从 22 调为 16，主标题为 24，减少日期对照片的视觉竞争。保留用户已保存的日视图列数。
- 滚动锚点考虑覆盖式页头高度，并按新旧行高的比例保留行内位置，避免切换分组后当前照片完全藏到页头下方。

共享参数同步在 `docs/design/ux/glass-tokens.json`。

## 定向验证

21 个相关用例通过，未运行全量测试：

| 范围 | 已通过用例 |
| --- | --- |
| `liquid_glass_evidence_test.dart` | 2 个：材质角色、不透明度边界和高对比 |
| `responsive_widths_test.dart` | 3 个：390/800/1440 宽度下浏览、查看、收藏、返回与 hover |
| `settings_material_test.dart` | 1 个：设置分类、墨水反馈和快捷键弹窗 |
| `presentation_test.dart` 精确名称选择 | 6 个：目的地导航、窄窗折叠、主题语言与玻璃设置、页头左右对齐、覆盖页头下的分组滚动锚点、双倍文字 |
| `library_backdrop_test.dart` | 2 个：翻页稳定、异步旧结果隔离及回收站清理；高对比不加载背景图 |
| `window_frame_test.dart` | 2 个：窗口操作和全屏恢复 |
| `viewer_filmstrip_test.dart` | 1 个：当前胶片缩略图居中 |
| `library_actions_test.dart` 精确名称选择 | 4 个：批量删除恢复、搜索范围、搜索隐藏日期工具、编辑保存 |

修改文件的 Flutter analyze 与 `git diff --check` 通过。

## 真实环境检查与边界

使用 `./tools/run_app dev` 启动真实默认图库，未设置临时 HOME/XDG、独立图库或 fake gateway。图库显示 369 项；进入实际旅行相册（142 项）检查照片背景及滚动覆盖页头，分别检查浅色与深色，再恢复用户原先的 system 主题设置。

真实进程日志报告 Wayland、Impeller/OpenGLESSDF，自动材质档位最终为 standard。截图通过 Flutter Inspector 从该进程读回，保存在被忽略的 `.tooling/photo-canvas-review/`，不将个人图库照片加入版本库。这证明当前应用的渲染结果，不等同于系统合成器截屏、premium 完整折射验收或跨设备性能测试。

检查中有部分高像素照片返回既有的 `DecodeBudgetExceeded: image exceeds the 128 MiB thumbnail decode budget`，因此出现占位块；本次未改媒体解码预算，不将这些占位块视为成功加载。未执行完整 UX 旅程、全量测试或跨平台验收。

Release 通过 `./tools/run_app release --build --background` 完成 Rust Release 与 Flutter Release 构建。后续使用 `./tools/run_app release` 保持真实桌面会话，检查进程持续运行且实际打开默认图库的 `library.sqlite`、WAL 和图库锁；未使用独立数据目录。
