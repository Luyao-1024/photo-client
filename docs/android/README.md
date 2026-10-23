# Android 编译、运行与测试环境

本文固定 Android 端的构建主机、工具链、ABI、模拟器和测试数据，使同一提交在满足条件的不同电脑上得到一致的可执行结果：相同的 profile 摘要、相同的原生库集合、相同的行为和验收步骤。

APK 的字节不要求一致：调试签名、打包时间戳和宿主路径都会不同。跨机对照以构建输出中的 `profile_digest`、APK 内的 ABI 列表和本文的验收步骤为准。

## 1. 支持范围与固定基线

| 项目 | 固定值 | 来源 / 检查方式 |
|---|---|---|
| 构建主机 | Linux x86_64 | `uname -sm`；`tools/platform` 会拒绝 Windows/macOS 主机 |
| 最低 Android | API 30（Android 11） | [build.gradle.kts](../../app/android/app/build.gradle.kts) |
| Flutter | 3.47.7 stable | `flutter --version` |
| Dart | 3.13.5 | `flutter --version` |
| Rust | 1.99.0（要求 ≥ 1.98） | `rustc --version`；[Cargo.toml](../../Cargo.toml) |
| cargo-ndk | 4.1.2 | `cargo ndk --version` |
| JDK | 25.0.4.1（最低 17） | `java -version` |
| Gradle | 9.3.1 | [gradle-wrapper.properties](../../app/android/gradle/wrapper/gradle-wrapper.properties) |
| Android Gradle Plugin | 9.1.0 | [settings.gradle.kts](../../app/android/settings.gradle.kts) |
| Kotlin | 2.4.0 | [settings.gradle.kts](../../app/android/settings.gradle.kts) |
| compileSdk / targetSdk | 36 / 36 | Flutter 3.47.7 的 `FlutterExtension` |
| minSdk | 30 | [build.gradle.kts](../../app/android/app/build.gradle.kts) |
| NDK | 27.0.12077973 | [build.gradle.kts](../../app/android/app/build.gradle.kts) |
| ABI | `armeabi-v7a`、`arm64-v8a`、`x86_64` | [android-universal.yaml](../../config/platforms/android-universal.yaml) |
| Android SDK 组件 | Platform 36、Build-Tools 36.0.0、Platform-Tools 37.0.0 | `sdkmanager --list_installed` |
| 模拟器 | Emulator 36.6.11，Android 37.0 x86_64 16 KB 页 | 见第 3.2 节 |
| Python | 3.14.8 + PyYAML 6.0.3 | `python3 -c 'import yaml'` |
| profile 摘要 | `3dcede2ccc8951fb4777f58feabca43910ed01f85671b02fdabb1b8248cfa7bf` | 2026-10-23、commit f0b903d 的实际构建输出 |

profile 摘要由 [android-universal.yaml](../../config/platforms/android-universal.yaml) 的规范化 JSON 计算。任何电脑只要 YAML 相同，构建输出的摘要就必须相同；摘要不同说明 profile 被修改过。摘要变化后必须按第 4 节重新构建并重新验收。

当前 active profile 的 host 校验要求 Linux x86_64；Windows/macOS 主机即使装了 Flutter/Android SDK 也会在 `tools/platform` 校验阶段被拒绝。本文中的“任何电脑”指满足第 1 节基线的 Linux x86_64 主机；若将来要支持其他构建主机，需要先修改平台配置与宿主校验，不能只改构建命令。

## 2. 保证一致性的规则

1. **只用 `tools/platform` 构建 Android。** 它负责生成 `PHOTO_PROFILE_*` dart-defines、交叉编译三份 Rust 原生库，并检查 APK 内 ABI。直接 `flutter build apk` 会缺少 profile 定义，安装后界面显示“照片加载失败”（底层是 `BuildProfileMissing`）。
2. **锁文件必须一起使用。** [Cargo.lock](../../Cargo.lock) 和 [app/pubspec.lock](../../app/pubspec.lock) 均已提交；Rust 构建使用 `--locked`，Flutter 依赖使用 `pub get --enforce-lockfile`。不要执行 `cargo update` 或 `flutter pub upgrade`。
3. **Gradle 与插件版本只能来自仓库。** 不要修改 wrapper 版本、AGP/Kotlin 版本或添加镜像仓库。
4. **NDK 只能使用 27.0.12077973。** Gradle 已固定该版本；`tools/platform` 在未设置 `ANDROID_NDK_HOME` 时会选择 SDK 中已安装的最高 NDK 版本。为保证跨机一致，必须显式设置 `ANDROID_NDK_HOME`，或只安装这一个 NDK。
5. **不要手工修改或提交生成物。** `.build/android-universal/`、`app/android/app/src/main/jniLibs/`、`app/build/`、`app/android/local.properties` 都是生成物且已被忽略。
6. **不要设置 `PUB_HOSTED_URL`。** 使用镜像会改写 `pubspec.lock` 中的下载地址，导致锁文件在不同电脑上不一致。需要代理时只设置 `http_proxy` / `https_proxy`。如果锁文件已被改写，从 git 恢复后再执行 `pub get --enforce-lockfile`。
7. **同一个应用数据只能由一个进程打开。** Android 端数据根固定在应用私有目录；启动新构建前先 `force-stop` 旧进程，不要双开或把该目录复制给另一个实例。
8. **不降级数据库。** 支持的旧数据库会自动升级到当前版本；新版本数据库不接受旧客户端写入。测试需要干净状态时应清理应用数据，而不是替换旧库。

