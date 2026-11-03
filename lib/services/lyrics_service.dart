import '../data/lyrics_repository.dart';
import '../models/v4/library_entities.dart';
import '../models/v4/lyrics.dart';
import 'lrc_parser.dart';
import 'v4_scan_platform.dart';

abstract interface class LyricsContentSource {
  Future<String> read(String uri);
}

class PlatformLyricsContentSource implements LyricsContentSource {
  const PlatformLyricsContentSource([this._platform = const V4ScanPlatform()]);

  final V4ScanPlatform _platform;

  @override
  Future<String> read(String uri) => _platform.readTextDocument(uri);
}

class LyricsService {
  const LyricsService({
    required this.repository,
    this.contentSource = const PlatformLyricsContentSource(),
    this.parser = const LrcParser(),
  });

  final LyricsRepository repository;
  final LyricsContentSource contentSource;
  final LrcParser parser;

  Future<TrackLyrics?> loadForTrack(String trackId) async {
    final reference = await repository.selectedForTrack(trackId);
    if (reference == null) return null;
    final content = await _content(reference);
    if (content == null || content.trim().isEmpty) return null;
    final parsed = parser.parse(content);
    final totalOffset = reference.offsetMs + parsed.declaredOffsetMs;
    final adjusted = parsed.lines
        .map(
          (line) => LrcLine(
            timestamp: Duration(
              milliseconds: (line.timestamp.inMilliseconds + totalOffset).clamp(
                0,
                1 << 31,
              ),
            ),
            text: line.text,
            words: List<LrcWord>.unmodifiable(
              line.words.map(
                (word) => LrcWord(
                  timestamp: Duration(
                    milliseconds: (word.timestamp.inMilliseconds + totalOffset)
                        .clamp(0, 1 << 31),
                  ),
                  endTimestamp: word.endTimestamp == null
                      ? null
                      : Duration(
                          milliseconds:
                              (word.endTimestamp!.inMilliseconds + totalOffset)
                                  .clamp(0, 1 << 31),
                        ),
                  text: word.text,
                ),
              ),
            ),
          ),
        )
        .toList(growable: false);
    return TrackLyrics(
      reference: reference,
      lines: List.unmodifiable(adjusted),
      metadata: parsed.metadata,
      totalOffsetMs: totalOffset,
    );
  }

  Future<String?> _content(LyricsReference reference) async {
    if (reference.source == 'embedded' && reference.mediaFileId != null) {
      return repository.embeddedContent(reference.mediaFileId!);
    }
    final uri = reference.documentUri ?? reference.contentUri;
    return uri == null || uri.isEmpty ? null : contentSource.read(uri);
  }
}
