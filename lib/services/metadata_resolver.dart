import '../models/v4/scan_models.dart';
import 'metadata_inference.dart';

class ResolvedTrackMetadata {
  const ResolvedTrackMetadata({
    required this.title,
    required this.artist,
    required this.albumArtist,
    required this.album,
    required this.albumType,
    required this.metadataState,
    this.year,
    this.discNumber,
    this.trackNumber,
  });

  final String title;
  final String artist;
  final String albumArtist;
  final String album;
  final int? year;
  final int? discNumber;
  final int? trackNumber;
  final String albumType;
  final String metadataState;
}

class MetadataResolver {
  const MetadataResolver();

  ResolvedTrackMetadata resolve({
    required AudioTagSnapshot raw,
    required InferredAudioMetadata inferred,
    Map<String, Object?> override = const {},
  }) {
    String? text(String field, String? rawValue, String? inferredValue) =>
        _text(override[field]) ?? _text(rawValue) ?? _text(inferredValue);
    String? artistText(String field, String? rawValue, String? inferredValue) =>
        _text(override[field]) ??
        _validArtist(rawValue) ??
        _validArtist(inferredValue);
    int? number(String field, int? rawValue, int? inferredValue) =>
        _integer(override[field]) ?? rawValue ?? inferredValue;
    final title = text('title', raw.title, inferred.title) ?? '未知歌曲';
    final artist = artistText('artist', raw.artist, inferred.artist) ?? '未知歌手';
    final albumArtist =
        artistText('album_artist', raw.albumArtist, inferred.albumArtist) ??
        artist;
    final album = text('album', raw.album, inferred.album) ?? '未知专辑';
    final reliable =
        title != '未知歌曲' &&
        artist != '未知歌手' &&
        (raw.hasReliableIdentity || !inferred.needsReview);
    return ResolvedTrackMetadata(
      title: title,
      artist: artist,
      albumArtist: albumArtist,
      album: album,
      year: number('year', raw.year, inferred.year),
      discNumber: number('disc_number', raw.discNumber, inferred.discNumber),
      trackNumber: number(
        'track_number',
        raw.trackNumber,
        inferred.trackNumber,
      ),
      albumType: inferred.albumType,
      metadataState: reliable ? 'complete' : 'needsReview',
    );
  }
}

String? _text(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

int? _integer(Object? value) => value is num ? value.toInt() : null;

String? _validArtist(String? value) {
  final text = _text(value);
  if (text == null) return null;
  final normalized = text.toLowerCase().replaceAll(
    RegExp(r'[\s_.\-/—·（）()\[\]]+'),
    '',
  );
  if (_categoryArtistNames.contains(normalized)) return null;
  return text;
}

const _categoryArtistNames = {
  '英文歌',
  '零散单曲',
  '单曲',
  'singles',
  'single',
  '其他歌手',
  '其他',
  '未分类',
  '音乐文件',
  'music',
};
