import 'library_entities.dart';

enum LyricsTimingMode { lineTimed, wordTimed }

class LrcWord {
  const LrcWord({
    required this.timestamp,
    required this.text,
    this.endTimestamp,
  });

  /// Absolute playback position at which this word/phrase becomes active.
  final Duration timestamp;

  /// Exact end position when the enhanced LRC provides one.
  ///
  /// A gap between this value and the next word's start is a real pause, so
  /// the highlight must remain still instead of stretching across that gap.
  final Duration? endTimestamp;
  final String text;
}

class LrcLine {
  const LrcLine({
    required this.timestamp,
    required this.text,
    this.words = const <LrcWord>[],
  });

  final Duration timestamp;
  final String text;
  final List<LrcWord> words;

  bool get hasWordTiming => words.isNotEmpty;
  LyricsTimingMode get timingMode =>
      hasWordTiming ? LyricsTimingMode.wordTimed : LyricsTimingMode.lineTimed;
}

class ParsedLrc {
  const ParsedLrc({
    required this.lines,
    required this.metadata,
    required this.declaredOffsetMs,
  });

  final List<LrcLine> lines;
  final Map<String, String> metadata;
  final int declaredOffsetMs;
}

class TrackLyrics {
  const TrackLyrics({
    required this.reference,
    required this.lines,
    required this.metadata,
    required this.totalOffsetMs,
  });

  final LyricsReference reference;
  final List<LrcLine> lines;
  final Map<String, String> metadata;
  final int totalOffsetMs;

  LyricsTimingMode get timingMode =>
      lines.any((line) => line.timingMode == LyricsTimingMode.wordTimed)
      ? LyricsTimingMode.wordTimed
      : LyricsTimingMode.lineTimed;

  LrcLine? lineAt(Duration position) {
    if (lines.isEmpty) return null;
    var low = 0;
    var high = lines.length - 1;
    var selected = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (lines[middle].timestamp <= position) {
        selected = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return selected < 0 ? null : lines[selected];
  }
}
