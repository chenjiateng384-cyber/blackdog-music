import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/models/v4/library_entities.dart';
import 'package:my_music_library/models/v4/lyrics.dart';
import 'package:my_music_library/services/lrc_parser.dart';

void main() {
  const parser = LrcParser();

  test('解析 Metadata、多时间标签、毫秒精度和声明偏移', () {
    final parsed = parser.parse('''
[ar:周杰伦]
[ti:七里香]
[offset:120]
[00:01.5][00:02.50]窗外的麻雀
[01:03.125]在电线杆上多嘴
''');

    expect(parsed.metadata, {'ar': '周杰伦', 'ti': '七里香'});
    expect(parsed.declaredOffsetMs, 120);
    expect(parsed.lines, hasLength(3));
    expect(parsed.lines.map((line) => line.timestamp.inMilliseconds), [
      1500,
      2500,
      63125,
    ]);
    expect(parsed.lines.first.text, '窗外的麻雀');
  });

  test('保留增强逐字时间标签，并稳定排序同一时间的歌词', () {
    final parsed = parser.parse('''
[00:02.00]<00:02.00>你<00:02.20>好
[00:01.00]第一行
[00:01.00]第二行
''');

    expect(parsed.lines.map((line) => line.text), ['第一行', '第二行', '你好']);
    final enhanced = parsed.lines.last;
    expect(enhanced.words.map((word) => word.text), ['你', '好']);
    expect(enhanced.words.map((word) => word.timestamp.inMilliseconds), [
      2000,
      2200,
    ]);
    expect(enhanced.words.first.endTimestamp?.inMilliseconds, 2200);
  });

  test('增强 LRC 可以用空时间标记保留字间停顿和尾字延音', () {
    final parsed = parser.parse(
      '[00:02.00]<00:02.00>你<00:02.30><00:02.65>好<00:03.20>',
    );

    final words = parsed.lines.single.words;
    expect(words.map((word) => word.text), ['你', '好']);
    expect(words.map((word) => word.timestamp.inMilliseconds), [2000, 2650]);
    expect(words.map((word) => word.endTimestamp?.inMilliseconds), [
      2300,
      3200,
    ]);
  });

  test('普通 LRC 不伪造逐字时间', () {
    final parsed = parser.parse('[00:01.00]窗外的麻雀');

    expect(parsed.lines.single.words, isEmpty);
    expect(parsed.lines.single.timingMode, LyricsTimingMode.lineTimed);
  });

  test('增强 LRC 识别逐字模式并拒绝倒退的时间轴', () {
    final enhanced = parser.parse(
      '[00:01.00]<00:01.00>窗<00:01.20><00:01.45>外<00:01.80>',
    );
    final invalid = parser.parse('[00:01.00]<00:01.30>窗<00:01.10>外');

    expect(enhanced.lines.single.timingMode, LyricsTimingMode.wordTimed);
    expect(invalid.lines.single.timingMode, LyricsTimingMode.lineTimed);
    expect(invalid.lines.single.words, isEmpty);
  });

  test('TrackLyrics 可以二分查找当前位置对应歌词', () {
    final reference = LyricsReference(
      lyricsId: '11111111-2222-4333-8444-555555555555',
      trackId: '66666666-7777-4888-8999-aaaaaaaaaaaa',
      source: 'sidecarLrc',
      matchMethod: 'exactBasename',
      matched: true,
      confidence: 1,
      offsetMs: 0,
      isSelected: true,
      createdAt: DateTime(2026),
    );
    final lyrics = TrackLyrics(
      reference: reference,
      lines: const [
        LrcLine(timestamp: Duration(seconds: 1), text: '一'),
        LrcLine(timestamp: Duration(seconds: 3), text: '二'),
      ],
      metadata: const {},
      totalOffsetMs: 0,
    );

    expect(lyrics.lineAt(const Duration(milliseconds: 500)), isNull);
    expect(lyrics.lineAt(const Duration(seconds: 2))?.text, '一');
    expect(lyrics.lineAt(const Duration(seconds: 4))?.text, '二');
  });
}
