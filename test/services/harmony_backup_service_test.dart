import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/playlist_repository.dart';
import 'package:my_music_library/services/backup_platform.dart';
import 'package:my_music_library/services/harmony_backup_service.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temp;
  late Directory packageDirectory;
  late Directory supportDirectory;
  late LibraryDatabase database;
  late _FakeBackupGateway gateway;
  late HarmonyBackupService service;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('harmony-backup-');
    packageDirectory = Directory('${temp.path}/package');
    supportDirectory = Directory('${temp.path}/support')..createSync();
    database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/current.db',
    );
    gateway = _FakeBackupGateway(packageDirectory);
    service = HarmonyBackupService(
      database: database,
      gateway: gateway,
      temporaryDirectory: () async => temp,
      supportDirectory: () async => supportDirectory,
    );
  });
  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  test('自选歌单封面随备份恢复，不依赖原图或原私有路径', () async {
    final source = File('${temp.path}/playlist.jpg');
    await source.writeAsBytes([7, 8, 9]);
    final playlists = PlaylistRepository(
      database,
      supportDirectory: () async => supportDirectory,
    );
    final playlist = await playlists.create('骑行', coverPath: source.path);
    final cover = (await playlists.covers())[playlist.playlistId]!;
    await service.exportBackup();
    await File(cover.cachePath!).delete();
    await source.delete();
    await service.restoreBackup();
    final restored = (await playlists.covers())[playlist.playlistId]!;
    expect(await File(restored.cachePath!).readAsBytes(), [7, 8, 9]);
    expect((await playlists.playlistById(playlist.playlistId))!.name, '骑行');
  });

  test('导出一致性数据库、设置、清单和人工封面', () async {
    final seeded = await _seed(database, temp);
    await SharedPreferences.getInstance().then(
      (prefs) => prefs.setString('harmony.listening_preference.v1', 'quiet'),
    );

    final result = await service.exportBackup();

    expect(result, isNotNull);
    expect(File('${packageDirectory.path}/library.db').existsSync(), isTrue);
    expect(File('${packageDirectory.path}/manifest.json').existsSync(), isTrue);
    expect(File('${packageDirectory.path}/settings.json').existsSync(), isTrue);
    expect(Directory('${packageDirectory.path}/assets').existsSync(), isTrue);
    expect(result!.manifest.rowCounts['track_preferences'], 1);
    expect(result.manifest.rowCounts['playlists'], 1);
    expect(result.manifest.files, contains('library.db'));
    expect(result.manifest.files, contains('settings.json'));
    expect(
      result.manifest.files.keys,
      contains('assets/${seeded.artworkId}.jpg'),
    );
    expect(await service.lastSuccessfulBackupAt(), isNotNull);
  });

  test('恢复整库数据、歌单顺序、设置和人工封面路径', () async {
    final seeded = await _seed(database, temp);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('harmony.listening_preference.v1', 'backup-value');
    await service.exportBackup();

    final db = await database.database;
    await db.update(
      'track_preferences',
      {'liked': 0},
      where: 'track_id = ?',
      whereArgs: [seeded.trackId],
    );
    await db.delete('playlists');
    await prefs.setString('harmony.listening_preference.v1', 'changed');

    final restored = await service.restoreBackup();

    expect(restored, isNotNull);
    final reopened = await database.database;
    expect((await reopened.query('track_preferences')).single['liked'], 1);
    expect(await reopened.query('playlists'), hasLength(1));
    expect((await reopened.query('playlist_tracks')).single['position'], 4);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'harmony.listening_preference.v1',
      ),
      'backup-value',
    );
    final artwork = (await reopened.query('artwork_assets')).single;
    final restoredPath = artwork['cache_path'] as String;
    expect(restoredPath, startsWith(supportDirectory.path));
    expect(File(restoredPath).existsSync(), isTrue);
  });

  test('校验失败时拒绝恢复且当前数据库不被覆盖', () async {
    final seeded = await _seed(database, temp);
    await service.exportBackup();
    await File('${packageDirectory.path}/library.db')
        .writeAsString('corrupted', flush: true);

    await expectLater(service.restoreBackup(), throwsA(isA<FormatException>()));

    final db = await database.database;
    expect(
      await db.query(
        'tracks',
        where: 'track_id = ?',
        whereArgs: [seeded.trackId],
      ),
      hasLength(1),
    );
  });

  test('设置损坏但校验值正确时也不得覆盖当前数据库或封面', () async {
    final seeded = await _seed(database, temp);
    await service.exportBackup();
    final db = await database.database;
    await db.update('tracks', {'title': '当前标题'});
    final cover = File('${temp.path}/manual.jpg');
    await cover.writeAsBytes([9, 8, 7]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('harmony.test', '当前设置');
    await File('${packageDirectory.path}/settings.json').writeAsString('[]');
    await _rehash(packageDirectory, 'settings.json');

    await expectLater(service.restoreBackup(), throwsA(isA<FormatException>()));

    expect((await db.query('tracks')).single['title'], '当前标题');
    expect((await db.query('tracks')).single['track_id'], seeded.trackId);
    expect(await cover.readAsBytes(), [9, 8, 7]);
    expect(prefs.getString('harmony.test'), '当前设置');
  });

  test('成功恢复使用独立资源目录，不覆盖同名现有封面', () async {
    final seeded = await _seed(database, temp);
    await service.exportBackup();
    final old = File(
      '${supportDirectory.path}/harmony_user_assets/${seeded.artworkId}.jpg',
    );
    await old.parent.create(recursive: true);
    await old.writeAsBytes([9, 8, 7]);
    await (await database.database).update('artwork_assets', {
      'cache_path': old.path,
    });

    await service.restoreBackup();

    final restored =
        (await (await database.database).query('artwork_assets'))
                .single['cache_path']
            as String;
    expect(restored, isNot(old.path));
    expect(await old.readAsBytes(), [9, 8, 7]);
    expect(await File(restored).readAsBytes(), [1, 2, 3, 4]);
  });

  test('数据库替换失败不改现有资源，清理本次暂存资源', () async {
    await _seed(database, temp);
    await service.exportBackup();
    await (await database.database).update('tracks', {'title': '当前标题'});
    await database.close();
    database = _FailingRestoreDatabase('${temp.path}/current.db');
    service = HarmonyBackupService(
      database: database,
      gateway: gateway,
      temporaryDirectory: () async => temp,
      supportDirectory: () async => supportDirectory,
    );

    await expectLater(service.restoreBackup(), throwsStateError);

    expect(
      (await (await database.database).query('tracks')).single['title'],
      '当前标题',
    );
    expect(await File('${temp.path}/manual.jpg').readAsBytes(), [1, 2, 3, 4]);
    expect(
      await Directory('${supportDirectory.path}/harmony_user_assets')
          .list()
          .toList(),
      isEmpty,
    );
  });

  test('人工歌词随备份恢复且保留偏移和选择状态', () async {
    final seeded = await _seed(database, temp);
    final original = File('${temp.path}/人工歌词.lrc');
    const text = '[00:01.000]第一句\n[00:02.000]第二句';
    await original.writeAsString(text);
    await (await database.database).insert('lyrics', {
      'lyrics_id': '00000000-0000-4000-8000-000000000205',
      'track_id': seeded.trackId,
      'source': 'manual',
      'match_method': 'manual',
      'document_uri': original.uri.toString(),
      'offset_ms': 125,
      'is_selected': 1,
      'created_at': 1,
    });
    await service.exportBackup();
    await original.delete();
    await service.restoreBackup();

    final lyric = (await (await database.database).query('lyrics')).single;
    expect(lyric['offset_ms'], 125);
    expect(lyric['is_selected'], 1);
    expect(
      await File.fromUri(Uri.parse(lyric['document_uri'] as String))
          .readAsString(),
      text,
    );
  });

  test('人工封面丢失时拒绝生成不完整备份', () async {
    await _seed(database, temp);
    await File('${temp.path}/manual.jpg').delete();
    await expectLater(service.exportBackup(), throwsStateError);
    expect(await service.lastSuccessfulBackupAt(), isNull);
    expect(await packageDirectory.exists(), isFalse);
  });

  for (final invalid in [
    'harmony-backup://assets/../../outside.jpg',
    'C:/outside.jpg',
  ]) {
    test('拒绝备份数据库内非法资源路径 $invalid', () async {
      await _seed(database, temp);
      await service.exportBackup();
      final copy = await databaseFactoryFfi.openDatabase(
        '${packageDirectory.path}/library.db',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await copy.update('artwork_assets', {'cache_path': invalid});
      await copy.close();
      await _rehash(packageDirectory, 'library.db');
      await expectLater(
        service.restoreBackup(),
        throwsA(isA<FormatException>()),
      );
      expect(await File('${temp.path}/manual.jpg').readAsBytes(), [1, 2, 3, 4]);
    });
  }

  test('拒绝清单未知数据表与伪造数据库版本', () async {
    await _seed(database, temp);
    await service.exportBackup();
    final manifestFile = File('${packageDirectory.path}/manifest.json');
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    final counts = manifest['rowCounts'] as Map<String, dynamic>;
    final removed = counts.remove('tracks');
    counts['tracks; DROP TABLE playlists'] = removed;
    await manifestFile.writeAsString(jsonEncode(manifest));
    await expectLater(service.restoreBackup(), throwsA(isA<FormatException>()));
    counts.remove('tracks; DROP TABLE playlists');
    counts['tracks'] = removed;
    manifest['databaseVersion'] = 5;
    await manifestFile.writeAsString(jsonEncode(manifest));
    await expectLater(service.restoreBackup(), throwsA(isA<FormatException>()));
    expect(await (await database.database).query('playlists'), hasLength(1));
  });

  test('并发恢复请求被拒绝，完成后可再次操作', () async {
    await _seed(database, temp);
    await service.exportBackup();
    final ready = Completer<void>();
    final release = Completer<void>();
    gateway.beforeImport = () async {
      ready.complete();
      await release.future;
    };
    final first = service.restoreBackup();
    await ready.future;
    await expectLater(service.restoreBackup(), throwsStateError);
    await expectLater(service.exportBackup(), throwsStateError);
    release.complete();
    expect(await first, isNotNull);
    gateway.beforeImport = null;
    expect(await service.exportBackup(), isNotNull);
  });

  test('备份提醒仅在有重要数据且超过周期时出现', () async {
    expect(await service.reminderDue(hasMeaningfulData: false), isFalse);
    expect(await service.reminderDue(hasMeaningfulData: true), isTrue);
    await service.snoozeReminder(DateTime(2026, 9, 1));
    expect(
      await service.reminderDue(
        hasMeaningfulData: true,
        now: DateTime(2026, 9, 2),
      ),
      isFalse,
    );
  });
}

Future<_SeededData> _seed(LibraryDatabase database, Directory temp) async {
  final db = await database.database;
  final now = DateTime.now().millisecondsSinceEpoch;
  const trackId = '00000000-0000-4000-8000-000000000201';
  const fileId = '00000000-0000-4000-8000-000000000202';
  const artworkId = '00000000-0000-4000-8000-000000000203';
  const playlistId = '00000000-0000-4000-8000-000000000204';
  await db.insert('tracks', {
    'track_id': trackId,
    'title': '七里香',
    'artist_display': '周杰伦',
    'added_at': now,
    'updated_at': now,
  });
  await db.insert('media_files', {
    'file_id': fileId,
    'track_id': trackId,
    'filename': '七里香.flac',
    'normalized_filename': '七里香.flac',
    'status': 'active',
    'created_at': now,
    'updated_at': now,
  });
  await db.update(
    'tracks',
    {'preferred_media_file_id': fileId},
    where: 'track_id = ?',
    whereArgs: [trackId],
  );
  await db.insert('track_preferences', {
    'track_id': trackId,
    'liked': 1,
    'updated_at': now,
  });
  await db.insert('playlists', {
    'playlist_id': playlistId,
    'name': '夜晚',
    'type': 'user',
    'created_at': now,
    'updated_at': now,
  });
  await db.insert('playlist_tracks', {
    'playlist_id': playlistId,
    'track_id': trackId,
    'position': 4,
    'added_at': now,
  });
  final artworkFile = File('${temp.path}/manual.jpg')
    ..writeAsBytesSync([1, 2, 3, 4]);
  await db.insert('artwork_assets', {
    'artwork_id': artworkId,
    'track_id': trackId,
    'file_id': fileId,
    'source': 'manual',
    'cache_path': artworkFile.path,
    'mime_type': 'image/jpeg',
    'created_at': now,
  });
  return const _SeededData(trackId: trackId, artworkId: artworkId);
}

class _SeededData {
  const _SeededData({required this.trackId, required this.artworkId});

  final String trackId;
  final String artworkId;
}

class _FakeBackupGateway implements BackupDocumentGateway {
  _FakeBackupGateway(this.packageDirectory);

  final Directory packageDirectory;
  Future<void> Function()? beforeImport;

  @override
  Future<String> appVersion() async => '0.3.0+4';

  @override
  Future<String?> exportDirectory({
    required String directoryPath,
    required String suggestedName,
  }) async {
    if (packageDirectory.existsSync()) {
      packageDirectory.deleteSync(recursive: true);
    }
    await _copyDirectory(Directory(directoryPath), packageDirectory);
    return packageDirectory.uri.toString();
  }

  @override
  Future<String?> importPackage({required String destinationDirectory}) async {
    await beforeImport?.call();
    await _copyDirectory(packageDirectory, Directory(destinationDirectory));
    return packageDirectory.uri.toString();
  }
}

class _FailingRestoreDatabase extends LibraryDatabase {
  _FailingRestoreDatabase(String path)
    : super(factory: databaseFactoryFfi, databasePath: path);

  @override
  Future<void> replaceWithBackup(String sourcePath) async =>
      throw StateError('模拟数据库替换失败');
}

Future<void> _rehash(Directory package, String relative) async {
  final file = File('${package.path}/manifest.json');
  final manifest =
      jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  (manifest['files'] as Map<String, dynamic>)[relative] = sha256
      .convert(await File('${package.path}/$relative').readAsBytes())
      .toString();
  await file.writeAsString(jsonEncode(manifest));
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(source.path.length + 1);
    final target = '${destination.path}/$relative';
    if (entity is Directory) {
      await Directory(target).create(recursive: true);
    } else if (entity is File) {
      await File(target).parent.create(recursive: true);
      await entity.copy(target);
    }
  }
}
