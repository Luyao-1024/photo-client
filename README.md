# Photo Client

PhotoViewer跨平台重写：Flutter界面、独立Rust核心与SQLite。**一期先完成纯本地照片功能，云同步留到二期。** Linux先交付；Android已接入并通过固定环境验收（见[docs/android/README.md](docs/android/README.md)）；Windows通过平台配置和适配器后续接入。

一期重点：本地目录/文件接入、十万张以内流畅浏览、查看器/收藏/相册/搜索、文件管理和编辑，以及统一液态玻璃UX。本地图库身份独立于云账号，不要求登录或网络。

- [当前一期本地方案](docs/local-first/README.md)
- [一期开发步骤](docs/local-first/development-plan.md)
- [一期验收清单](docs/local-first/acceptance.md)

以下保留总体技术与二期同步参考：

- [总体架构与选型](docs/cloud-sync-architecture.md)
- [14步开发计划](docs/design/development-plan.md)
- [逐步验收操作](docs/design/stage-acceptance.md)
- [17 个模块详细设计](docs/design/README.md)
- [十万张性能预算](docs/design/modules/16-performance.md)
- [液态玻璃视觉与交互](docs/design/modules/17-liquid-glass.md)
- [统一验收矩阵](docs/design/acceptance.md)
- [设计核查记录](docs/design/review.md)

当前本地功能已经接通来源管理、目录监听、图片/视频查看、收藏与搜索、文件夹相册管理、系统回收站、导出和编辑。Linux窗口使用应用自绘标题栏与窗口按钮。详细变更见[本地功能与UX记录](docs/local-first/local-feature-delivery.md)。

当前优先完成功能；按用户要求，新的UX自动化用例后续再补。原有S01–S04证据仍是各自版本的历史证据，不代表当前全部功能或十万张性能验收通过。云同步继续留到二期。

开发与启动约定见 [AGENTS.md](AGENTS.md)。Android 的固定工具链、构建、模拟器与测试环境见 [docs/android/README.md](docs/android/README.md)。每次修改只运行与改动直接相关的用例，禁止运行全量用例；纯文档修改不重跑功能测试。
