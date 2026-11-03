import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/models/song.dart';
import 'package:my_music_library/models/v4/legacy_song_compatibility.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/listening_data.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/track.dart';

void main() {
  test('V4 Track 通过 Preferred MediaFile 生成旧 UI Song', () {
    final item = _libraryTrack();
    final song = LegacySongCompatibility.libraryTrackToLegacySong(item);

    expect(song.id, 123);
    expect(song.uri, 'content://music/preferred-flac');
    expect(song.title, '稻香');
    expect(song.artist, '周杰伦');
    expect(song.displayName, '03_稻香.flac');
  });

  test('没有 MediaStore ID 时，Track UUID 生成跨调用稳定的兼容数字 ID', () {
    const trackId = '11111111-2222-4333-8444-555555555555';
    final first = LegacySongCompatibility.stableLegacyId(trackId);
    final second = LegacySongCompatibility.stableLegacyId(trackId);

    expect(first, second);
    expect(first, greaterThan(0));
  });

  test('旧 Song 可以进入兼容层，但只生成内存 Track，不写数据库', () {
    final legacy = Song(
      id: 9,
      uri: 'content://legacy/9',
      title: '旧歌曲',
      artist: '旧歌手',
      album: '旧专辑',
      duration: const Duration(minutes: 3),
      dateAdded: DateTime(2026),
      displayName: '旧歌曲.mp3',
      mimeType: 'audio/mpeg',
      sizeBytes: 1000,
      bitrate: 320000,
      sampleRate: 44100,
      bitsPerSample: 0,
    );

    final item = LegacySongCompatibility.libraryTrackFromLegacySong(legacy);

    expect(item.track.trackId, 'legacy-track-9');
    expect(item.preferredFile?.contentUri, legacy.uri);
    expect(item.isPlayable, isTrue);
  });
}

LibraryTrack _libraryTrack() {
  final now = DateTime(2026, 8, 20);
  const trackId = '11111111-2222-4333-8444-555555555555';
  return LibraryTrack(
    track: Track(
      trackId: trackId,
      title: '稻香',
      artistDisplay: '周杰伦',
      albumArtistDisplay: '周杰伦',
      albumDisplay: '魔杰座',
      durationMs: 223000,
      metadataState: 'complete',
      addedAt: now,
      updatedAt: now,
    ),
    preferredFile: MediaFile(
      fileId: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
      trackId: trackId,
      mediaStoreId: 123,
      contentUri: 'content://music/preferred-flac',
      filename: '03_稻香.flac',
      normalizedFilename: '03_稻香.flac',
      extension: 'flac',
      mimeType: 'audio/flac',
      sizeBytes: 30000000,
      durationMs: 223000,
      hashState: 'ready',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    ),
    preference: TrackPreference.empty(trackId, now),
    stats: TrackStats.empty(trackId, now),
  );
}
