# 第三方代码与素材声明

本项目自行编写的代码采用根目录 MIT 许可证。第三方代码、字体、图片、专辑封面不因主许可证变为 MIT，也不因出现在截图中自动获得再授权。

## Flutter

`shaders/ink_sparkle.frag`、`shaders/stretch_effect.frag` 来自 Flutter，保留原版权头，适用以下 BSD 许可证。Flutter SDK 自带的 Material 图标、字体及其他组件适用 SDK 自带的许可。

来源：[Flutter LICENSE](https://github.com/flutter/flutter/blob/3.47.0/LICENSE)。分发 APK 时应同时提供本声明；Flutter 的运行期许可证注册信息由工具链生成。

```text
Copyright 2014 The Flutter Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## 依赖与电脑歌词工具

- Dart/Flutter 依赖版本以 `pubspec.lock` 为准；其许可证保留在对应依赖包中。公开 APK 前核对所分发组件及其传递依赖的声明，不以本文件代替完整依赖许可证清单。
- 电脑端歌词工具、对齐器和模型：[独立声明](tools/lyrics_alignment/THIRD_PARTY_NOTICES.md)。这些下载到 `.tooling` 的工具不随 Android APK 打包；首次初始化可能联网下载。
- 没有把仅参考的 AGPL/GPL 歌词项目声明为本项目的 MIT 代码。

## 图片与公开素材

项目所有者于 2026-11-03 确认狗狗图标、现有设计图和截图内封面具有可公开分发授权，并表示可提供来源。此处记录的是所有者确认，不是独立版权核验结论。

首次公开前仍须把实际来源、授权范围和证明整理到以下清单；不要在证明缺失时写成“已全面审核通过”。不删除本地原图，不上传用户私人音乐或备份来充当演示数据。

| 范围 | 当前状态 | 公开前需要补齐 |
| --- | --- | --- |
| `android/app/src/main/res/mipmap-*/ic_launcher.png` 狗狗图标 | 所有者确认可公开分发 | 原始来源、作者、授权凭证/条款；注明是否含 AI 生成素材 |
| `docs/ui-mockups/` 设计图 | 所有者确认可公开分发 | 设计来源及图内第三方素材的授权范围 |
| `docs/phase-ix-1/`、其他文档真机截图 | 所有者确认可公开分发 | 封面来源与许可；检查通知、文件路径和个人信息 |
| 用户自己的音乐、LRC、歌手照片与数据 | 不作为源码发布内容 | 用户自行管理；本项目许可不涵盖用户收藏 |

授权材料若含个人合同、身份证明等敏感信息，应私下保管；公开清单只放可公开的来源和授权说明。
