# 全窗相册背景与完整液态透镜：2026-10-21

本轮继承[照片画布](photo-canvas-redesign.md)，根据第二轮反馈保留真实相册照片背景，改为覆盖全窗；取消固定蓝灰基调，适度恢复圆角，并加强实际折射。

## 阅读的代码示例与采用方式

核对当前锁定依赖 `liquid_glass_widgets` 1.14.0 的源码及 README，未升级依赖或修改 pub 缓存：

- README 的 Quality Modes：premium 是完整 Impeller 管线，固定工具栏适合使用；minimal 只有柔化，standard 为轻量近似。Linux 的静态能力策略直接封顶 standard，并不等待真实性能数据。
- `LiquidGlassSettings.ios27Light` / `ios27Dark` 示例：`GlassLensModel.paraxial`、32 厚度、1.24 折射率、独立 frost/blur、定向 rimShade/rimLight。按此结构使用 `copyWith` 派生项目角色，不再从一组几乎关闭光学效果的参数出发。
- `LiquidGlassWidgets.initialize()` 示例：在正常产品启动前异步预加载着色器，调试模式启用依赖的性能监测。
- `GlassAdaptiveScope` 的固定下界示例：小范围完整透镜通过局部 scope 的 premium 下界避免被全局静态策略替换成 standard；未使用 `skipStaticProbeForTesting`，未伪造平台或修改用户保存的材质偏好。
- 容器的嵌套示例：内容侧保留 `InheritedLiquidGlass.avoidsRefraction` 契约；搜索框等内层控件继承父级参数，通过 vibrancy 路径表现，不再申请自己的后景采样层。
- 旧 GTK 客户端的 `docs/modules/ui-liquid-glass.md` 仅复核角色及交互原则；其 CSS/GSK 实现不适用于当前 Flutter 光学材质。

## 最终外观

| 范围 | 当前实现 |
| --- | --- |
| 背景 | 当前目的地首张照片的缓存缩略图，512 解码宽度，`BoxFit.cover` 覆盖整个窗口；取消 760 宽度限制和向纯色底渐隐。 |
| 明暗 | 同一张照片经 sigma 18 的静态柔化，浅色叠白色 .72，深色叠黑色 .56；无额外蓝色底。照片自身的蓝天等颜色正常保留。 |
| 主题 | `DynamicSchemeVariant.monochrome`；填充、选择、按钮、焦点和提示均为中性色。 |
| 形状 | 照片 8、控件 12、面板 18、弹窗 24；侧栏内缩 8、工具栏内缩 12/8；使用 RoundedSuperellipse 透镜。 |
| 完整透镜 | 普通浏览固定侧栏、顶栏和年月日共三处请求 premium；各自独立渲染层，照片 tile 和导航行不增加折射层。 |
| 光学 | 焦点厚度 42、折射率 1.34、色散 .012、blur .6；其他玻璃厚度 32、折射率 1.26、色散 .006；paraxial 模型保留折叠边缘。 |
| 边缘 | 无应用绘制的普通描边，Fresnel 为 0；用 rimShade 1 和定向 rimLight .65 表现厚度。premium 保留完整形状边缘，standard 仍扩展后裁切固定白圈。 |
| 覆盖面板 | 基础 alpha 从 .88 改为 .52，范围 .42–.62；按原生示例使用 frost 14，避免近乎不透明的正文把折射盖住。 |
| 阅读与辅助 | Reading 仍为 .96 / 最低 .94；高对比不透明并取消背景图。轻量偏好仍将表面限制在 standard，固定透镜不会越过用户轻量选择。 |

三块固定 premium 表面比第一版的预算更激进，尤其窄窗下占比更高。本轮未测量持续滚动的 P75/P95 或十万图库性能，不宣称满足原 20% 面积预算或跨设备帧率指标。降 frost 的 scope 及调试性能监测仍在；用户可显式选择轻量。

## 验证

16 个不同的相关用例通过：

- `liquid_glass_evidence_test.dart`：4 个，包含 Linux ceiling 下 auto 的完整焦点透镜、reduced 上限、paraxial 参数及中性填充、Reading 与高对比。
- `library_backdrop_test.dart`：3 个，包含两种主题下 1600×900 的全窗背景、翻页稳定/异步旧结果/回收站清理、高对比无背景图。
- `responsive_widths_test.dart`：3 个，390/800/1440 的浏览、查看、收藏与返回。
- `settings_material_test.dart`：1 个，设置分类及墨水反馈。
- `presentation_test.dart` 精确选择：4 个，主题/语言/材质、页头左右对齐、分组滚动锚点、双倍文字。
- `library_actions_test.dart` 精确选择：1 个，搜索范围与查询；覆盖内层控件共享父级材质后的输入交互。

修改文件 Flutter analyze 和 `git diff --check` 通过。未运行全量测试、完整 UX 旅程或跨平台验收。

通过 `./tools/run_app dev` 在真实默认图库冷启动，未覆盖 HOME/XDG、未使用独立 data-root 或 fake gateway。检查真实旅行相册的明暗主题、滚动覆盖和完整透镜；用户保存的材质为 full，透明度约 .351，均保留；临时浅色预览后恢复原 `system` 主题。auto/reduced 的局部策略另外由定向用例验证。真实日志包含：

```text
Using the Impeller rendering backend (OpenGLESSDF).
[LiquidGlass] Initialization complete.
GLASS_LENS chrome/premium/frost=true
GLASS_LENS overlay/premium/frost=true
GLASS_LENS raised/premium/frost=true
```

`GLASS_EFFECTIVE standard` 仍可能代表外围自适应 scope；它不覆盖局部三块固定 premium 透镜，具体以 `GLASS_LENS` 和实际渲染树为准。截图从真实进程通过 Inspector 读回，保存在被忽略的 `.tooling/photo-canvas-review-v2/`；不将个人照片加入版本库，不将应用渲染读回称作系统合成器截图。

部分既有高像素照片仍因 128 MiB 解码预算出现占位，未修改媒体处理。检查期间一次 Flutter 热重启未能重新建立原生会话，完整进程冷启动恢复；本轮未调整原生生命周期。

`./tools/run_app release --build --background` 完成 Rust Release 和 Flutter Linux Release 构建；随后使用 `./tools/run_app release` 保持真实桌面会话。验证 Release 进程持续运行且打开真实默认图库的 SQLite/WAL/锁文件，三个固定材质角色均报告 premium。定向验证摘要在 `.tooling/photo-canvas-review-v2/report.json`。
