# M17 液态玻璃 UX 与视觉系统

当前外观及固定透镜策略以 [2026-10-21 全窗照片与完整透镜修订](../../local-first/photo-canvas-liquid-material.md)和共享 token 为准；下文的蓝灰配色、旧半径、单焦点与 20% 面积预算保留为早期设计记录，不代表本轮已完成的性能验收。

照片页最新布局见[标题与操作菜单](../../local-first/photo-page-actions.md)：页头已拆为无底板文字及独立圆形搜索/菜单按钮，年月日胶囊为 216 宽。

覆盖滚动、灰色面板与相册面板上下对齐、整窗透明圆角及相册背景渐变以[悬浮与圆角修订](../../local-first/photo-floating-window.md)为准；照片面板圆角在包含标题/留白的外层实现。

## 职责与范围

确定新客户端统一的液态玻璃风格、布局层级、动效、可读性和渲染预算。照片保持内容主体，玻璃用于导航与操作表面；主题、材质质量和透明度是独立设置。

参考旧项目[液态玻璃模块](../../../../photoViewer/docs/modules/ui-liquid-glass.md)的共享材质、单胶囊分段器、焦点与照片覆盖控件规则；Flutter 重新实现，不搬 GTK CSS。设计与预算参考见[token 文件](../ux/glass-tokens.json)；运行时共享颜色与几何已落在 `GlassTheme` ThemeExtension，角色透明度与渲染档位由 `GlassSurface` 统一解析。

材质实现不自研：采用 `liquid_glass_widgets`（MIT，显式支持 Android/Linux/Windows/macOS/Web）作为渲染层，折射透镜、镜面高光、Fresnel 边缘与色散由它的 fragment shader 提供；本项目只负责角色、token 映射、档位策略与可读性约束。项目代码只做薄封装（`GlassSurface`），不复制其 shader。

## 接口与数据

```text
GlassTheme { color_scheme, accent, user_mode, transparency, reduce_motion, high_contrast }
GlassCapabilities { live_backdrop, clip_supported, estimated_cost_tier }
GlassPolicy.resolve(theme, capabilities, recent_frame_budget) -> EffectiveMaterial
GlassSurface(role, shape, interaction_state, content)
```

user_mode 为 auto/full/reduced；默认 auto。auto 才会按持续帧预算降级；full 是用户显式请求，不得被平台启发式静默降级。不存在纯色材质模式：所有表面都是半透明或高不透明度填充，降级只改变折射与高光强度，不改变层级、圆角、焦点和交互。

三档映射到 `liquid_glass_widgets` 的渲染档：full→premium（完整折射+色散+镜面高光）、reduced→standard（轻量 shader，无纹理捕获）、auto→由自适应范围在 minimal/standard/premium 之间按实测帧预算决定。该包的静态探测在 Web/Windows/Linux 上会封顶到 standard（ANGLE 运行时编译多趟 SDF 可能卡住光栅线程）；Android 不封顶。full 通过把自适应范围的下界抬到 premium 抵消该封顶，帧预算吃紧时先撤掉 frost，材质仍是 premium 外观。

公开质量选项为“自动/液态玻璃/轻量”和透明度；auto 可显示“自动”质量。有效档位与降级原因必须能在诊断日志中读到（`GLASS_QUALITY` 行），用户设置不因降级被覆盖。

## 流程与状态

### 材质层级

| 层级 | 用途 | 材质与性能策略 |
|---|---|---|
| Content | 照片网格、图像本体 | 无实时背景模糊、无逐图多层阴影；稳定裁切与轻量选中描边 |
| Chrome | 侧栏、导航背景、状态区域 | 有色半透明填充、静态柔和背景、细边与顶部高光；固定区域可缓存 |
| Raised | 浮动工具栏、模式分段器、查看器控制 | 裁切范围内真实 backdrop blur、边缘光和克制阴影 |
| Overlay | 菜单、popover、小型操作面板 | 单一可见玻璃表面，阴影外边距保持透明，避免嵌套双面板 |
| Reading | 设置表单、长文本、错误说明、模态正文 | 更高不透明度，低模糊或不模糊，保证文字对比度 |

