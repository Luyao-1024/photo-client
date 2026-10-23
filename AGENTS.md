# Photo Client 工作约定

本项目是 PhotoViewer 的 Flutter 界面 + Rust 核心重写。相邻 `../photoViewer` 是迁移前的 GTK 客户端；日常开发和启动以当前项目为准。

## 编译并启动当前代码

优先使用已有 `tools/run_app`，不要另造启动入口。用户要运行最新修改时，在项目根目录执行：

```bash
./tools/run_app release --build
```

该命令先构建 Rust 核心和 Flutter Release bundle，再启动客户端；构建失败会停止，不会继续运行旧版本。需要启动后返回终端时：

```bash
./tools/run_app release --build --background
```

脚本会输出应用 PID 和日志位置。dev、release 及其他正常启动和人工验证都必须在真实桌面运行，读取用户真实环境中的文件、目录、设置和默认图库；不得切换到打桩 gateway、临时图库或伪造 HOME/XDG 环境。仅运行自动测试用例时允许隔离环境。

其他用法：

```bash
# 直接启动已有 Release 产物；不会自动包含尚未编译的修改。
./tools/run_app release

# 开发模式：先构建 Rust，再启动支持 Flutter 热重载的前台会话。
./tools/run_app dev

# 查看完整参数。
./tools/run_app --help
```

`--x11` 可强制使用 X11/XWayland；默认优先使用当前 Wayland 会话。`dev` 不支持 `--background`。`--data-root` 会转换为绝对路径；开发模式受 Flutter 参数解析限制，路径不要包含逗号。

`--headless`、独立 `--data-root` 和 fake gateway 只供自动测试用例使用，不能代替真实环境启动或人工验收。

### Android

安卓端同样走 `tools/run_app`，不要另造启动入口：

```bash
# 构建 APK、安装到模拟器或设备、授予全文件与媒体权限、启动。
./tools/run_app android --build

# 用已有 APK 直接安装并启动。
./tools/run_app android
```

没有在线设备时脚本会用 `setsid` 拉起 AVD `photo36` 并等待引导完成；模拟器参数用 `--device`、`--avd`、`--no-avd`、`--gpu`、`--no-window`、`--window` 调整（默认无窗口、低内存模式，并关闭 Vulkan；`--window` 可恢复桌面窗口）。`--background`、`--data-root`、`--x11`、`--headless` 只适用于 Linux 桌面端。

安卓端的真实环境是设备本身：读取设备上的 `/sdcard/{DCIM,Pictures,Movies,Download}`，权限由系统授予，不伪造访问路径。工具链、模拟器基线、构建与验收步骤见 [Android 编译、运行与测试环境](docs/android/README.md)。

## 数据库版本升级

开发阶段允许并要求为受支持的旧版本添加明确的数据库升级逻辑。当前支持 v1/v2 → v3：先通过 SQLite backup API 将一致备份写入真实图库的 `backups/`，再在单个事务中补齐字段、表和偏好，并更新版本记录。保留原照片文件、图库身份、来源、收藏及相册关系；失败回滚，备份失败则不开始升级。不得因版本不匹配删库重建。未来版本数据库拒绝旧客户端写入，不做自动降级。实现与验证见 [数据库升级记录](docs/local-first/database-upgrade.md)。

## 工具链与依赖

- Flutter 优先使用显式 `PHOTO_FLUTTER_ROOT`，其次 PATH，最后本机默认 `${XDG_DATA_HOME:-$HOME/.local/share}/photo-client/flutter`。显式指定的 SDK 无效时会报错。
- `tools/platform` 负责平台配置生成与 Rust/Flutter 构建；`tools/prepare_linux_media.py` 为两种启动模式准备媒体依赖及链接环境。不要绕过这些步骤直接运行裸 `flutter run`，否则可能缺少平台定义、原生核心或媒体依赖。
- 系统只有 `libheif.so.1`、缺少开发链接名时，工具会在 `.tooling/media-link` 创建本地 `libheif.so` 别名并设置 `LIBRARY_PATH`。不再需要临时的 `glass-build-link` 或手动设置库路径；不修改系统库。
- 手动调用平台工具时，需要保证 Flutter 在 PATH 中或设置 `PHOTO_FLUTTER_ROOT`。构建产物位于 `app/build/linux/x64/{debug,release}/bundle/`，不要只复制其中的可执行文件。
- 安卓构建需要 `cargo-ndk` 与三个 Rust 安卓 target；`app/android/app/build.gradle.kts` 的 `ndkVersion` 必须等于 SDK 里实际安装的 NDK 版本。产物是 `app/build/app/outputs/flutter-apk/app-release.apk`。
- 本机 `/usr/lib/jvm/java-25-openjdk` 是 JRE，没有 javac，AGP 会失败；Gradle 与 Flutter 都指向 `~/.local/jdk/jdk-21.0.12.1+1`。`dl.google.com` 在本网络不可达，`~/.gradle/init.gradle` 把 Google Maven 重定向到可达镜像。

## 验证

### 测试范围约束

- 每次修改只运行与本次改动直接相关的用例，按受影响的文件、类、函数或用例名精确选择；共享接口变更只补充明确受影响的调用方用例。
- **禁止运行全量用例**，包括无范围的 `flutter test`、`cargo test --workspace`、覆盖全部测试的 unittest discover，以及完整验收矩阵。不得因提交、推送或发布而自动扩大测试范围。
- 纯文档修改只需校对内容与执行 `git diff --check`，不运行功能或 UX 用例，不触发无关构建。
- 相关用例已通过后，除非有新的相关改动、失败或未解决问题，不重复运行；提交说明应如实记录已执行范围和未执行项。

以下为脚本/依赖处理的定向检查示例，按实际改动选择相关命令，不要求每次全部执行：

```bash
bash -n tools/run_app
python3 -B -m unittest discover -s tests/platform -p 'test_run_app.py' -v
python3 -B -m unittest discover -s tests/platform -p 'test_prepare_linux_media.py' -v
```

仅自动测试用例使用独立 `--data-root`；实际启动及人工验证必须使用真实环境。构建成功、窗口启动、真实数据可用和真实桌面/GPU视觉验收是不同证据，报告时应说明实际完成的范围。
