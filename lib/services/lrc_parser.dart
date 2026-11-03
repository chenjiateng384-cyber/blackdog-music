import '../models/v4/lyrics.dart';

class LrcParser {
  const LrcParser();

  ParsedLrc parse(String content) {
    final metadata = <String, String>{};
    final lines = <_IndexedLrcLine>[];
    var declaredOffsetMs = 0;
    var sourceIndex = 0;
    for (final rawLine
        in content.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'))) {
      final metadataMatch = _metadata.firstMatch(rawLine.trim());
      if (metadataMatch != null) {
        final key = metadataMatch.group(1)!.toLowerCase();
        final value = metadataMatch.group(2)!.trim();
        if (key == 'offset') {
          declaredOffsetMs = int.tryParse(value) ?? declaredOffsetMs;
        } else {
          metadata[key] = value;
        }
        continue;
      }
      final timestamps = _timestamp.allMatches(rawLine).toList(growable: false);
      if (timestamps.isEmpty) continue;
      final body = rawLine.substring(timestamps.last.end);
      final wordMatches = _enhancedWordTimestamp
          .allMatches(body)
          .toList(growable: false);
      final text = body.replaceAll(_enhancedWordTimestamp, '').trim();
      final firstLineTimestamp = _durationFromMatch(timestamps.first);
      for (final match in timestamps) {
        final timestamp = _durationFromMatch(match);
        if (timestamp == null) continue;
        final shift = firstLineTimestamp == null
            ? Duration.zero
            : timestamp - firstLineTimestamp;
        lines.add(
          _IndexedLrcLine(
            timestamp: timestamp,
            text: text,
            words: _parseWords(body, wordMatches, shift),
            sourceIndex: sourceIndex++,
          ),
        );
      }
    }
    lines.sort((left, right) {
      final byTime = left.timestamp.compareTo(right.timestamp);
      return byTime != 0
          ? byTime
          : left.sourceIndex.compareTo(right.sourceIndex);
    });
    return ParsedLrc(
      lines: List.unmodifiable(
        lines.map(
          (line) => LrcLine(
            timestamp: line.timestamp,
            text: line.text,
            words: line.words,
          ),
        ),
      ),
      metadata: Map.unmodifiable(metadata),
      declaredOffsetMs: declaredOffsetMs,
    );
  }

  static final _timestamp = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
  static final _metadata = RegExp(
    r'^\[(ar|ti|al|by|re|ve|length|offset):([^\]]*)\]$',
    caseSensitive: false,
  );
  static final _enhancedWordTimestamp = RegExp(
    r'<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>',
  );

  static Duration? _durationFromMatch(Match match) {
    final minutes = int.parse(match.group(1)!);
    final seconds = int.parse(match.group(2)!);
    if (seconds >= 60) return null;
    final fraction = match.group(3);
    final milliseconds = fraction == null
        ? 0
        : fraction.length == 1
        ? int.parse(fraction) * 100
        : fraction.length == 2
        ? int.parse(fraction) * 10
        : int.parse(fraction.substring(0, 3));
    return Duration(
      minutes: minutes,
      seconds: seconds,
      milliseconds: milliseconds,
    );
  }

  static List<LrcWord> _parseWords(
    String body,
    List<RegExpMatch> matches,
    Duration shift,
  ) {
    if (matches.isEmpty) return const <LrcWord>[];
    final words = <LrcWord>[];
    for (var index = 0; index < matches.length; index++) {
      final match = matches[index];
      final timestamp = _durationFromMatch(match);
      if (timestamp == null) continue;
      final end = index + 1 < matches.length
          ? matches[index + 1].start
          : body.length;
      final value = body.substring(match.end, end);
      final shiftedTimestamp = timestamp + shift;
      if (words.isNotEmpty &&
          words.last.endTimestamp == null &&
          shiftedTimestamp >= words.last.timestamp) {
        final previous = words.removeLast();
        words.add(
          LrcWord(
            timestamp: previous.timestamp,
            endTimestamp: shiftedTimestamp,
            text: previous.text,
          ),
        );
      }
      if (value.trim().isEmpty) continue;
      words.add(LrcWord(timestamp: shiftedTimestamp, text: value));
    }
    if (!_hasValidWordTiming(words, body)) return const <LrcWord>[];
    return List<LrcWord>.unmodifiable(words);
  }

  static bool _hasValidWordTiming(List<LrcWord> words, String body) {
    if (words.isEmpty) return false;
    final plainText = body.replaceAll(_enhancedWordTimestamp, '').trim();
    if (words.map((word) => word.text).join().trim() != plainText) return false;
    for (var index = 0; index < words.length; index++) {
      final word = words[index];
      final end = word.endTimestamp;
      if (end != null && end < word.timestamp) return false;
      if (index > 0 && word.timestamp < words[index - 1].timestamp) {
        return false;
      }
    }
    return true;
  }
}

class _IndexedLrcLine {
  const _IndexedLrcLine({
    required this.timestamp,
    required this.text,
    required this.words,
    required this.sourceIndex,
  });

  final Duration timestamp;
  final String text;
  final List<LrcWord> words;
  final int sourceIndex;
}
