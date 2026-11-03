# 黑狗音乐（Harmony）

黑狗音乐是面向个人长期使用的 Android 本地音乐播放器：保留真实目录，读取本地 Metadata、封面和 LRC，并在本机保存喜欢、歌单、播放历史和个性化播放数据。

当前为 **0.4.6 测试候选版**，不是已经完成全机型验收的正式版。主代码 MIT；第三方代码、图标和截图素材见 [第三方声明](THIRD_PARTY_NOTICES.md)。

发布准备：已在所有者账号创建私有仓库 `chenjiateng384-cyber/blackdog-music`，用于源码和线上检查；尚未公开，也没有正式 Release。首发选集不含旧设计图、私人复盘、Word 原件、音乐或用户数据库，原件在维护者本地保留。

**只想安装听歌：** 先看[第一次使用](docs/QUICK_START.md)，不需要配置开发工具。**想改代码或自行编译：** 看下方“从源码运行”。

## 平台与下载

| 你要使用什么 | 当前状态 |
| --- | --- |
| Android 手机播放器 | 已有 ARM64 本地测试 APK；Android 7.0 / API 24 起，主要验收设备为一加13；尚无正式公开下载地址 |
| iPhone / iPad | 暂不支持；没有 iOS 工程、IPA、TestFlight 或 App Store 版本，不能安装 Android APK |
| Windows / macOS / Linux 播放器 | 暂未提供桌面播放器；电脑上的 Python 工具不是桌面版 App |
| 电脑音乐后勤工具 | 随源码提供，可选使用；当前测试边界见音乐后勤文档 |

普通用户将来应从 GitHub Releases 下载明确标注平台的 APK，不要把“Source code”源码压缩包当安装包。当前仍在发布准备阶段，不提供虚构下载链接。推荐定位、发布内容和剩余条件见[发布前最终核对](docs/RELEASE_READINESS.md)。

## 当前能力

- SAF 选择一个或多个音乐根目录，递归扫描且不移动原文件。
- 支持 FLAC、MP3、WAV、M4A、AAC、OGG、OPUS。
- Track 与 MediaFile 分离，支持文件移动、重复检测和多音质版本。
- 读取 FLAC、MP3、WAV 标签与内嵌封面，并支持本地目录封面和歌手封面。
- 音乐库按歌曲、歌手、专辑、文件夹浏览；文件夹保留原始结构。
- 本地搜索、喜欢、普通歌单和“仅手动播放”。
- 播放队列、Mini Player、后台/锁屏控制、本地 LRC。
- 随心听动态电台和每日稳定的智能播放池，内容只来自本地曲库。
- 播放事件与音乐档案。
- 可导出/恢复单个 `.harmonybackup`，不打包原始音乐。

## 重要文档

- [第一次使用：安装、选目录、听第一首歌](docs/QUICK_START.md)
- [当前产品体验检查报告](docs/Harmony-当前产品体验检查报告.md)
- [日常使用手册](docs/Harmony-使用手册.md)
- [从获取音乐到入库：本地音乐收藏指南](docs/LOCAL_MUSIC_COLLECTION_GUIDE.md)
- [音乐后勤架构、AI 提示词与检查工具](docs/MUSIC_OPERATIONS.md)
- [增强 LRC 说明](docs/HARMONY_ENHANCED_LRC.md)
- [项目与使用说明书](docs/黑狗音乐-从源码到手机运行的完整说明.md)
- [本轮整改与交付状态](docs/OPEN_SOURCE_DELIVERY.md)
- [第一次发布操作指南](docs/RELEASING.md)
- [发布定位、平台与最终检查单](docs/RELEASE_READINESS.md)
- [陌生用户完整走查与实际修复结果](docs/FIRST_USER_WALKTHROUGH.md)
- [数据与隐私](PRIVACY.md) · [参与开发](CONTRIBUTING.md) · [安全反馈](SECURITY.md)

## 从源码运行

已验证的工具组合：Flutter 3.47.0（Dart 3.13.0）、JDK 21、Android SDK Platform 36。项目使用 Gradle 9.3.1、AGP 9.1.0、Kotlin 2.4.0，不要为了运行随意升级依赖。Flutter 首次构建会按项目需要准备 NDK。

Android 最低 API 24；目前主要验收设备为一加13。识别某种音频扩展名不等于已验证该格式的每个编码变体。

