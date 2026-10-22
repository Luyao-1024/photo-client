# 播放与退出稳定性修复

日期：2026-10-23。范围：Linux 播放器加载、生命周期和播放时退出；保留现有动态照片、悬停控件及缩略栏渐变交互。

## 已确认的问题

- 2026-10-22 23:44:59 的 Release core：Flutter 引擎已进入销毁流程，libmpv 的 `wakeup_client` 仍调用已失效的 Dart 回调，触发 SIGSEGV。此前窗口关闭只等待图库核心关闭，播放器在组件 `dispose` 中异步释放，未纳入关闭屏障。
- 同日 23:49:20 的 Debug core：同一进程加载了 bundle 的 `libmpv.so.2` 和 `.tooling/media-runtime` 的 `libmpv.so` 两份实例，触发 `m_config_cache_from_shadow: group_index >= 0` 断言。定向复现确认，`media_kit_video` 的解码器查询会再次调用不带路径的 `NativeLibrary.ensureInitialized()`，使开发环境中的库搜索路径覆盖首次初始化。

## 修复

- `VideoPlaybackLifecycle` 登记活动播放器及尚未结束的释放任务。窗口关闭在销毁 Flutter 引擎前等待全部播放器释放；关闭期间拒绝创建新播放器。释放时先使异步回调失效并取消事件订阅。
- Linux runner 在 Dart 启动前用 `dlsym`/`dladdr` 找到视频插件实际加载的 libmpv，并设置 `LIBMPV_LIBRARY_PATH`。播放器也优先复用进程已映射的实例，避免开发依赖目录与 bundle 各加载一份。

## 定向验证

- 3 项生命周期/窗口关闭用例及 3 项查看器播放用例通过；相关文件静态检查通过。未运行全量测试或完整 UX 矩阵。
- 新增独立 `playback-lifecycle` 自动旅程，使用真实 GTK/Flutter、Rust 核心、SQLite、libmpv、视频纹理和 Wayland 桌面。仅自动测试使用生成的视频、动态照片及独立图库；输入方式为 `framework`，不等同于人工鼠标验收。
- Release 和 Debug 均完成 6 轮视频播放/关闭、6 轮动态照片播放/自动恢复，并在最后一次播放中关闭原生窗口。两次进程退出码均为 0，映射检查均只有一份 libmpv。Debug 保留了原先触发冲突的 `.tooling/media-runtime/usr/lib64` 库搜索路径。
- 报告：[Release](../verification/local-features/playback-stability/release.json)、[Debug](../verification/local-features/playback-stability/debug.json)。此范围内未再复现两处原生崩溃，不代表已验证所有媒体格式或长时间播放场景。

自动旅程参数为 `--local-journey --journey-phase=playback-lifecycle --data-root=<独立测试库> --source=<含视频与动态照片的测试目录> --evidence-dir=<证据目录> --input=framework`。正常启动仍使用 `tools/run_app` 和真实默认图库。

## 缩略栏与进度条悬停

同日补充修正显示时序：仅准备当前可见缩略图和相邻少量项目，等待缩略图解码完成后统一淡入；播放中悬停缩略栏可提前显示，移开后恢复隐藏，播放结束后保持显示。隐藏状态下的播放控件只接受进度条实际命中区域，页面底部和隐藏的播放按钮区不会将其唤出；显示后仍可移到播放/音量按钮操作。

10 项相关 widget 用例通过，覆盖分批准备时不提前露出、渐变中间透明度、悬停提前显示、拖动进度条及缩略图居中。新增 `playback-hover` 定向自动旅程，在 Xvfb/X11 软件 GL 的原生播放器窗口中使用实际鼠标事件验证区域独立、6 张可见缩略图均已解码、动态照片自动恢复和播放中退出，进程退出码为 0。报告见 [hover.json](../verification/local-features/playback-stability/hover.json)。该自动化不替代真实 Wayland/GPU 上的流畅度人工复核。
