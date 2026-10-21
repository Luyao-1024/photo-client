# 固定液态玻璃与三项外观设置：2026-10-22

- 材质固定 premium，移除自动/轻量切换和旧客户端质量策略；范围上下界均为 premium，关闭自动档位及 frost 切换。旧 `glassMode` 偏好不再参与 Flutter 呈现，保留旧数据兼容。阅读、高对比和内层控件共享材质的安全规则保留。
- 外观页仅有透明度、背景虚化程度、跟随滚动三项。主题与减少动画保留在通用页。
- `backgroundBlur` 为 0–1，默认 .5，映射背景 Gaussian sigma 0–36；不改玻璃透镜参数。
- `followScroll` 默认 true；关闭时取消待处理视口目标并渐变回保存的相册封面，无封面则首图。关闭期间忽略滚动，重新开启后采样当前视口。不会改写封面。
- 两项新偏好经过现有 JSON 接口保存；原生层校验数值范围和布尔类型，无需变更图库 schema。同步更新 UX 校验器，未运行完整旅程。

14 个定向用例通过：Flutter 10 个（固定材质/高对比、三项控件和重开恢复、背景虚化与封面回退、开关跟随、通用设置和分类交互），Rust 2 个（SQLite 重开持久化、非法值拒绝），Python 2 个（UX 校验器契约）。修改文件 analyze 和 diff check 通过，未运行全量测试。

使用 `./tools/run_app dev` 在真实默认图库检查了外观页，未使用独立 data-root 或 fake gateway；真实日志仅报告 premium，截图为 Inspector 渲染读回，保存在忽略目录 `.tooling/fixed-appearance-review/`。最终使用 `./tools/run_app release --build` 构建并启动。