采用窗口内部玻璃，不宣称 Linux 透明窗能够直接模糊桌面/其他应用。背景不做持续流动噪声或跟随每张照片取色；主题变更时一次性更新静态装饰。

### 外观和控件

间距为 4/8/12/16/24/32；小控件圆角12、面板20、对话框24、胶囊完全圆角。照片网格间距初设8，圆角8；照片边缘无透明内边距或玻璃边框，不暴露白线。

Light 使用低饱和浅灰底、深色文字和白色局部高光；Dark 使用深蓝灰底、浅色文字。高光始终偏白、阴影始终黑，不随主题反转成暗色高光。accent 优先系统可用值，无则用统一蓝色 fallback。

分段模式控件是一个 raised 胶囊，等宽命中区，选中使用文字/短指示线或轻量移动指示器；不为每段叠一个厚实玻璃块。任务详情箭头、暂停和账号菜单各有独立命中区。

照片覆盖按钮用局部暗色 scrim 与白色前景，收藏为填充心形；hover/pressed/selected/focus/disabled 状态各自明确。不能每帧读照片像素来决定文字颜色。hover 不改变分组或选中项，focus 不依赖玻璃透明边界。

透明度strength取0–1，alpha=`clamp(base_alpha + (1-2*strength)*0.10, role_floor, ceiling)`。液态玻璃的主体是空气：Chrome 的 base_alpha 为 0.25，范围 0.12~0.40；Raised 为 0.40，范围 0.32~0.50；Overlay 为 0.88，范围 0.86~0.94；Reading 为 0.96，范围 0.94~0.98。高对比时全部为 1.0。主体越不透明，折射与高光越被压死，材质会退化成"带亮边的实心面板"——这是上一版最严重的缺陷。主题、slider与材质模式共同解析，不同页面不得各写一套映射。

普通文字目标对比度≥4.5:1、大字号/控件关键边界≥3:1；在明亮/暗色/高对比照片背景上验证。Reading 填充不低于 token 的安全 alpha floor，用户透明度滑块不得把表单文字变不可读。

### 动效

hover约120ms、press约90ms、材质/选中约180ms、面板进出220ms；只做opacity/transform和小范围指示器移动，避免在过渡中逐帧改变大区域blur sigma。

reduce_motion 时删除空间滑动/缩放，保留即时状态或≤80ms淡变。选择器中途反向操作从当前视觉值继续，不跳回起点；所有动效可打断。高对比模式使用高不透明度/明确描边；跟随平台辅助设置并允许用户加强。

## 模糊与合成预算

full 必须包含精确裁切的后景折射、静态边缘高光/镜面渐变和浮起层次，按压/选中保持短暂可打断反馈。折射与色散由 `liquid_glass_widgets` 的 shader 提供，本项目不自研 shader；整窗动态折射仍不列首版依赖。

该包 premium 档用 `toImageSync` 抓取后景纹理，因此 premium 表面必须自带渲染层（`useOwnLayer`），不能与自身捕获重叠；同一栈内多个 premium 表面各自捕获自己的后景。Reading 与大面积 Chrome 走不采样后景的路径，避免为看不见的模糊付出整帧代价。

所有 BackdropFilter 必须有精确 ClipRect/ClipRRect，避免过滤整个窗口。

普通浏览同屏实时backdrop表面最多3个、合计面积不超过viewport的20%。侧栏大面板采用缓存/静态材质；照片tile和逐项badge不用BackdropFilter。模态表面超出普通面积预算时停止其后的动态玻璃并降低模态blur，Reading提高填充不透明度。

共享后景只在不重叠表面使用 BackdropGroup/分组滤镜优化；重叠表面不得复用同一 backdrop key。ImageFiltered 仅模糊自己的装饰内容时使用，不能用它冒充真实后景模糊。

禁止全屏嵌套saveLayer、逐tile ShaderMask/多层Opacity、无限呼吸动效、滚动时逐图截图/像素下载。RepaintBoundary 只隔离真实需要独立重绘的可见子树，不为十万逻辑项预建层。

