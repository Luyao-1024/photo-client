# 液态玻璃隔离台架（glasslab）

这是 Photo 客户端「液态玻璃」材质的**最小隔离实验**：不依赖 Photo 客户端本体，只用一张彩色背景图 + 一叠玻璃胶囊，把材质渲染结果输出成 PNG，用真实像素判断折射、暗边与分辨率。

它存在的理由：应用里的玻璃面是半透明叠在照片上的，截图难以区分「玻璃真的折射了」和「只是半透明变暗」。台架把背景换成高饱和的渐变+圆点场，折射、位移、色散、暗内带一眼可辨。

## 目录内容

| 路径 | 说明 |
| --- | --- |
| `lib/main.dart` | 台架本体：3 个档位胶囊（premium / standard / minimal）+ 包自带的 `GlassSegmentedControl` / `GlassButton` / `GlassSlider` |
| `assets/backdrop.png` | 1600×1000 彩色渐变+圆点背景（PIL 生成），真实折射才看得出来 |
| `test/widget_test.dart` | 结构检查：档位与胶囊的接线关系（headless 跑不了 shader，**不做像素比对**） |
| `android/` `linux/` | Flutter 工程壳，供真机/桌面运行 |
| `pubspec.yaml` | 依赖 `liquid_glass_widgets: 1.14.0`（与客户端本体同版本） |

## A–F 六个演示项

| 标记 | 内容 | 对应客户端职责 |
| --- | --- | --- |
| A | premium 胶囊 | 悬浮主控件（模式选择器），完整材质 |
| B | standard 胶囊 | 窗口 chrome |
| C | minimal 胶囊 | 阅读面板（近不透明，保证可读性） |
| D | `GlassSegmentedControl` | 包自带控件 |
| E | `GlassButton` | 包自带控件 |
| F | `GlassSlider` | 包自带控件 |

配方与客户端本体 `app/lib/ui/glass_surface.dart` 一一对应（premium：`thickness 16 / blur 2 / chromaticAberration 0.004 / rimLight 0.35 / rimShade 0.9 / edgeAbsorption 0.035`）。

## 运行

```sh
# 依赖
flutter pub get

# Linux 桌面：直接看窗口
flutter run -d linux

# Linux 桌面：自动截图后退出
flutter build linux --debug --dart-define=SHOT=/tmp/glass.png
DISPLAY=:0 ./build/linux/x64/debug/bundle/glasslab
# 日志会打印：GLASS_SHOT /tmp/glass.png 1280x720
```

```sh
# Android
flutter build apk --debug --target-platform android-x64
adb install -r -t build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n dev.photo.glasslab/.MainActivity
adb shell screencap -p /sdcard/android_shot.png && adb pull /sdcard/android_shot.png
```

> Android 上应用内直接写 `/sdcard` 会因 scoped storage 报 `PathAccessException`，所以走 `adb shell screencap`。

## 验收要点

1. 背景的圆点与色块在胶囊边缘应出现**位移与放大**（折射），而不是简单变模糊。
2. 胶囊边缘应有一圈**暗内带**（`rimShade`），高光克制，不应出现等亮白边。
3. 胶囊内文字必须清晰可读，不能因为 `blur` 而糊掉。
4. `standard` / `minimal` 与 premium 的差异应是「折射强度」而不是「整体明暗」。

## 已知约束

- `flutter test` 跑在 Skia 上，`ImageFilter.isShaderFilterSupported` 为 `false`，包会降级为「只渲染子组件、无玻璃效果」；**headless 快照不能证明 GPU 玻璃效果**，像素结论必须来自上面两条真机/桌面命令的输出。
- 本台架未接入 `GlassAdaptiveScope`，因此质量档位是逐面硬编码的，用于把每一档配方单独看清楚。

## 相关文档

- 结论与截图：[`../report.json`](../report.json)
- 设计模块：`docs/design/modules/17-liquid-glass.md`
- 客户端封装：`app/lib/ui/glass_surface.dart`