## 3. 一次性环境搭建

### 3.1 主机依赖

需要 Linux x86_64 主机、可用的 `/dev/kvm`（模拟器）、Python 3、JDK 17+、Rust 与 Flutter。Android Studio 不是必需组件，但需要 Android command-line tools 提供 `sdkmanager` / `avdmanager`。

以下路径是示例，按本机安装位置替换。

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.0.12077973"
export PHOTO_FLUTTER_ROOT="$HOME/.local/share/photo-client/flutter"   # Flutter 3.47.7
export PATH="$PHOTO_FLUTTER_ROOT/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
```

安装固定版本的 Rust 目标与 cargo-ndk：

```bash
rustup toolchain install 1.99.0        # 多工具链时用 rustup override 指向它
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk --version 4.1.2 --locked
```

安装 Android SDK 组件。`sdkmanager` 位于 `$ANDROID_HOME/cmdline-tools/latest/bin/`；新机器需先从 Android 开发者网站下载 command-line tools 并解压到该位置。

```bash
yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses
sdkmanager --sdk_root="$ANDROID_HOME" \
  "platform-tools" \
  "platforms;android-36" \
  "build-tools;36.0.0" \
  "ndk;27.0.12077973" \
  "emulator" \
  "system-images;android-37.0;google_apis_playstore_ps16k;x86_64"
```

准备 Flutter 依赖：

```bash
cd app
flutter pub get --enforce-lockfile
flutter precache --android
```

### 3.2 固定模拟器

基线 AVD 名为 `Medium_Phone`，参数固定为：1080×2400、density 420、2 GB RAM、x86_64、Android 37.0（Google APIs Play Store）、16 KB 页大小。

```bash
# 已存在同名 AVD 时跳过；不要复用参数不同的 AVD
echo no | avdmanager create avd \
  -n Medium_Phone \
  -k "system-images;android-37.0;google_apis_playstore_ps16k;x86_64" \
  -d medium_phone

"$ANDROID_HOME/emulator/emulator" -avd Medium_Phone -no-snapshot -gpu host &

adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  sleep 2
done
```

启动后固定显示条件并核对环境；如有多个设备，先 `export ANDROID_SERIAL=emulator-5554`。

```bash
adb shell settings put system font_scale 1.0
adb shell cmd uimode night no
adb shell getprop ro.build.version.sdk   # 37
adb shell getconf PAGE_SIZE              # 16384
adb shell wm size                        # Physical size: 1080x2400
adb shell wm density                     # Physical density: 420
adb shell getprop ro.product.cpu.abi     # x86_64
```

应用语言跟随系统；需要固定截图文案时，同时在系统设置中固定语言并记录。

若主机 GPU 不受支持，可把 `-gpu host` 换成 `-gpu swiftshader_indirect`；这只是渲染后端差异，不改变功能验收条件。

### 3.3 环境自检

回到仓库根目录执行以下检查，全部符合第 1 节基线后再开始构建：

```bash
uname -sm                                  # Linux x86_64
flutter --version                          # Flutter 3.47.7 / Dart 3.13.5
rustc --version                            # 1.99.0
cargo ndk --version                        # 4.1.2
rustup target list --installed | grep android
java -version                              # 17+
python3 -c 'import yaml'
adb version
```

`PHOTO_FLUTTER_ROOT` 优先级最高；若未设置，`tools/platform` 只会在 `PATH` 中查找 `flutter`，不会自动使用其他目录的 SDK。

## 4. 编译

### 4.1 Release 构建

```bash
cd /path/to/photo-client
./tools/platform build --profile android-universal --mode release
```

脚本按顺序执行：

1. 校验 profile 与构建主机，生成 `.build/android-universal/profile.json` 和 `dart-defines.json`。
2. 用 `cargo ndk -P 30 build --locked -p photo-bridge` 编译三个 ABI，输出到 `app/android/app/src/main/jniLibs/`。
3. 用生成好的 dart-defines 执行 `flutter build apk --release --target-platform android-arm,android-arm64,android-x64`。
4. 检查 APK 中三份 `libphoto_bridge.so` 是否齐全，并打印 JSON 摘要。

成功输出示例（路径和摘要按本机实际值）：

```json
{"abis":["armeabi-v7a","arm64-v8a","x86_64"],"apk":".../app/build/app/outputs/flutter-apk/app-release.apk","mode":"release","native_libraries":{"armeabi-v7a":".../jniLibs/armeabi-v7a/libphoto_bridge.so","arm64-v8a":".../jniLibs/arm64-v8a/libphoto_bridge.so","x86_64":".../jniLibs/x86_64/libphoto_bridge.so"},"packaging_acceptance":"NOT RUN","profile_digest":"3dcede2ccc8951fb4777f58feabca43910ed01f85671b02fdabb1b8248cfa7bf","profile_id":"android-universal"}
```

`packaging_acceptance: NOT RUN` 表示安装包级别的验收没有自动化，必须按第 6.3 节在设备或模拟器上完成。构建成功、APK 内 ABI 齐全，不等于功能验收通过。

### 4.2 产物位置

| 产物 | 路径 | 是否提交 |
|---|---|---|
| Release APK | `app/build/app/outputs/flutter-apk/app-release.apk` | 否 |
| Debug APK | `app/build/app/outputs/flutter-apk/app-debug.apk` | 否 |
| 原生库 | `app/android/app/src/main/jniLibs/<abi>/libphoto_bridge.so` | 否，生成物 |
| profile 与 dart-defines | `.build/android-universal/` | 否，生成物 |
| 本机 SDK 路径 | `app/android/local.properties` | 否，生成物 |

`gradlew` 与 `gradle-wrapper.jar` 未提交，首次构建时由 Flutter 从 SDK 缓存补齐；`gradle-wrapper.properties` 已提交并固定 Gradle 9.3.1。不要手工替换 wrapper，否则不同电脑可能使用不同 Gradle 版本。

Debug 包用于需要 `run-as` 检查应用私有数据的场景：

```bash
./tools/platform build --profile android-universal --mode debug
```

两种模式都使用本机 Android debug keystore 签名，因此 debug 与 release 可以直接覆盖安装并保留应用数据。

### 4.3 构建后检查

```bash
unzip -l app/build/app/outputs/flutter-apk/app-release.apk | grep 'lib/.*/libphoto_bridge.so'

"$ANDROID_HOME/build-tools/36.0.0/zipalign" -c -P 16 -v 4 \
  app/build/app/outputs/flutter-apk/app-release.apk | tail -1
# 期望：Verification successful
```

第一条命令必须列出 `armeabi-v7a`、`arm64-v8a`、`x86_64` 三份原生库。16 KB AVD 上还必须通过 16 KB 对齐检查；64 位库（`arm64-v8a`、`x86_64`）的 `LOAD` 段对齐应为 `0x4000`，32 位 `armeabi-v7a` 不受 16 KB 页要求约束。

每次改动 Dart、Rust 或 profile 后重新执行 `tools/platform build`。它会先删除旧的 ABI 库再生成，不要手工复制或保留旧的 `libphoto_bridge.so`。`flutter clean` 不会清掉 `jniLibs`，因此也不要用它代替重新构建。

## 5. 安装与运行

```bash
export ANDROID_SERIAL=emulator-5554       # 多设备时必设

adb shell am force-stop com.photoviewer.photo_client
adb install -r app/build/app/outputs/flutter-apk/app-release.apk
adb shell am start -n com.photoviewer.photo_client/.MainActivity
```

如果换了一台电脑重新构建，debug keystore 与上一台不同，覆盖安装会报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`。此时只能先 `adb uninstall com.photoviewer.photo_client`，这会删除应用私有的数据库、偏好和回收站。

### 5.1 权限

应用和桌面版一样使用路径式图库，首次启动必须取得“所有文件访问权限”，否则权限门禁会阻止进入图库。手动操作路径：系统设置 → 应用 → PhotoViewer → 特殊应用权限 → 所有文件访问权限。

自动化测试设备可以用 adb 直接授权：

```bash
adb shell appops set --uid com.photoviewer.photo_client MANAGE_EXTERNAL_STORAGE allow
adb shell appops get com.photoviewer.photo_client MANAGE_EXTERNAL_STORAGE
adb shell pm grant com.photoviewer.photo_client android.permission.READ_MEDIA_IMAGES
adb shell pm grant com.photoviewer.photo_client android.permission.READ_MEDIA_VIDEO
```

