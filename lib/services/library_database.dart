// ignore_for_file: prefer_initializing_formals

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/database_backup.dart';
import '../data/v4_schema.dart';

class MusicCategory {
  const MusicCategory({
    required this.id,
    required this.name,
    required this.songCount,
  });

  final int id;
  final String name;
  final int songCount;
}

class MetadataCache {
  const MetadataCache({
    required this.title,
    required this.artist,
    required this.album,
    required this.artwork,
    required this.matched,
  });

  final String title;
  final String artist;
  final String album;
  final Uint8List? artwork;
  final bool matched;
}

class SongOverride {
  const SongOverride({
    required this.title,
    required this.artist,
    required this.album,
  });

  final String title;
  final String artist;
  final String album;
}

class LibraryDatabase {
  LibraryDatabase({
    DatabaseFactory? factory,
    String? databasePath,
    Directory? backupDirectory,
    SchemaFaultInjector schemaFaultInjector,
    Uuid? uuid,
  }) : _factory = factory ?? databaseFactory,
       _databasePath = databasePath,
       _backupDirectory = backupDirectory,
       _schemaFaultInjector = schemaFaultInjector,
       _uuid = uuid ?? const Uuid();

  final DatabaseFactory _factory;
  final String? _databasePath;
  final Directory? _backupDirectory;
  final SchemaFaultInjector _schemaFaultInjector;
  final Uuid _uuid;
  Database? _database;
  DatabaseBackupResult? lastUpgradeBackup;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final path =
        _databasePath ??
        p.join(await _factory.getDatabasesPath(), 'my_music_library.db');
    final existingVersion = await _existingVersion(path);
    if (existingVersion == 3) {
      final backupDirectory =
          _backupDirectory ?? Directory(p.join(p.dirname(path), 'v3_backups'));
      lastUpgradeBackup = await DatabaseBackupService(
        factory: _factory,
        backupDirectory: backupDirectory,
      ).backupV3(path);
    }
    _database = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: V4Schema.version,
        onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          await V4Schema.createLegacyTables(db);
          await V4Schema.createV4Tables(
            db,
            faultInjector: _schemaFaultInjector,
          );
          final now = DateTime.now().millisecondsSinceEpoch;
          await db.insert('migration_state', {
            'migration_id': 1,
            'source_version': V4Schema.version,
            'target_version': V4Schema.version,
            'status': 'ready',
            'started_at': now,
            'completed_at': now,
          });
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) await _createMetadataCache(db);
          if (oldVersion < 3) await _createSongOverrides(db);
          if (oldVersion < 4) await _upgradeToV4(db, oldVersion);
          if (oldVersion >= 4 && oldVersion < 5) {
            await V4Schema.createFileIdentityTables(db);
          }
          if (oldVersion >= 4 && oldVersion < 6) {
            await V4Schema.createArtistProfilesTable(db);
          }
        },
        onOpen: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    return _database!;
  }

  Future<int?> _existingVersion(String path) async {
    if (!await File(path).exists()) return null;
    Database? db;
    try {
      db = await _factory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      return await db.getVersion();
    } finally {
      await db?.close();
    }
  }

  Future<void> _upgradeToV4(Database db, int oldVersion) async {
    await V4Schema.createV4Tables(db, faultInjector: _schemaFaultInjector);
    final now = DateTime.now().millisecondsSinceEpoch;
    final legacyIds = await db.rawQuery(
      'SELECT song_id FROM favorites '
      'UNION SELECT song_id FROM category_songs '
      'UNION SELECT song_id FROM metadata_cache '
      'UNION SELECT song_id FROM song_overrides',
    );
    for (final row in legacyIds) {
      await db.insert('legacy_song_map', {
        'legacy_song_id': row['song_id'],
        'match_status': 'awaiting_scan',
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    final categories = await db.query('categories', columns: ['id', 'name']);
    for (final category in categories) {
      await db.insert('playlists', {
        'playlist_id': _uuid.v4(),
        'name': category['name'],
        'type': 'user',
        'legacy_category_id': category['id'],
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    final awaitingScan = legacyIds.isNotEmpty;
    await db.insert('migration_state', {
      'migration_id': 1,
      'source_version': oldVersion,
      'target_version': V4Schema.version,
      'status': awaitingScan ? 'awaiting_scan' : 'completed',
      'backup_manifest_path': lastUpgradeBackup?.manifestPath,
      'started_at': now,
      'completed_at': awaitingScan ? null : now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _createMetadataCache(Database db) => db.execute(
    'CREATE TABLE IF NOT EXISTS metadata_cache('
    'song_id INTEGER PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL, '
    'album TEXT NOT NULL, artwork BLOB, matched INTEGER NOT NULL, checked_at INTEGER NOT NULL)',
  );

  static Future<void> _createSongOverrides(Database db) => db.execute(
    'CREATE TABLE IF NOT EXISTS song_overrides('
    'song_id INTEGER PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL, album TEXT NOT NULL)',
  );

  Future<void> close() async {
    final db = _database;
    _database = null;
    await db?.close();
  }

  Future<String> get resolvedPath async =>
      _databasePath ??
      p.join(await _factory.getDatabasesPath(), 'my_music_library.db');

  DatabaseFactory get factory => _factory;

  Future<void> createConsistentSnapshot(String targetPath) async {
    final target = File(targetPath);
    if (await target.exists()) await target.delete();
    final escapedPath = targetPath.replaceAll("'", "''");
    await (await database).execute("VACUUM INTO '$escapedPath'");
    final snapshot = await _factory.openDatabase(
      targetPath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final rows = await snapshot.rawQuery('PRAGMA integrity_check');
      if (rows.length != 1 ||
          '${rows.single.values.first}'.toLowerCase() != 'ok') {
        throw StateError('数据库快照完整性检查失败');
      }
    } finally {
      await snapshot.close();
    }
  }

  Future<void> replaceWithBackup(String sourcePath) async {
    final targetPath = await resolvedPath;
    final target = File(targetPath);
    final staged = File('$targetPath.restore-new');
    final previous = File('$targetPath.restore-old');
    await close();
    for (final file in [staged, previous]) {
      if (await file.exists()) await file.delete();
    }
    await File(sourcePath).copy(staged.path);
    try {
      if (await target.exists()) await target.rename(previous.path);
      await staged.rename(target.path);
      for (final suffix in ['-wal', '-shm']) {
        final sidecar = File('$targetPath$suffix');
        if (await sidecar.exists()) await sidecar.delete();
      }
      await database;
      if (await previous.exists()) await previous.delete();
    } catch (_) {
      await close();
      if (await target.exists()) await target.delete();
      if (await previous.exists()) await previous.rename(target.path);
      await database;
      rethrow;
    } finally {
      if (await staged.exists()) await staged.delete();
    }
  }

  Future<Map<int, SongOverride>> songOverrides() async {
    final rows = await (await database).query('song_overrides');
    return {
      for (final row in rows)
        row['song_id']! as int: SongOverride(
          title: row['title']! as String,
          artist: row['artist']! as String,
          album: row['album']! as String,
        ),
    };
  }

  Future<void> saveSongOverride(
    int songId, {
    required String title,
    required String artist,
    required String album,
  }) async {
    await (await database).insert('song_overrides', {
      'song_id': songId,
      'title': title,
      'artist': artist,
      'album': album,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<MetadataCache?> metadataFor(int songId) async {
    final rows = await (await database).query(
      'metadata_cache',
      where: 'song_id = ?',
      whereArgs: [songId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return MetadataCache(
      title: row['title']! as String,
      artist: row['artist']! as String,
      album: row['album']! as String,
      artwork: row['artwork'] as Uint8List?,
      matched: (row['matched']! as int) == 1,
    );
  }

  Future<void> saveMetadata(
    int songId, {
    required String title,
    required String artist,
    required String album,
    required Uint8List? artwork,
    required bool matched,
  }) async {
    await (await database).insert('metadata_cache', {
      'song_id': songId,
      'title': title,
      'artist': artist,
      'album': album,
      'artwork': artwork,
      'matched': matched ? 1 : 0,
      'checked_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Set<int>> favoriteIds() async {
    final rows = await (await database).query('favorites');
    return rows.map((row) => row['song_id']! as int).toSet();
  }

  Future<void> setFavorite(int songId, bool favorite) async {
    final db = await database;
    if (favorite) {
      await db.insert('favorites', {
        'song_id': songId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    } else {
      await db.delete('favorites', where: 'song_id = ?', whereArgs: [songId]);
    }
  }

  Future<List<MusicCategory>> categories() async {
    final rows = await (await database).rawQuery(
      'SELECT c.id, c.name, COUNT(cs.song_id) AS song_count FROM categories c '
      'LEFT JOIN category_songs cs ON cs.category_id = c.id GROUP BY c.id ORDER BY c.name',
    );
    return rows
        .map(
          (row) => MusicCategory(
            id: row['id']! as int,
            name: row['name']! as String,
            songCount: (row['song_count']! as num).toInt(),
          ),
        )
        .toList();
  }

  Future<void> createCategory(String name) async {
    await (await database).insert('categories', {'name': name.trim()});
  }

  Future<Set<int>> categorySongIds(int categoryId) async {
    final rows = await (await database).query(
      'category_songs',
      columns: ['song_id'],
      where: 'category_id = ?',
      whereArgs: [categoryId],
    );
    return rows.map((row) => row['song_id']! as int).toSet();
  }

  Future<void> setSongInCategory(
    int categoryId,
    int songId,
    bool included,
  ) async {
    final db = await database;
    if (included) {
      await db.insert('category_songs', {
        'category_id': categoryId,
        'song_id': songId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    } else {
      await db.delete(
        'category_songs',
        where: 'category_id = ? AND song_id = ?',
        whereArgs: [categoryId, songId],
      );
    }
  }

  Future<void> deleteCategory(int categoryId) async {
    final db = await database;
    await db.transaction((transaction) async {
      await transaction.delete(
        'category_songs',
        where: 'category_id = ?',
        whereArgs: [categoryId],
      );
      await transaction.delete(
        'categories',
        where: 'id = ?',
        whereArgs: [categoryId],
      );
    });
  }

  Future<void> removeSongReferences(List<int> songIds) async {
    if (songIds.isEmpty) return;
    final placeholders = List.filled(songIds.length, '?').join(',');
    final db = await database;
    await db.transaction((transaction) async {
      for (final table in [
        'favorites',
        'category_songs',
        'metadata_cache',
        'song_overrides',
      ]) {
        await transaction.delete(
          table,
          where: 'song_id IN ($placeholders)',
          whereArgs: songIds,
        );
      }
    });
  }
}
