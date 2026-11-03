import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/data_health_repository.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temp;
  late LibraryDatabase database;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('harmony-health-');
    database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
  });
  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  test('健康数据库通过完整性与外键检查', () async {
    await database.database;
    final report = await DataHealthRepository(database).inspect();
    expect(report.integrityOk, isTrue);
    expect(report.issues, isEmpty);
  });

  test('报告未结束播放、不可用歌曲、失效资源和孤立实体', () async {
    final db = await database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    const trackId = '00000000-0000-4000-8000-000000000101';
    await db.insert('tracks', {
      'track_id': trackId,
      'title': '测试歌曲',
      'added_at': now,
      'updated_at': now,
    });
    await db.insert('play_events', {
      'event_id': '00000000-0000-4000-8000-000000000102',
      'track_id': trackId,
      'started_at': now,
    });
    await db.insert('artwork_assets', {
      'artwork_id': '00000000-0000-4000-8000-000000000103',
      'track_id': trackId,
      'source': 'manual',
      'cache_path': '${temp.path}/missing-cover.jpg',
      'created_at': now,
    });
    await db.insert('artists', {
      'artist_id': '00000000-0000-4000-8000-000000000104',
      'display_name': '孤立歌手',
      'normalized_name': '孤立歌手',
      'created_at': now,
      'updated_at': now,
    });

    final report = await DataHealthRepository(database).inspect();
    expect(report.integrityOk, isTrue);
    expect(
      report.issues.map((issue) => issue.code),
      containsAll({
        'unfinished_playback',
        'unavailable_tracks',
        'missing_private_assets',
        'orphan_library_entities',
      }),
    );
    final whilePlaying = await DataHealthRepository(database)
        .inspect(activePlaybackEventId: '00000000-0000-4000-8000-000000000102');
    expect(
      whilePlaying.issues.where((issue) => issue.code == 'unfinished_playback'),
      isEmpty,
    );
    await db.insert('play_events', {
      'event_id': '00000000-0000-4000-8000-000000000105',
      'track_id': trackId,
      'started_at': now - 1000,
    });
    final withStaleEvent = await DataHealthRepository(database)
        .inspect(activePlaybackEventId: '00000000-0000-4000-8000-000000000102');
    expect(
      withStaleEvent.issues
          .singleWhere((issue) => issue.code == 'unfinished_playback')
          .count,
      1,
    );
  });
  test('被有效专辑引用的专辑歌手不应报告为孤立实体', () async {
    final db = await database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    const artistId = '00000000-0000-4000-8000-000000000111';
    const albumId = '00000000-0000-4000-8000-000000000112';
    const trackId = '00000000-0000-4000-8000-000000000113';
    const mediaFileId = '00000000-0000-4000-8000-000000000114';

    await db.insert('artists', {
      'artist_id': artistId,
      'display_name': '专辑歌手',
      'normalized_name': '专辑歌手',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('albums', {
      'album_id': albumId,
      'title': '有效专辑',
      'normalized_title': '有效专辑',
      'album_artist_id': artistId,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('tracks', {
      'track_id': trackId,
      'title': '专辑歌曲',
      'album_id': albumId,
      'added_at': now,
      'updated_at': now,
    });
    await db.insert('media_files', {
      'file_id': mediaFileId,
      'track_id': trackId,
      'content_uri': 'content://harmony/test/$mediaFileId',
      'filename': 'album-track.flac',
      'normalized_filename': 'album-track.flac',
      'extension': 'flac',
      'size_bytes': 1024,
      'status': 'active',
      'created_at': now,
      'updated_at': now,
    });

    final report = await DataHealthRepository(database).inspect();
    expect(report.integrityOk, isTrue);
    expect(
      report.issues.where((issue) => issue.code == 'orphan_library_entities'),
      isEmpty,
    );
  });
}