`appops` 只用于自有测试设备，不应作为产品绕过权限的方式。应用启动时仍会通过系统接口检查真实授权状态。

### 5.2 数据根、日志与清理

数据根固定在应用私有目录；通过本文的构建与安装流程，不能像桌面端那样用 `--data-root` 改变：

```text
/data/user/0/com.photoviewer.photo_client/files/library
```

该目录包含 `library.sqlite`、缓存和回收站。Release 包不可调试，不能用 `run-as` 读取；Debug 包可以：

```bash
adb shell run-as com.photoviewer.photo_client ls -la files/library
```

Flutter 与 Android 崩溃日志：

```bash
adb logcat -c
adb shell am force-stop com.photoviewer.photo_client
adb shell am start -n com.photoviewer.photo_client/.MainActivity
adb logcat -v time | grep -E 'flutter|AndroidRuntime|photo_client'
```

原生核心当前不依赖 Android logcat 输出；需要核对数据库或缓存状态时，使用 Debug 包的 `run-as`。

重置到首次启动状态（**只对测试设备执行，会删除应用数据库、偏好和回收站**）：

```bash
adb shell am force-stop com.photoviewer.photo_client
adb shell pm clear com.photoviewer.photo_client
adb shell appops set --uid com.photoviewer.photo_client MANAGE_EXTERNAL_STORAGE allow
```

共享存储中的测试照片不会被 `pm clear` 删除。

## 6. 测试环境

### 6.1 固定测试素材

每次验收使用同一套素材和同一个目录，避免“这次能翻 6 张、下次 5 张”的不可比结果。建议使用 6 张图片（至少 1 张 HEIC）和 1 段短 MP4，共 7 项。

```bash
mkdir -p /tmp/android-fixtures
for i in 0 1 2 3 4; do
  convert -size 1200x900 "xc:hsl($((i * 55)),75%,55%)" \
    -gravity center -pointsize 96 -fill white -annotate 0 "P$i" \
    "/tmp/android-fixtures/IMG_000$i.jpg"
done
ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30 -t 4 \
  -c:v libx264 -pix_fmt yuv420p /tmp/android-fixtures/clip.mp4
# 仅当 ImageMagick 带 HEIC 支持时：
convert /tmp/android-fixtures/IMG_0000.jpg /tmp/android-fixtures/IMG_HEIC_0000.heic

adb shell mkdir -p /sdcard/DCIM/PhotoClientE2E
adb push /tmp/android-fixtures/. /sdcard/DCIM/PhotoClientE2E/
```

HEIC 生成失败时另放一张 HEIC 样图，使总数保持 7 项；确实无法提供时按实际数量验收并记录。

在应用内添加来源时选择 `/storage/emulated/0/DCIM/PhotoClientE2E`。应用直接扫描路径，不需要系统媒体库先收录；如需让系统相册也看到这些文件，可逐个发送扫描广播：

```bash
adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
  -d file:///sdcard/DCIM/PhotoClientE2E/IMG_0000.jpg
```

素材属于测试设备，不要放私人照片；卸载应用不会删除这些文件，需要时应手动清理该目录。

### 6.2 自动化测试

主机侧 profile 校验与 Linux 构建编排测试（不需要模拟器）；Android 的打包正确性由第 4 节的构建检查覆盖：

```bash
python3 -B -m unittest discover -s tests/platform -p 'test_platform.py' -v
```

Flutter 组件测试（在 `app/` 下执行）：

```bash
cd app
flutter test test/mobile_layout_test.dart
```

该文件覆盖手机三列网格、Android 滚动不拉伸、手机查看器滑动翻页、相册页收藏/回收站等。改动视频控件或查看器时，再按实际影响选择：

```bash
flutter test test/hover_video_controls_test.dart
flutter test test/viewer_playback_test.dart
flutter test test/progressive_media_test.dart
```

仓库没有 Android instrumentation 或端到端 UI 用例；组件测试使用 fake gateway，只能证明界面逻辑正确，不能代替真机验收。按 [AGENTS.md](../../AGENTS.md) 只运行与本次改动直接相关的用例，禁止全量测试。

### 6.3 手工验收清单

每次 Android 交付至少执行以下流程，并在验收记录中写明 AVD、提交号、profile 摘要和使用的命令。

