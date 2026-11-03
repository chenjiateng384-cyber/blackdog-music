import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/models/song.dart';
import 'package:my_music_library/models/v4/artwork.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/listening_data.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/playback.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/services/music_audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('播放器 V4 队列使用稳定 TrackId，并忽略没有可播放文件的 Track', () async {
    final handler = MusicAudioHandler();
    addTearDown(handler.disposeHandler);
    handler.setTrackLibrary([
      _track('track-a', playable: true),
      _track('track-b'),
    ]);

    expect(handler.queueTrackIds, ['track-a']);
  });

  test('旧 Song 入口只作为适配层转换成 Track 队列', () async {
    final handler = MusicAudioHandler();
    addTearDown(handler.disposeHandler);
    handler.setLibrary([
      Song(
        id: 7,
        uri: 'content://legacy/7',
        title: '兼容歌曲',
        artist: '兼容歌手',
        album: '兼容专辑',
        duration: const Duration(minutes: 3),
        dateAdded: DateTime(2026),
        displayName: '兼容歌曲.mp3',
        mimeType: 'audio/mpeg',
        sizeBytes: 1000,
        bitrate: 320000,
        sampleRate: 44100,
        bitsPerSample: 0,
      ),
    ]);

    expect(handler.queueTrackIds, ['legacy-track-7']);
  });

  test('五种播放模式都能进入播放器业务层并同步系统播放状态', () async {
    final handler = MusicAudioHandler();
    addTearDown(handler.disposeHandler);
    handler.setTrackLibrary([
      _track('track-a', playable: true),
      _track('track-b', playable: true),
    ]);

    for (final mode in PlaybackMode.values) {
      await handler.setPlaybackMode(mode);
      expect(handler.playbackMode, mode);
    }
    expect(handler.playbackState.value.shuffleMode.name, 'all');

    await handler.setPlaybackMode(PlaybackMode.repeatOne);
    expect(handler.playbackState.value.repeatMode.name, 'one');
  });

  test('1000 首内部队列完整保留，系统媒体队列使用有限窗口且相同列表不重建', () {
    final handler = MusicAudioHandler();
    addTearDown(handler.disposeHandler);
    final tracks = List.generate(
      1000,
      (index) => _track('track-$index', playable: true),
    );

    handler.setTrackLibrary(tracks);
    final firstPublishedQueue = handler.queue.value;

    expect(handler.queueTrackIds, hasLength(1000));
    expect(firstPublishedQueue, hasLength(120));

    handler.setTrackLibrary(tracks);
    expect(handler.queue.value, same(firstPublishedQueue));
    expect(handler.queueTrackIds, hasLength(1000));
  });

  test('系统媒体队列包含锁屏和通知栏需要的真实封面与展示信息', () {
    final handler = MusicAudioHandler();
    addTearDown(handler.disposeHandler);
    handler.setTrackLibrary([
      _track('track-artwork', playable: true, artwork: true),
    ]);

    final item = handler.queue.value.single;
    expect(item.title, '歌曲');
    expect(item.artist, '歌手');
    expect(item.album, '专辑');
    expect(item.displayTitle, '歌曲');
    expect(item.displaySubtitle, '歌手');
    expect(item.displayDescription, '专辑');
    expect(item.artUri, Uri.file('/data/user/0/music/artwork/cover.jpg'));
  });
}

LibraryTrack _track(
  String trackId, {
  bool playable = false,
  bool artwork = false,
}) {
  final now = DateTime(2026, 8, 20);
  return LibraryTrack(
    track: Track(
      trackId: trackId,
      title: '歌曲',
      artistDisplay: '歌手',
      albumArtistDisplay: '歌手',
      albumDisplay: '专辑',
      durationMs: 180000,
      metadataState: 'complete',
      addedAt: now,
      updatedAt: now,
    ),
    preferredFile: playable
        ? MediaFile(
            fileId: 'file-$trackId',
            trackId: trackId,
            contentUri: 'content://music/$trackId',
            filename: '$trackId.flac',
            normalizedFilename: '$trackId.flac',
            extension: 'flac',
            mimeType: 'audio/flac',
            sizeBytes: 1000,
            durationMs: 180000,
            hashState: 'ready',
            status: 'active',
            createdAt: now,
            updatedAt: now,
          )
        : null,
    artwork: artwork
        ? ArtworkReference(
            artworkId: 'art-$trackId',
            trackId: trackId,
            fileId: 'file-$trackId',
            source: 'embedded',
            cachePath: '/data/user/0/music/artwork/cover.jpg',
            confidence: 1,
            createdAt: now,
          )
        : null,
    preference: TrackPreference.empty(trackId, now),
    stats: TrackStats.empty(trackId, now),
  );
}
