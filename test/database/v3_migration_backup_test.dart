import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/database_backup.dart';
import 'package:my_music_library/data/migration_repository.dart';
import 'package:my_music_library/data/v4_schema.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDirectory;

  setUpAll(sqfliteFfiInit);
  setUp(
    () async => tempDirectory = await Directory.systemTemp.createTemp(
      'music-v3-migration-',
    ),
  );
  tearDown(() async => tempDirectory.delete(recursive: true));

  test('V3 用户数据原样保留并建立 awaiting_scan 迁移框架', () async {
    final path = '${tempDirectory.path}/library.db';
    await _createPopulatedV3(path);
    final backupDirectory = Directory('${tempDirectory.path}/backups');
    final library = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: path,
      backupDirectory: backupDirectory,
    );
    final db = await library.database;

    expect(await db.getVersion(), V4Schema.version);
    expect(await _count(db, 'favorites'), 1);
    expect(await _count(db, 'categories'), 2);
    expect(await _count(db, 'category_songs'), 2);
    expect(await _count(db, 'song_overrides'), 1);
    expect(await _count(db, 'metadata_cache'), 1);
    expect(await _count(db, 'playlists'), 2);
    expect(await _count(db, 'legacy_song_map'), 2);
    expect(
      (await db.query('migration_state')).single['status'],
      'awaiting_scan',
    );

    final backup = library.lastUpgradeBackup;
    expect(backup, isNotNull);
    expect(backup!.checkpointVerified, isTrue);
    expect(backup.databaseVerified, isTrue);
    expect(await File(backup.databasePath).exists(), isTrue);
    expect(await File(backup.exportPath).exists(), isTrue);
    expect(await File(backup.manifestPath).exists(), isTrue);
    final export = jsonDecode(
      await File(backup.exportPath).readAsString(),
    ) as Map<String, dynamic>;
    final tables = export['tables'] as Map<String, dynamic>;
    expect((tables['favorites'] as List).length, 1);
    expect((tables['category_songs'] as List).length, 2);
    expect((tables['metadata_cache'] as List).length, 1);
    await library.close();

    final restoredPath = '${tempDirectory.path}/restored-v3.db';
    await DatabaseBackupService(
      factory: databaseFactoryFfi,
      backupDirectory: backupDirectory,
    ).restore(backup: backup, targetPath: restoredPath);
    final restored = await databaseFactoryFfi.openDatabase(
      restoredPath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    expect(await restored.getVersion(), 3);
    expect(await _count(restored, 'favorites'), 1);
    expect(await _count(restored, 'categories'), 2);
    expect(await _count(restored, 'category_songs'), 2);
    expect(await _count(restored, 'song_overrides'), 1);
    expect(await _count(restored, 'metadata_cache'), 1);
    await restored.close();
  });

  test('重复打开 V4 不重复建立歌单或迁移映射', () async {
    final path = '${tempDirectory.path}/idempotent.db';
    await _createPopulatedV3(path);
    var library = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: path,
      backupDirectory: Directory('${tempDirectory.path}/backups'),
    );
    await library.database;
    await library.close();

    library = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: path,
      backupDirectory: Directory('${tempDirectory.path}/backups'),
    );
    final db = await library.database;
    expect(await _count(db, 'playlists'), 2);
    expect(await _count(db, 'legacy_song_map'), 2);
    expect(library.lastUpgradeBackup, isNull);
    await library.close();
  });

  test('Schema Migration 中途异常会完整回滚且下次可重试', () async {
    final path = '${tempDirectory.path}/failure.db';
    await _createPopulatedV3(path);
    final backupDirectory = Directory('${tempDirectory.path}/failure-backups');
    final failing = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: path,
      backupDirectory: backupDirectory,
      schemaFaultInjector: (index, _) {
        if (index == 7) throw StateError('injected schema failure');
      },
    );

    await expectLater(failing.database, throwsA(isA<StateError>()));
    final raw = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    expect(await raw.getVersion(), 3);
    expect(await _count(raw, 'favorites'), 1);
    expect(await _tables(raw), isNot(contains('tracks')));
    await raw.close();
    expect(
      (await backupDirectory.list().toList()).whereType<File>(),
      isNotEmpty,
    );

    final retry = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: path,
      backupDirectory: backupDirectory,
    );
    final upgraded = await retry.database;
    expect(await upgraded.getVersion(), V4Schema.version);
    expect(await _count(upgraded, 'favorites'), 1);
    expect(
      (await upgraded.query('migration_state')).single['status'],
      'awaiting_scan',
    );
    await retry.close();
  });

  test('旧关联可以幂等迁入喜欢、歌单和人工 Override', () async {
    final path = '${tempDirectory.path}/link.db';
    await _createPopulatedV3(path);
    final library = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: path,
      backupDirectory: Directory('${tempDirectory.path}/backups'),
    );
    final db = await library.database;
    const trackId = '00000000-0000-4000-8000-000000000101';
    const fileId = '00000000-0000-4000-8000-000000000102';
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('tracks', {
      'track_id': trackId,
      'title': '晴天',
      'added_at': now,
      'updated_at': now,
    });
    await db.insert('media_files', {
      'file_id': fileId,
      'track_id': trackId,
      'filename': '晴天.flac',
      'normalized_filename': '晴天.flac',
      'created_at': now,
      'updated_at': now,
    });
    final migration = MigrationRepository(library);
    await migration.linkLegacySong(
      legacySongId: 11,
      trackId: trackId,
      fileId: fileId,
    );
    await migration.linkLegacySong(
      legacySongId: 11,
      trackId: trackId,
      fileId: fileId,
    );

    expect(await _count(db, 'track_preferences'), 1);
    expect((await db.query('track_preferences')).single['liked'], 1);
    expect(await _count(db, 'track_overrides'), 1);
    expect(await _count(db, 'playlist_tracks'), 2);
    expect((await migration.awaitingLegacySongIds()), [12]);
    await library.close();
  });
}

Future<void> _createPopulatedV3(String path) async {
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 3,
      singleInstance: false,
      onCreate: (db, _) async {
        await V4Schema.createLegacyTables(db);
      },
    ),
  );
  await db.execute('PRAGMA journal_mode = WAL');
  await db.insert('favorites', {'song_id': 11});
  final gym = await db.insert('categories', {'name': '健身'});
  final night = await db.insert('categories', {'name': '夜晚'});
  await db.insert('category_songs', {'category_id': gym, 'song_id': 11});
  await db.insert('category_songs', {'category_id': night, 'song_id': 11});
  await db.insert('song_overrides', {
    'song_id': 11,
    'title': '晴天',
    'artist': '周杰伦',
    'album': '叶惠美',
  });
  await db.insert('metadata_cache', {
    'song_id': 12,
    'title': '稻香',
    'artist': '周杰伦',
    'album': '魔杰座',
    'artwork': Uint8List.fromList([1, 2, 3]),
    'matched': 1,
    'checked_at': DateTime.now().millisecondsSinceEpoch,
  });
  await db.close();
}

Future<int> _count(DatabaseExecutor db, String table) async {
  final rows = await db.rawQuery('SELECT COUNT(*) AS count FROM $table');
  return (rows.single['count']! as num).toInt();
}

Future<Set<String>> _tables(DatabaseExecutor db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table'",
  );
  return rows.map((row) => row['name']! as String).toSet();
}