| 步骤 | 操作 | 通过标准 |
|---|---|---|
| 权限 | 清空数据后首次启动 | 出现权限门禁；授权后返回并重新检查可进入图库；未授权时不会伪造访问 |
| 图库 | 添加测试目录 | 7 项素材全部出现；三列网格；快速滚动不拉伸变形 |
| 查看器 | 左右滑动 | 文件名与 `N / 7` 随滑动变化；没有左右箭头、胶片条、缩放和沉浸按钮 |
| 查看器 | 点按、捏合、菜单 | 点按隐藏/恢复头部；双指缩放后滑动不翻页；更多菜单含编辑、照片信息、移到回收站 |
| 视频 | 打开 `clip.mp4` | 点按只出现播放/时间/进度条；控件显示时拖动进度条不翻页；约 3 秒自动隐藏后左右滑动可翻页 |
| 相册 | 收藏、回收站、搜索 | 收藏与回收站位于相册页内；创建、重命名、排序、搜索可用 |
| 编辑 | 裁剪/旋转并保存副本 | 保存副本成功；返回时未保存修改有确认 |
| 重启 | 强制停止后重新打开 | 图库、收藏、相册和数据库版本保持；已授权时不再拦截 |

视觉是否完全一致受 GPU 与驱动影响；功能和布局以本文固定 AVD 的截图做对照。

### 6.4 证据

```bash
adb exec-out screencap -p > /tmp/android-viewer.png
adb shell dumpsys package com.photoviewer.photo_client | grep -E 'versionCode|versionName|minSdk|targetSdk'
```

验收记录至少包含：提交号、构建命令与 `profile_digest`、三 ABI 检查结果、AVD 参数、7 项素材清单、上述流程的截图。不要提交 APK 或 `jniLibs`。

## 7. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `toolchain: Flutter not found` | SDK 不在 PATH，且未设 `PHOTO_FLUTTER_ROOT` | 设置 `PHOTO_FLUTTER_ROOT` 或加入 PATH |
| `toolchain: Android NDK not found` | 未安装 NDK 或 `ANDROID_NDK_HOME` 无效 | 安装 27.0.12077973，并显式设置 `ANDROID_NDK_HOME` |
| `toolchain: cargo-ndk not found` | 未安装或不在 PATH | `cargo install cargo-ndk --version 4.1.2 --locked` |
| `expected native library missing` | 交叉编译失败或 ABI 不齐 | 重新执行 `tools/platform build`，不要手工复制库 |
| 安装后显示“照片加载失败” | 用了裸 `flutter build apk`，缺少 `PHOTO_PROFILE_*` | 改用 `tools/platform build --profile android-universal` |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 新电脑的 debug keystore 不同 | 先卸载再安装；卸载会删除应用数据 |
| 一直停在权限门禁 | 未授予所有文件访问权限 | 系统设置授权，或测试设备执行第 5.1 节 `appops` |
| 模拟器启动失败或极慢 | 无 KVM 或 GPU 后端不兼容 | 确认 `/dev/kvm` 可访问；改用 `-gpu swiftshader_indirect` |
| 截图尺寸/布局与文档不符 | AVD 参数被改过 | 重新创建 `Medium_Phone`，核对 `wm size` 与 `wm density` |
| `pubspec.lock` 出现镜像 URL | 设置了 `PUB_HOSTED_URL` | 取消该变量，从 git 恢复锁文件，再 `pub get --enforce-lockfile` |
| 构建时报 Java 版本错误 | JDK 低于 17 或未被 Flutter 识别 | 安装 JDK 17+，设置 `JAVA_HOME` 或 `flutter config --jdk-dir` |
| 16 KB 设备上原生库加载失败 | 原生库未按 16 KB 对齐 | 重新用固定 NDK/cargo-ndk 构建，执行第 4.3 节检查 |
| 数据库被占用 | 旧进程未退出 | `adb shell am force-stop com.photoviewer.photo_client` 后重试 |

## 8. 本文的验证记录

2026-10-23，在 Linux x86_64、Flutter 3.47.7、Rust 1.99.0、JDK 25.0.4.1、NDK 27.0.12077973、`Medium_Phone`（Android 37.0，16 KB 页）上完成了：

- Release 构建成功，输出 `profile_digest=3dcede2...`，APK 内含三 ABI 的 `libphoto_bridge.so`；
- APK 通过 `zipalign -P 16` 校验，`arm64-v8a` 与 `x86_64` 原生库的 `LOAD` 段对齐为 `0x4000`；
- 安装、授权、启动后验证照片网格、查看器滑动、视频播放/进度拖动、控件隐藏后翻页；
- `mobile_layout_test.dart` 6 个用例通过。

未执行项：本文件没有新增或修改 Android 自动化端到端套件；安装级别的人工验收仍按 6.3 节逐次记录。