安装 [Flutter SDK](https://docs.flutter.dev/install/archive)、Android SDK 和 JDK，将 Flutter 加入 PATH，并用 `flutter doctor -v` 确认 Android 工具链就绪。在项目根目录：

建议把 SDK 安装在不含中文和空格的工具目录，减少第三方工具链的编码问题。当前 Windows 脚本的 APK 构建已额外处理外部中文 SDK 路径；交互式 `run` 仍需连接 Android 设备单独验收，不能用成功生成 APK 代替。

```sh
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
flutter devices
# 将 ANDROID_DEVICE_ID 替换为上一条命令中 Android 手机的实际 ID：
flutter run -d ANDROID_DEVICE_ID
```

Windows 中文路径可用项目脚本；脚本优先识别 `FLUTTER_ROOT`，其次 `.tooling/flutter`，最后 PATH；JDK 使用 `JAVA_HOME` 或本地 `.tooling/jdk`。SDK 使用 `ANDROID_HOME` / `ANDROID_SDK_ROOT`，或系统默认目录：

```powershell
.\tool.ps1 doctor
.\tool.ps1 get
.\tool.ps1 analyze
.\tool.ps1 test
.\tool.ps1 build-local-test
```

脚本支持透传参数，例如 `./tool.ps1 run -d 设备ID`、`./tool.ps1 build-local-test --build-number=12`。当前源码基号为 12；此工具链的分架构构建给 ARM64 加 2000，因此预期 APK 更新编号为 2012，较早测试包为 2011。最终以实际验包为准；未拆分 APK 的编号不能直接按此规则推断。

脚本不强制更换下载源；默认沿用 Flutter/Dart 设置，显式配置的 `PUB_HOSTED_URL` 和 `FLUTTER_STORAGE_BASE_URL` 会保留。若网络需要镜像，先确认来源再自行配置，不必为此改业务代码。

首次配置时，先处理 `doctor` 中与 Android SDK、JDK、许可和网络有关的问题。SDK 许可需你阅读并自行决定是否接受；不要用自动批量同意命令替代。只有 Windows 桌面构建的 Visual Studio 警告不要求为本项目安装整套桌面工具。若只列出 Windows/Chrome/Edge 而没有 Android 设备，不要选择它们运行：当前项目没有这些平台工程，请连接并授权 Android 手机。

若 PowerShell 阻止脚本运行，先确认源码可信，再使用仅作用于这次进程的形式，例如 `powershell -NoProfile -ExecutionPolicy Bypass -File .\tool.ps1 doctor`；不要为了运行项目全局关闭安全策略。网络受限时参考 [Flutter 官方镜像配置说明](https://docs.flutter.dev/community/china)，镜像是否可信由使用者确认。

`build-local-test` 是 release 性能模式、调试证书签名的本地测试包，输出 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`，**不是可正式公开分发的签名版**。其他电脑的调试证书通常不同，不能保证覆盖原手机。

正式 `build-release` 必须先配置私有的 `android/key.properties`；默认不再悄悄使用调试签名。安装前对比证书，签名不一致立即停止，不卸载、不清数据。详见发布指南。

仓库不提交 `.tooling`、`dist` APK、音乐、数据库、备份和私钥。全新克隆后必须构建，不能依赖本机 `dist` 路径；首次公开后经验证的 APK 才放 GitHub Releases。

## 测试边界

- 默认测试使用合成数据；真实库测试缺少输入时会明确跳过，不能算通过。
- `REAL_MUSIC_ROOT` 指向你自己的音乐根目录；`REAL_HISTORY_DB` 指向可信、完整的离线数据库快照。测试读取/复制这些输入，不应公开上传。
- 原生解析测试：`android\gradlew.bat -p android/tag-parser-core test --no-daemon`；可加 `-DrealMusicRoot=...` 验证本机音乐样本。
- 电脑歌词工具测试：`python -m unittest discover -s tools/lyrics_alignment -p 'test_*.py'`，无需下载模型即可运行。
- 音乐后勤检查工具测试：`python -m unittest discover -s tools/harmony-music-intake -p 'test_*.py'`，无需新增依赖。
- Windows 构建脚本回归：`powershell -NoProfile -ExecutionPolicy Bypass -File tools/test_tool.ps1`，使用临时模拟 SDK，不接触手机或真实音乐。
- GitHub Actions 配置只检查和构建调试 APK，不自动发布、不接触签名私钥；首次实际远端运行仍需验收。
- 长时间播放、锁屏、蓝牙/耳机、系统打断和卸载恢复必须另做设备/隔离环境验收。普通 LRC 无法提供真实逐字时间，详见增强 LRC 说明。

## 文件分工

- `lib/`：Flutter 页面、交互、控制器、数据查询和播放业务。
- `android/`：Android 权限、媒体服务、SAF、标签解析和构建配置。
- `test/`：合成数据回归测试；`android/tag-parser-core/` 另有原生解析测试。
- `docs/`：产品说明、历史设计与验收记录；历史报告不代表当前版本已验证结果。
- `tools/lyrics_alignment/`：可选电脑端歌词对齐，不进入手机 APK。

第一次使用：复制音乐到手机 → “我的”选择根目录 → 扫描 → 播放。添加喜欢/歌单后及时导出外部备份；详细整理规则见使用手册。

## 数据原则

- 音乐文件属于用户，Harmony 默认只读。
- 扫描目录是主流程，“导入复制”不是主流程。
- 卸载前应把 `.harmonybackup` 保存到 App 外部。
- 不提供在线音乐、会员、广告、社区或云同步。