auto 的质量控制交给 `liquid_glass_widgets` 的三阶段适配器：静态探测（能力）→ 预热基准（180 帧 P75）→ 运行期迟滞（120 帧窗口 P95，超预算连续 2 窗降一档，连续 10 窗升一档，8 秒冷却）。降级只动档位不关材质本身；用户选 full 时该适配器只允许撤 frost，不允许降到 standard 以下的外观档。

验收同时测 full 固定模式和 auto；默认 auto 一直退到 standard 才能达标时，报告为玻璃预算未达成，需要继续优化，不能只公布平均FPS。

## 异常与恢复

后端不支持/驱动异常时使用最低强度的半透明材质并记录原因；页面仍可用。滤镜和动效变化不重建Engine、不触发同步配置变更。偏好在首帧前加载，避免先闪亮色/错误材质再切换。

透明/折射视觉必须在真实合成桌面、打包应用中截图和输入验证；headless widget snapshot可证明布局，不能证明最终GPU玻璃效果。与参考旧项目的截图测试边界保持一致。隔离验证用一个不依赖本项目的最小实验应用：彩色背景图 + 叠放胶囊，自带截图输出，用于在目标平台（Linux 桌面 / Android 模拟器）上判断材质本身是否成立。

## 验收

- T17-01：明暗主题×full/reduced×三宽度，层级和几何一致。
- T17-02：代表性照片背景的对比度、焦点、hover/pressed/disabled和无白边。
- T17-03：10万图库full/auto同时测帧耗时、blur面积/数量与降级轨迹。
- T17-04：高对比/reduce motion与透明度安全下限有效。
- T17-05：账号/暂停/分段器等真实输入无误触，快速反向动效无跳变。
- T17-06：真实合成桌面验证材质，headless证据不冒称GPU效果通过。

## 官方技术依据

本轮已读取BackdropFilter官方文档，核对精确裁切、非重叠表面分组、重叠key限制和ImageFiltered语义：

- `https://api.flutter.dev/flutter/widgets/BackdropFilter-class.html`
- `https://docs.flutter.dev/perf/best-practices`

材质实现依据 `liquid_glass_widgets` 的公开实现与文档（MIT，1.14.0）：档位语义、`GlassAdaptiveScope` 的三阶段适配、`ImageFilter.isShaderFilterSupported` 探测、OpenGL ES 纹理朝向兼容（`gles_compat.glsl`，对 Flutter 3.44/3.45 与 3.46+ 两种约定自适应）：

- `https://pub.dev/packages/liquid_glass_widgets`
- `https://github.com/sdegenaar/liquid_glass_widgets`

本页参数是项目预算与已实测结果，不是GPU实测结论；实际档位与降级原因以运行日志的 `GLASS_QUALITY` 行为准。

## 2026-10-21 覆盖统一

对照旧客户端 `docs/modules/ui-liquid-glass.md`，本轮补齐此前默认 Material 弹窗/菜单和玻璃主界面之间的断层。

- `GlassTheme` 统一材质色、边缘、阴影、内部分组和选中状态；按钮、输入框、Chip、ListTile、提示与下拉菜单复用主题几何。窗口只使用静态低饱和背景，不添加持续动画。
- 侧栏与页面工具栏改为留出外边距的圆角表面；相册行与导航行共享轻量选中和按压反馈，无逐行玻璃滤镜。
- `GlassDialog`/`GlassAlertDialog` 让设置、文件选择、快捷键、确认、重命名、相册选择和网格详情各自只有一个可见材质层。菜单复用 Flutter 原生路由的定位、键盘导航、Esc 和点外关闭，行内不增加玻璃滤镜。
- 相册选择使用可滚动的真实封面网格，保留新建入口；少量相册按实际行数收缩高度。
- 查看器工具栏与胶片条使用 Raised；详情、编辑面板使用 Overlay，正文更高不透明度；减少动画时详情面板取消滑入。
- 年/月/日与搜索范围都采用单容器、文字加短指示线，不再给搜索的每段叠选中底块。照片内容和网格不加玻璃滤镜。

记录与本轮验证范围见[视觉统一记录](../../local-first/glass-ux-unification.md)。
