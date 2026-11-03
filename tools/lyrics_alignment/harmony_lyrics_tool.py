#!/usr/bin/env python3
"""Safe desktop pipeline for producing Harmony enhanced LRC files.

The tool never modifies the music library.  It extracts trusted text from an
existing LRC, asks lyric-align for audio-based timings, converts the JSON result
to Harmony's start/end-tagged enhanced LRC, and writes a validation report.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


AUDIO_EXTENSIONS = (".flac", ".wav", ".mp3", ".m4a", ".aac", ".ogg", ".opus")
LINE_TAG = re.compile(r"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]")
META_TAG = re.compile(r"^\[(ar|ti|al|by|re|ve|length|offset):([^\]]*)\]$", re.I)
INLINE_TAG = re.compile(r"<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>")


@dataclass(frozen=True)
class SourceLyrics:
    metadata: tuple[str, ...]
    lines: tuple[str, ...]
    ignored_leading_lines: tuple[str, ...] = ()
    line_times_ms: tuple[int | None, ...] = ()


LEADING_CREDIT = re.compile(
    r"^(?:(?:作?词|作?曲|编曲|演唱|歌手|制作人|监制|混音|录音|(?:和|合)声(?:编写)?|OP|SP|Lyrics by|Composed by|Arranged by|Produced by)\s*[:：]|TME享有.*|[^:：]{1,40}[:：].{0,120}$|.{1,80}\s[-–—]\s.{1,80}$)",
    re.I,
)


def _millis(match: re.Match[str]) -> int:
    fraction = match.group(3) or "0"
    ms = int((fraction + "00")[:3])
    return (int(match.group(1)) * 60 + int(match.group(2))) * 1000 + ms


def read_source_lrc(path: Path) -> SourceLyrics:
    text = path.read_text(encoding="utf-8-sig")
    metadata: list[str] = []
    timed: list[tuple[int, int, str]] = []
    untimed: list[str] = []
    order = 0
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        meta = META_TAG.fullmatch(line)
        if meta:
            if meta.group(1).lower() != "offset":
                metadata.append(line)
            continue
        tags = list(LINE_TAG.finditer(line))
        body = LINE_TAG.sub("", line).strip()
        if not body:
            continue
        if tags:
            for tag in tags:
                timed.append((_millis(tag), order, body))
                order += 1
        else:
            untimed.append(body)
    if timed:
        ordered = sorted(timed)
        lines = [body for _, _, body in ordered]
        line_times_ms: list[int | None] = [time_ms for time_ms, _, _ in ordered]
    else:
        lines = untimed
        line_times_ms = [None] * len(lines)
    if not lines:
        raise ValueError(f"歌词没有可对齐的正文：{path}")
    ignored: list[str] = []
    while lines and LEADING_CREDIT.match(lines[0]):
        ignored.append(lines.pop(0))
        line_times_ms.pop(0)
    if not lines:
        raise ValueError(f"歌词只有歌曲说明，没有可对齐正文：{path}")
    return SourceLyrics(tuple(metadata), tuple(lines), tuple(ignored), tuple(line_times_ms))


def _timestamp(seconds: float) -> str:
    total_ms = max(0, round(seconds * 1000))
    minutes, remain = divmod(total_ms, 60_000)
    secs, millis = divmod(remain, 1000)
    return f"{minutes:02d}:{secs:02d}.{millis:03d}"


def _is_cjk(text: str) -> bool:
    cjk = sum("\u3400" <= char <= "\u9fff" for char in text)
    visible = sum(not char.isspace() for char in text)
    return visible > 0 and cjk / visible >= 0.2


def _alignment_indices(source: SourceLyrics, language: str) -> tuple[int, ...]:
    language = language.lower()
    if language.startswith("en"):
        indices = tuple(
            index for index, line in enumerate(source.lines)
            if not _is_cjk(line) and re.search(r"[A-Za-z]", line)
        )
    elif language.startswith("zh"):
        indices = tuple(index for index, line in enumerate(source.lines) if _is_cjk(line))
    else:
        indices = tuple(range(len(source.lines)))
    if not indices:
        raise ValueError(f"歌词中没有可用于 {language} 对齐的演唱行")
    return indices


def _line_start_ms(line: str) -> int:
    match = LINE_TAG.search(line)
    if match is None:
        raise ValueError("增强歌词缺少整句时间")
    return _millis(match)


def _merge_selected_lines(
    source: SourceLyrics,
    source_indices: tuple[int, ...],
    selected_lines: list[str],
) -> list[str]:
    if len(source_indices) != len(selected_lines):
        raise ValueError("对齐结果行数与选中的原歌词行数不一致")
    aligned = dict(zip(source_indices, selected_lines))
    starts = {index: _line_start_ms(line) for index, line in aligned.items()}
    output: list[str] = []
    previous_ms = 0
    for index, source_line in enumerate(source.lines):
        if index in aligned:
            line = aligned[index]
            aligned_start = starts[index]
            if aligned_start < previous_ms:
                raise ValueError("对齐结果的歌词行时间发生倒退")
            previous_ms = aligned_start
            output.append(line)
            continue
        original_ms = (
            source.line_times_ms[index]
            if index < len(source.line_times_ms) and source.line_times_ms[index] is not None
            else previous_ms
        )
        next_ms = next((starts[i] for i in source_indices if i > index), None)
        time_ms = max(previous_ms, int(original_ms))
        if next_ms is not None:
            time_ms = min(time_ms, next_ms)
        output.append(f"[{_timestamp(time_ms / 1000)}]{source_line}")
        previous_ms = time_ms
    return output


def _matched_output_indices(
    source: SourceLyrics,
    candidate_indices: tuple[int, ...],
    selected_lines: list[str],
) -> tuple[int, ...]:
    matched: list[int] = []
    cursor = 0
    for enhanced_line in selected_lines:
        body = LINE_TAG.sub("", enhanced_line)
        plain = INLINE_TAG.sub("", body).strip()
        found = None
        while cursor < len(candidate_indices):
            source_index = candidate_indices[cursor]
            cursor += 1
            if source.lines[source_index] == plain:
                found = source_index
                break
        if found is None:
            raise ValueError(f"对齐结果无法与原歌词按顺序匹配：{plain}")
        matched.append(found)
    return tuple(matched)


def _timed_units(line: str, chars: list[dict]) -> list[dict]:
    """Rebuild exact text while grouping Latin text by word and CJK by char."""
    usable = [item for item in chars if item.get("start") is not None and item.get("end") is not None]
    if len(usable) != sum(not char.isspace() for char in line):
        return []
    mapped: list[tuple[str, float, float]] = []
    iterator = iter(usable)
    for char in line:
        if char.isspace():
            if mapped:
                old, start, end = mapped[-1]
                mapped[-1] = (old + char, start, end)
            continue
        item = next(iterator)
        mapped.append((char, float(item["start"]), float(item["end"])))
    if _is_cjk(line):
        return [{"text": text, "start": start, "end": end} for text, start, end in mapped]

    units: list[dict] = []
    for text, start, end in mapped:
        if units and not units[-1]["text"].endswith(tuple(" \t")):
            units[-1]["text"] += text
            units[-1]["end"] = end
        else:
            units.append({"text": text, "start": start, "end": end})
    return units


def json_to_harmony_lrc(payload: list[dict], metadata: tuple[str, ...]) -> tuple[str, dict]:
    output: list[str] = list(metadata)
    unmatched: list[dict] = []
    scores: list[float] = []
    for index, item in enumerate(payload, 1):
        if not item.get("matched") or item.get("start") is None or item.get("end") is None:
            unmatched.append({"line": index, "text": item.get("line", ""), "score": item.get("score")})
            continue
        line = str(item.get("line", "")).strip()
        units = _timed_units(line, list(item.get("chars") or []))
        if not units:
            unmatched.append({"line": index, "text": line, "score": item.get("score"), "reason": "missing_word_timing"})
            continue
        body = "".join(
            f"<{_timestamp(unit['start'])}>{unit['text']}<{_timestamp(unit['end'])}>"
            for unit in units
        )
        output.append(f"[{_timestamp(float(item['start']))}]{body}")
        scores.append(float(item.get("score") or 0))
    report = {
        "sourceLineCount": len(payload),
        "alignedLineCount": len(payload) - len(unmatched),
        "unmatched": unmatched,
        "minimumScore": min(scores) if scores else None,
        "averageScore": sum(scores) / len(scores) if scores else None,
    }
    return "\n".join(output) + "\n", report


def validate_enhanced_lrc(source: SourceLyrics, enhanced: str) -> dict:
    parsed_lines: list[str] = []
    timing_errors: list[str] = []
    last_line_ms = -1
    for raw in enhanced.splitlines():
        tags = list(LINE_TAG.finditer(raw))
        if not tags:
            continue
        line_ms = _millis(tags[0])
        if line_ms < last_line_ms:
            timing_errors.append("歌词行时间倒退")
        last_line_ms = line_ms
        body = raw[tags[-1].end():]
        word_tags = list(INLINE_TAG.finditer(body))
        plain = INLINE_TAG.sub("", body).strip()
        parsed_lines.append(plain)
        previous = -1
        for tag in word_tags:
            current = _millis(tag)
            if current < previous:
                timing_errors.append(f"逐字时间倒退：{plain}")
                break
            previous = current
    text_matches = tuple(parsed_lines) == source.lines
    return {
        "valid": text_matches and not timing_errors,
        "textMatchesSource": text_matches,
        "sourceLineCount": len(source.lines),
        "outputLineCount": len(parsed_lines),
        "timingErrors": timing_errors,
    }


SWLRC_LINE = re.compile(r"^\[(\d{1,3}):(\d{2})\.(\d{3}),(\d{1,3}):(\d{2})\.(\d{3})\]$")
SWLRC_TOKEN = re.compile(r"^<(\d{1,3}):(\d{2})\.(\d{3}),(\d{1,3}):(\d{2})\.(\d{3})>(.*)$")


def _swlrc_ms(groups: tuple[str, str, str]) -> int:
    return (int(groups[0]) * 60 + int(groups[1])) * 1000 + int(groups[2])


def _restore_source_text(source_line: str, tokens: list[tuple[int, int, str]]) -> list[tuple[int, int, str]]:
    """Restore spaces and punctuation removed by the CTC tokenizer."""
    restored: list[tuple[int, int, str]] = []
    cursor = 0
    for start, end, value in tokens:
        index = source_line.find(value, cursor)
        if index < 0:
            raise ValueError(f"SWLRC token 与原歌词不一致：{source_line}")
        restored.append((start, end, source_line[cursor:index] + value))
        cursor = index + len(value)
    if cursor != len(source_line):
        if not restored:
            raise ValueError(f"SWLRC 歌词行没有可恢复 token：{source_line}")
        start, end, value = restored[-1]
        restored[-1] = (start, end, value + source_line[cursor:])
    return restored


def swlrc_to_harmony_lrc(
    content: str,
    source: SourceLyrics | None = None,
    source_indices: tuple[int, ...] | None = None,
) -> tuple[str, dict]:
    physical = [line.strip() for line in content.replace("\ufeff", "").splitlines() if line.strip()]
    if not physical or physical[0] != "[swlrc:1]":
        raise ValueError("SWLRC 必须以 [swlrc:1] 开头")
    metadata: list[str] = []
    output: list[str] = []
    current: tuple[int, int] | None = None
    tokens: list[tuple[int, int, str]] = []
    matched_source_indices: list[int] = []
    next_source_candidate = 0

    def flush() -> None:
        nonlocal tokens, next_source_candidate
        if current is None:
            return
        if not tokens:
            raise ValueError("SWLRC 歌词行没有 token")
        if source is not None:
            indices = source_indices or tuple(range(len(source.lines)))
            restored = None
            while next_source_candidate < len(indices):
                source_index = indices[next_source_candidate]
                next_source_candidate += 1
                try:
                    restored = _restore_source_text(source.lines[source_index], tokens)
                    matched_source_indices.append(source_index)
                    break
                except ValueError:
                    continue
            if restored is None:
                raise ValueError("SWLRC token 无法与剩余原歌词按顺序匹配")
            tokens = restored
        previous_end = current[0]
        body = ""
        for start, end, value in tokens:
            if start < current[0] or end > current[1] or start >= end or start < previous_end:
                raise ValueError("SWLRC token 时间范围非法或发生重叠")
            body += f"<{_timestamp(start / 1000)}>{value}<{_timestamp(end / 1000)}>"
            previous_end = end
        output.append(f"[{_timestamp(current[0] / 1000)}]{body}")
        tokens = []

    for line in physical[1:]:
        line_match = SWLRC_LINE.fullmatch(line)
        if line_match:
            flush()
            start = _swlrc_ms((line_match.group(1), line_match.group(2), line_match.group(3)))
            end = _swlrc_ms((line_match.group(4), line_match.group(5), line_match.group(6)))
            if start >= end:
                raise ValueError("SWLRC 歌词行结束时间必须晚于开始时间")
            current = (start, end)
            continue
        token_match = SWLRC_TOKEN.fullmatch(line)
        if token_match:
            if current is None:
                raise ValueError("SWLRC token 出现在歌词行之前")
            start = _swlrc_ms((token_match.group(1), token_match.group(2), token_match.group(3)))
            end = _swlrc_ms((token_match.group(4), token_match.group(5), token_match.group(6)))
            tokens.append((start, end, token_match.group(7)))
            continue
        meta = re.fullmatch(r"\[([^:]+):(.*)\]", line)
        if meta and current is None:
            key = {"title": "ti", "artist": "ar", "album": "al", "offset": "offset"}.get(meta.group(1).lower())
            if key:
                metadata.append(f"[{key}:{meta.group(2)}]")
            continue
        raise ValueError(f"无法识别的 SWLRC 行：{line}")
    flush()
    if source is not None:
        if len(output) != len(matched_source_indices):
            raise ValueError("SWLRC 歌词行与原歌词映射不完整")
        output = _merge_selected_lines(source, tuple(matched_source_indices), output)
        metadata = list(source.metadata)
    report = {
        "lineCount": len(output),
        "tokenCount": sum(len(INLINE_TAG.findall(line)) // 2 for line in output),
    }
    if source is not None:
        report["textRestoredFromSource"] = True
    return "\n".join(metadata + output) + "\n", report


def cmd_convert_swlrc(args: argparse.Namespace) -> int:
    source = read_source_lrc(args.source_lrc) if args.source_lrc else None
    indices = _alignment_indices(source, args.language) if source is not None else None
    enhanced, report = swlrc_to_harmony_lrc(
        args.source.read_text(encoding="utf-8-sig"),
        source,
        indices,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(enhanced, encoding="utf-8")
    print(json.dumps({"output": str(args.output), **report}, ensure_ascii=False, indent=2))
    return 0

def _audio_for_lrc(lrc: Path) -> Path:
    by_suffix = {path.suffix.lower(): path for path in lrc.parent.glob(f"{lrc.stem}.*")}
    for suffix in AUDIO_EXTENSIONS:
        if suffix in by_suffix:
            return by_suffix[suffix]
    raise FileNotFoundError(f"找不到同目录同名音频：{lrc}")


def _run_alignment(args: argparse.Namespace, relative_lrc: Path, options: dict) -> dict:
    source_lrc = args.music_root / relative_lrc
    audio = _audio_for_lrc(source_lrc)
    source = read_source_lrc(source_lrc)
    work = args.output_root / ".work" / relative_lrc.parent
    work.mkdir(parents=True, exist_ok=True)
    plain = work / f"{relative_lrc.stem}.txt"
    raw_json = work / f"{relative_lrc.stem}.json"
    alignment_audio = audio
    if options.get("separate") is True:
        alignment_audio = work / audio.name
        if (
            not alignment_audio.exists()
            or alignment_audio.stat().st_size != audio.stat().st_size
            or alignment_audio.stat().st_mtime_ns != audio.stat().st_mtime_ns
        ):
            shutil.copy2(audio, alignment_audio)
    language = options.get("language", "zh")
    source_indices = _alignment_indices(source, language)
    plain.write_text(
        "\n".join(source.lines[index] for index in source_indices) + "\n",
        encoding="utf-8",
    )

    command = [
        str(args.lyric_align), str(alignment_audio), str(plain), "-f", "json", "--karaoke",
        "--language", language, "--model", args.model,
        "--device", args.device, "-o", str(raw_json),
    ]
    if options.get("vad") is False:
        command.append("--no-vad")
    if options.get("separate") is True:
        command.append("--separate")
    completed = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if completed.returncode != 0:
        return {
            "path": str(relative_lrc), "status": "failed", "exitCode": completed.returncode,
            "stderr": completed.stderr[-4000:],
        }

    enhanced, alignment = json_to_harmony_lrc(
        json.loads(raw_json.read_text(encoding="utf-8")),
        source.metadata,
    )
    selected_lines = [line for line in enhanced.splitlines() if LINE_TAG.search(line)]
    matched_indices = _matched_output_indices(source, source_indices, selected_lines)
    merged = _merge_selected_lines(source, matched_indices, selected_lines)
    enhanced = "\n".join([*source.metadata, *merged]) + "\n"
    alignment["auxiliaryLineCount"] = len(source.lines) - len(matched_indices)
    destination = args.output_root / relative_lrc
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(enhanced, encoding="utf-8")
    validation = validate_enhanced_lrc(source, enhanced)
    aligned_count = int(alignment["alignedLineCount"])
    source_count = max(1, int(alignment["sourceLineCount"]))
    alignment["coverage"] = aligned_count / source_count
    quality_passed = validation["valid"] and alignment["coverage"] >= 0.7
    return {
        "path": str(relative_lrc), "audio": str(audio.relative_to(args.music_root)),
        "status": "ready_for_listening" if quality_passed else "needs_review",
        "ignoredLeadingLines": list(source.ignored_leading_lines),
        "alignment": alignment, "validation": validation,
        "stderr": completed.stderr[-4000:],
    }


def _write_report(output_root: Path, results: list[dict]) -> Path:
    report = output_root / "alignment_report.json"
    report.write_text(json.dumps({"results": results}, ensure_ascii=False, indent=2), encoding="utf-8")
    return report


def cmd_align(args: argparse.Namespace) -> int:
    result = _run_alignment(args, args.lrc, {"language": args.language, "vad": not args.no_vad, "separate": args.separate})
    report = _write_report(args.output_root, [result])
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print(f"报告：{report}")
    return 0 if result["status"] == "ready_for_listening" else 1


def cmd_batch(args: argparse.Namespace) -> int:
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    report_path = args.output_root / "alignment_report.json"
    previous = {}
    if report_path.exists():
        saved = json.loads(report_path.read_text(encoding="utf-8"))
        previous = {item["path"]: item for item in saved.get("results", [])}
    results = []
    for item in manifest["songs"]:
        relative = Path(item["lrc"])
        old = previous.get(str(relative))
        if old and old.get("status") == "ready_for_listening" and (args.output_root / relative).exists():
            print(f"跳过已通过：{relative}", flush=True)
            results.append(old)
            continue
        print(f"对齐：{relative}", flush=True)
        results.append(_run_alignment(args, relative, item))
        _write_report(args.output_root, results)
    report = _write_report(args.output_root, results)
    ready = sum(item["status"] == "ready_for_listening" for item in results)
    print(f"完成：{ready}/{len(results)} 首通过严格校验；报告：{report}")
    return 0 if ready == len(results) else 1


def cmd_validate(args: argparse.Namespace) -> int:
    source = read_source_lrc(args.source)
    result = validate_enhanced_lrc(source, args.enhanced.read_text(encoding="utf-8-sig"))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["valid"] else 1


def cmd_prepare_text(args: argparse.Namespace) -> int:
    source = read_source_lrc(args.source)
    indices = _alignment_indices(source, args.language)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        "\n".join(source.lines[index] for index in indices) + "\n",
        encoding="utf-8",
    )
    print(json.dumps({
        "output": str(args.output),
        "lineCount": len(indices),
        "auxiliaryLineCount": len(source.lines) - len(indices),
        "ignoredLeadingLines": list(source.ignored_leading_lines),
    }, ensure_ascii=False, indent=2))
    return 0


def _common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--music-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--lyric-align", type=Path, required=True)
    parser.add_argument("--model", default="medium")
    parser.add_argument("--device", default="cpu", choices=("cpu", "cuda"))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Harmony 增强歌词安全对齐工具")
    commands = parser.add_subparsers(required=True)
    align = commands.add_parser("align", help="对齐一首歌曲")
    _common(align)
    align.add_argument("--lrc", type=Path, required=True, help="相对于 music-root 的 LRC")
    align.add_argument("--language", default="zh")
    align.add_argument("--no-vad", action="store_true")
    align.add_argument("--separate", action="store_true")
    align.set_defaults(func=cmd_align)
    batch = commands.add_parser("batch", help="按清单批量对齐")
    _common(batch)
    batch.add_argument("--manifest", type=Path, required=True)
    batch.set_defaults(func=cmd_batch)
    validate = commands.add_parser("validate", help="验证增强 LRC")
    validate.add_argument("--source", type=Path, required=True)
    validate.add_argument("--enhanced", type=Path, required=True)
    validate.set_defaults(func=cmd_validate)
    prepare = commands.add_parser("prepare-text", help="从原 LRC 提取可信歌词正文")
    prepare.add_argument("--source", type=Path, required=True)
    prepare.add_argument("--output", type=Path, required=True)
    prepare.add_argument("--language", default="zh")
    prepare.set_defaults(func=cmd_prepare_text)
    convert = commands.add_parser("convert-swlrc", help="把 Xingyu SWLRC 转成 Harmony 增强 LRC")
    convert.add_argument("--source", type=Path, required=True)
    convert.add_argument("--source-lrc", type=Path, help="原始 LRC，用于无损恢复空格和标点")
    convert.add_argument("--output", type=Path, required=True)
    convert.add_argument("--language", default="zh")
    convert.set_defaults(func=cmd_convert_swlrc)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if hasattr(args, "output_root"):
        music_root = args.music_root.resolve()
        output_root = args.output_root.resolve()
        if output_root == music_root or music_root in output_root.parents:
            raise SystemExit("输出目录不能位于音乐库内，已停止以保护原文件")
        args.output_root.mkdir(parents=True, exist_ok=True)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
