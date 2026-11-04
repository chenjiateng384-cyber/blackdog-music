# Harmony 逐字歌词对齐工具

这套工具运行在电脑上，不塞进 Android APK。它读取用户已有的音频和普通 LRC，调用开源声学对齐器生成逐字时间，再输出 Harmony 已支持的增强 `.lrc`。

## 安全边界

- 不修改、移动或删除你通过 `MusicRoot` 指定的音乐目录中的任何文件。
- 结果写入独立镜像目录。
- 没有通过“歌词全文一致 + 时间单调”校验的结果标记为 `needs_review`。
- 不会自动替换手机歌词；试听通过后再由用户决定复制哪些文件。
- 输出中的空时间段是真实停顿；每个字词都带开始和结束时间，拖音不会在格式转换时丢失。

## 使用的开源方案

高精度主路线使用 `Xingyu Lyrics Aligner`（Apache-2.0，固定提交 `ef5ad02a0059ab07f4cc92f608d373447c89b007`）和固定版本的中文 Wav2Vec2 CTC 模型。它直接把可信歌词与真实音频对齐，输出包含每个字开始、结束时间的 SWLRC。Harmony 转换时会从原 LRC 无损恢复空格和标点。

`lyric-align`（MIT，固定提交 `50aefb487deb30dd8b0590b78e1a705199ed9189`）保留为英文歌或快速草稿备用。真实测试表明它不适合作为中文快唱的最终结果。`UserSync` 可作为人工校正备用，但仍需人工复核。
## 初始化

在项目根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File tools\lyrics_alignment\bootstrap.ps1
```

第三方源码、模型和虚拟环境只放在已忽略的 `.tooling`，不会提交到 App。

## 先跑一首

下列命令中的 `MUSIC_ROOT` 需要替换成你自己的音乐根目录；示例歌曲路径和 20 首清单也要按实际收藏修改。工具不附带这些歌曲或歌词。

```powershell
.tooling\lyrics-alignment\.venv\Scripts\python.exe tools\lyrics_alignment\harmony_lyrics_tool.py align `
  --music-root "MUSIC_ROOT" `
  --output-root "artifacts\lyrics_alignment_output" `
  --lyric-align ".tooling\lyrics-alignment\.venv\Scripts\lyric-align.exe" `
  --lrc "周杰伦\2001_范特西\安静.lrc" `
  --language zh --no-vad
```

第一次运行会下载 Whisper 模型。CPU 可运行，但一首歌可能需要较长时间。

## 20 首试运行

推荐使用按语言自动分流的首批脚本：中文使用 Xingyu CTC，英文使用 lyric-align。脚本支持中断后续跑，且只写入独立镜像目录：

```powershell
powershell -ExecutionPolicy Bypass -File tools\lyrics_alignment\run_pilot.ps1 -MusicRoot "MUSIC_ROOT"
```

统一报告位于 `artifacts\lyrics_alignment_pilot_output\pilot_report.json`。

旧的单一 lyric-align 批处理入口保留用于快速草稿：
```powershell
.tooling\lyrics-alignment\.venv\Scripts\python.exe tools\lyrics_alignment\harmony_lyrics_tool.py batch `
  --music-root "MUSIC_ROOT" `
  --output-root "artifacts\lyrics_alignment_output" `
  --lyric-align ".tooling\lyrics-alignment\.venv\Scripts\lyric-align.exe" `
  --manifest "tools\lyrics_alignment\pilot_manifest.json"
```

结果保持原目录结构；总报告位于 `artifacts\lyrics_alignment_output\alignment_report.json`。

## 高精度中文逐字对齐（推荐）

首次准备固定版本工具与中文模型：

```powershell
powershell -ExecutionPolicy Bypass -File tools\lyrics_alignment\bootstrap_xingyu.ps1
```

对齐单首歌曲：

```powershell
powershell -ExecutionPolicy Bypass -File tools\lyrics_alignment\run_xingyu.ps1 `
  -MusicRoot "MUSIC_ROOT" `
  -RelativeLrc "周杰伦\2001_范特西\双截棍.lrc"
```

结果写入 `artifacts\lyrics_alignment_xingyu_output` 的同名镜像路径，原音频和原 LRC 不会被修改。运行器会依次完成可信正文提取、CTC 强制对齐、Harmony 增强 LRC 转换和严格校验。

如已有 Xingyu 输出，也可单独转换：

```powershell
python tools\lyrics_alignment\harmony_lyrics_tool.py convert-swlrc `
  --source "lyrics.swlrc" `
  --source-lrc "原始歌词.lrc" `
  --output "artifacts\lyrics_alignment_output\对应目录\歌曲名.lrc"
```

转换会拒绝倒退、越界、重叠、行数不符或正文不一致，并保留每个字词的真实开始、结束与停顿。
## 质量说明

开源 ASR 对齐可以把普通整句 LRC 提升成可用的逐字草稿，但“每个咬字绝对准确”仍取决于音频版本、伴奏干扰和模型识别。低分、漏行、Live 或重伴奏歌曲必须试听复核。Harmony 不再用平均分配时间掩盖低质量结果。
