import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/library_repository.dart';
import 'package:my_music_library/data/music_archive_repository.dart';
import 'package:my_music_library/models/v4/library_entities.dart';
import 'package:my_music_library/models/v4/listening_data.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temp;
  late LibraryDatabase database;
  late LibraryRepository library;
  late MusicArchiveRepository archive;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('music-archive-');
    database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    library = LibraryRepository(database);
    archive = MusicArchiveRepository(database, library);
    await _seedLibrary(database, library);
  });
  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  test('年度档案由真实播放事件聚合并使用主要歌手', () async {
    final db = await database.database;
    for (var index = 0; index < 10; index++) {
      await _insertEvent(
        db,
        serial: index,
        trackId: _trackOne,
        startedAt: DateTime(2026, 7, 1 + index, 22),
        listenedMs: 60000,
      );
    }
    for (var index = 10; index < 12; index++) {
      await _insertEvent(
        db,
        serial: index,
        trackId: _trackTwo,
        startedAt: DateTime(2026, 8, index, 10),
        listenedMs: 30000,
      );
    }
    await _insertEvent(
      db,
      serial: 99,
      trackId: _trackOne,
      startedAt: DateTime(2024, 3, 2, 20),
      listenedMs: 1000,
    );

    final result = await archive.load(DateTime(2026, 9, 1));

    expect(result.validEventCount, 12);
    expect(result.distinctTrackCount, 2);
    expect(result.listenedDurationMs, 660000);
    expect(result.topTrack?.track.trackId, _trackOne);
    expect(result.topArtist, '周杰伦');
    expect(result.topAlbum, '七里香');
    expect(result.listeningPeriod, '晚上 10 点以后');
    expect(result.likedCount, 1);
    expect(result.playlistCount, 1);
    expect(result.recordStartedAt, DateTime(2024, 3, 2, 20));
  });

  test('数据不足时不虚构常听时间段并回退到最早入库日期', () async {
    final result = await archive.load(DateTime(2026, 9, 1));

    expect(result.hasListeningData, isFalse);
    expect(result.topTrack, isNull);
    expect(result.listeningPeriod, isNull);
    expect(result.recordStartedAt, DateTime(2025, 1, 2));
  });
}

const _trackOne = '11111111-1111-4111-8111-111111111111';
const _trackTwo = '22222222-2222-4222-8222-222222222222';
const _artistId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _albumId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

Future<void> _seedLibrary(
  LibraryDatabase database,
  LibraryRepository library,
) async {
  final addedAt = DateTime(2025, 1, 2);
  await library.saveArtist(
    const Artist(
      artistId: _artistId,
      displayName: '周杰伦',
      normalizedName: '周杰伦',
    ),
    now: addedAt,
  );
  await library.saveAlbum(
    const Album(
      albumId: _albumId,
      title: '七里香',
      normalizedTitle: '七里香',
      albumType: 'studio',
      albumArtistId: _artistId,
      year: 2004,
    ),
    now: addedAt,
  );
  for (final item in [
    (_trackOne, '七里香', '01_七里香.flac'),
    (_trackTwo, '借口', '03_借口.flac'),
  ]) {
    final fileId = item.$1 == _trackOne
        ? 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        : 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    await library.createTrack(
      Track(
        trackId: item.$1,
        title: item.$2,
        artistDisplay: '周杰伦',
        albumArtistDisplay: '周杰伦',
        albumDisplay: '七里香',
        albumId: _albumId,
        durationMs: 240000,
        metadataState: 'complete',
        addedAt: addedAt,
        updatedAt: addedAt,
      ),
    );
    await library.saveMediaFile(
      MediaFile(
        fileId: fileId,
        trackId: item.$1,
        contentUri: 'content://music/${item.$3}',
        filename: item.$3,
        normalizedFilename: item.$3.toLowerCase(),
        extension: 'flac',
        mimeType: 'audio/flac',
        sizeBytes: 1000,
        durationMs: 240000,
        hashState: 'ready',
        status: 'active',
        createdAt: addedAt,
        updatedAt: addedAt,
      ),
    );
    await library.setPreferredMediaFile(item.$1, fileId);
  }
  final db = await database.database;
  for (final trackId in [_trackOne, _trackTwo]) {
    await db.insert('track_artists', {
      'track_id': trackId,
      'artist_id': _artistId,
      'role': 'primary',
      'position': 0,
    });
  }
  await library.savePreference(
    TrackPreference(
      trackId: _trackOne,
      liked: true,
      likedAt: addedAt,
      recommendationExcluded: false,
      updatedAt: addedAt,
    ),
  );
  await library.createPlaylist(
    Playlist(
      playlistId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      name: '夜晚',
      type: 'user',
      createdAt: addedAt,
      updatedAt: addedAt,
    ),
  );
  await library.createPlaylist(
    Playlist(
      playlistId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
      name: '系统列表',
      type: 'system',
      createdAt: addedAt,
      updatedAt: addedAt,
    ),
  );
}

Future<void> _insertEvent(
  Database db, {
  required int serial,
  required String trackId,
  required DateTime startedAt,
  required int listenedMs,
}) => db.insert('play_events', {
  'event_id': '00000000-0000-4000-8000-${serial.toString().padLeft(12, '0')}',
  'track_id': trackId,
  'started_at': startedAt.millisecondsSinceEpoch,
  'ended_at': startedAt
      .add(Duration(milliseconds: listenedMs))
      .millisecondsSinceEpoch,
  'listened_duration_ms': listenedMs,
  'track_duration_ms': 240000,
  'completed': 0,
  'skipped': 0,
  'manually_selected': 1,
  'context_type': 'library',
  'playback_mode': 'sequential',
});
