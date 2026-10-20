# Photo Client

PhotoViewer跨平台重写：Flutter界面、独立Rust核心与SQLite。**一期先完成纯本地照片功能，云同步留到二期。** Linux先交付；Android、Windows通过平台配置和适配器后续接入。

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

当前按用户要求暂停开发。S01工程基础已验收；本地数据库、扫描/缩略图、界面组件已分别完成聚焦检查，尚未接通原生端到端流程。详情见[暂停与恢复记录](docs/local-first/progress.md)。
