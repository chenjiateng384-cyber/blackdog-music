# 参与开发

这是仍在验证中的 Android 私人音乐播放器，不承诺已达到所有设备的稳定标准。请先读 [README](README.md)、[隐私说明](PRIVACY.md) 和 [交付检查](docs/OPEN_SOURCE_DELIVERY.md)。

## 修改原则

- 一个改动解决一个明确问题；先给复现步骤和预期行为，再改代码。
- 不提交音乐、真实数据库、备份、签名私钥、个人绝对路径或未授权素材。
- 不顺便改 UI 大结构、扫描器、Track 身份、数据库 Schema 或播放器核心。必要变更先说明迁移与回退方案。
- 修复 Bug 要附回归测试；测试使用合成数据和独立临时目录，不能依赖开发者唯一音乐库。

## 自检

```sh
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
python -m unittest discover -s tools/lyrics_alignment -p 'test_*.py'
python -m unittest discover -s tools/harmony-music-intake -p 'test_*.py'
# 在项目根目录，Windows 使用 android\gradlew.bat：
sh android/gradlew -p android/tag-parser-core test --no-daemon
flutter build apk --debug --no-pub
```

使用 Flutter 3.47.0 / Dart 3.13.0、JDK 21。真实库验收按 README 显式设置环境变量；跳过不能报告为通过。后台、锁屏、耳机、播放连续性仍需真机验收，不能由单元测试替代。

修改 Windows 启动/构建脚本时，另运行 `powershell -NoProfile -ExecutionPolicy Bypass -File tools/test_tool.ps1`。测试使用本次创建的临时目录和模拟 SDK，覆盖参数、下载源、中文路径与失败返回，不需要实际下载 Flutter 或连接设备。

提交 PR 时列出：问题、根因、修改范围、测试命令与结果、是否影响数据和未验证项。不得把改过代码等同于已修复。
