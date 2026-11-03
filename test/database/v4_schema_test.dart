import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/library_repository.dart';
import 'package:my_music_library/data/v4_schema.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDirectory;

  setUpAll(sqfliteFfiInit);
  setUp(
    () async => tempDirectory = await Directory.systemTemp.createTemp(
      'music-v4-schema-',
    ),
  );
  tearDown(() async => tempDirectory.delete(recursive: true));

  test('空数据库直接创建完整 V4 Schema，重复打开不重复数据', () async {
    final path = '${tempDirectory.path}/library.db';
    var library = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: path,
    );
    var db = await library.database;

    expect(await db.getVersion(), V4Schema.version);
    final tables = await _tables(db);
    expect(
      tables,
      containsAll([...V4Schema.legacyTables, ...V4Schema.v4Tables]),
    );
    expect((await db.rawQuery('PRAGMA foreign_keys')).single.values.single, 1);
    expect((await db.query('migration_state')).single['status'], 'ready');
    await library.close();

    library = LibraryDatabase(factory: databaseFactoryFfi, databasePath: path);
    db = await library.database;
    expect((await db.query('migration_state')).length, 1);
    expect((await db.query('playlists')).length, 0);
    await library.close();
  });

  test('已有 V4 数据库以纯新增方式升级文件身份关系表', () async {
    final path = '${tempDirectory.path}/v4-to-v5.db';
    final original = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: path,
    );
    final originalDb = await original.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    const track = '00000000-0000-4000-8000-000000000081';
    await _insertTrack(originalDb, track, now);
    await originalDb.execute('DROP TABLE media_file_relations');
    await originalDb.execute(
      'ALTER TABLE tracks DROP COLUMN preferred_file_source',
    );
    await originalDb.setVersion(4);
    await original.close();

    final upgraded = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: path,
    );
    final upgradedDb = await upgraded.database;
    expect(await upgradedDb.getVersion(), V4Schema.version);
    expect(await _tables(upgradedDb), contains('media_file_relations'));
    expect(await _tables(upgradedDb), contains('artist_profiles'));
    final trackColumns = await upgradedDb.rawQuery('PRAGMA table_info(tracks)');
    expect(
      trackColumns.map((row) => row['name']),
      contains('preferred_file_source'),
    );
    expect(await upgradedDb.query('tracks'), hasLength(1));
    await upgraded.close();
  });

  test('外键、唯一约束和首选文件归属约束生效', () async {
    final library = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${tempDirectory.path}/constraints.db',
    );
    final db = await library.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    const trackA = '00000000-0000-4000-8000-000000000001';
    const trackB = '00000000-0000-4000-8000-000000000002';
    const fileA = '00000000-0000-4000-8000-000000000003';
    const playlist = '00000000-0000-4000-8000-000000000004';

    await _insertTrack(db, trackA, now);
    await _insertTrack(db, trackB, now);
    await db.insert('media_files', {
      'file_id': fileA,
      'track_id': trackA,
      'filename': 'a.flac',
      'normalized_filename': 'a.flac',
      'created_at': now,
      'updated_at': now,
    });
    await db.update(
      'tracks',
      {'preferred_media_file_id': fileA},
      where: 'track_id = ?',
      whereArgs: [trackA],
    );
    expect(
      () => db.update(
        'tracks',
        {'preferred_media_file_id': fileA},
        where: 'track_id = ?',
        whereArgs: [trackB],
      ),
      throwsA(isA<DatabaseException>()),
    );

    await db.insert('track_preferences', {
      'track_id': trackA,
      'updated_at': now,
    });
    expect(
      () => db.insert('track_preferences', {
        'track_id': trackA,
        'updated_at': now,
      }),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      () => db.insert('media_files', {
        'file_id': '00000000-0000-4000-8000-000000000005',
        'track_id': '00000000-0000-4000-8000-000000000099',
        'filename': 'missing.mp3',
        'normalized_filename': 'missing.mp3',
        'created_at': now,
        'updated_at': now,
      }),
      throwsA(isA<DatabaseException>()),
    );

    await db.insert('playlists', {
      'playlist_id': playlist,
      'name': '测试',
      'type': 'user',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('playlist_tracks', {
      'playlist_id': playlist,
      'track_id': trackA,
      'position': 0,
      'added_at': now,
    });
    expect(
      () => db.insert('playlist_tracks', {
        'playlist_id': playlist,
        'track_id': trackA,
        'position': 1,
        'added_at': now,
      }),
      throwsA(isA<DatabaseException>()),
    );
    await library.close();
  });

  test('删除 MediaFile 只清空首选文件，不删除 Track 用户数据', () async {
    final library = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${tempDirectory.path}/delete.db',
    );
    final db = await library.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    const track = '00000000-0000-4000-8000-000000000011';
    const file = '00000000-0000-4000-8000-000000000012';
    await _insertTrack(db, track, now);
    await db.insert('media_files', {
      'file_id': file,
      'track_id': track,
      'filename': 'song.flac',
      'normalized_filename': 'song.flac',
      'created_at': now,
      'updated_at': now,
    });
    await db.update(
      'tracks',
      {'preferred_media_file_id': file},
      where: 'track_id = ?',
      whereArgs: [track],
    );
    await db.insert('track_preferences', {
      'track_id': track,
      'liked': 1,
      'updated_at': now,
    });

    await db.delete('media_files', where: 'file_id = ?', whereArgs: [file]);
    expect(
      (await db.query('tracks')).single['preferred_media_file_id'],
      isNull,
    );
    expect((await db.query('tracks')).length, 1);
    expect((await db.query('track_preferences')).single['liked'], 1);
    await library.close();
  });

  test('更新 MediaFile 不触发删除语义并保留首选文件关系', () async {
    final library = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${tempDirectory.path}/safe-upsert.db',
    );
    final db = await library.database;
    final repository = LibraryRepository(library);
    final now = DateTime.now();
    const track = '00000000-0000-4000-8000-000000000021';
    const file = '00000000-0000-4000-8000-000000000022';
    await _insertTrack(db, track, now.millisecondsSinceEpoch);
    await repository.saveMediaFile(
      MediaFile(
        fileId: file,
        trackId: track,
        filename: 'song.mp3',
        normalizedFilename: 'song.mp3',
        extension: 'mp3',
        mimeType: 'audio/mpeg',
        sizeBytes: 100,
        durationMs: 1000,
        hashState: 'pending',
        status: 'active',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repository.setPreferredMediaFile(track, file);
    await repository.saveMediaFile(
      MediaFile(
        fileId: file,
        trackId: track,
        filename: 'renamed.mp3',
        normalizedFilename: 'renamed.mp3',
        extension: 'mp3',
        mimeType: 'audio/mpeg',
        sizeBytes: 200,
        durationMs: 1000,
        hashState: 'pending',
        status: 'active',
        createdAt: now,
        updatedAt: now.add(const Duration(seconds: 1)),
      ),
    );

    final trackRow = (await db.query('tracks')).single;
    final fileRow = (await db.query('media_files')).single;
    expect(trackRow['preferred_media_file_id'], file);
    expect(fileRow['filename'], 'renamed.mp3');
    expect(fileRow['size_bytes'], 200);
    await library.close();
  });
}

Future<Set<String>> _tables(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table'",
  );
  return rows.map((row) => row['name']! as String).toSet();
}

Future<void> _insertTrack(Database db, String id, int now) => db.insert(
  'tracks',
  {'track_id': id, 'title': '测试歌曲', 'added_at': now, 'updated_at': now},
);
