import '../models/v4/scan_models.dart';

class LyricsMatch {
  const LyricsMatch({
    required this.candidate,
    required this.method,
    required this.confidence,
  });

  final LyricsCandidate candidate;
  final String method;
  final double confidence;
}

class LrcMatcher {
  const LrcMatcher();

  LyricsMatch? match({
    required ScannedAudioFile audio,
    required String resolvedTitle,
    required String resolvedArtist,
  }) {
    final candidates = audio.lyricsCandidates;
    if (candidates.isEmpty) return null;
    final exact = _unique(
      candidates.where(
        (candidate) =>
            candidate.basename.toLowerCase() == audio.basename.toLowerCase(),
      ),
    );
    if (exact != null) {
      return LyricsMatch(
        candidate: exact,
        method: 'exactBasename',
        confidence: 1,
      );
    }
    final strippedAudio = _withoutTrackAndDecorations(audio.basename);
    final stripped = _unique(
      candidates.where(
        (candidate) =>
            _withoutTrackAndDecorations(candidate.basename) == strippedAudio,
      ),
    );
    if (stripped != null) {
      return LyricsMatch(
        candidate: stripped,
        method: 'normalizedWithoutTrack',
        confidence: 0.92,
      );
    }
    final normalizedTitle = _normalize(resolvedTitle);
    final normalizedArtistTitle = _normalize('$resolvedArtist$resolvedTitle');
    final title = _unique(
      candidates.where((candidate) {
        final value = _normalize(candidate.basename);
        return value == normalizedTitle || value == normalizedArtistTitle;
      }),
    );
    if (title != null) {
      return LyricsMatch(
        candidate: title,
        method: 'artistAndTitleNormalized',
        confidence: 0.82,
      );
    }
    return null;
  }

  LyricsCandidate? _unique(Iterable<LyricsCandidate> values) {
    final matches = values.take(2).toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  String _withoutTrackAndDecorations(String value) => _normalize(
    value
        .replaceFirst(RegExp(r'^\s*\d{1,3}\s*[._\- ]+'), '')
        .replaceAll(RegExp(r'[（(\[].*?[）)\]]'), ''),
  );

  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s_.\-/—·（）()\[\]]+'), '');
}
