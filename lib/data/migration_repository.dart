import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../services/library_database.dart';

class MigrationStatus {
  const MigrationStatus({
    required this.sourceVersion,
    required this.targetVersion,
    required this.status,
    required this.retryCount,
    this.backupManifestPath,
    this.lastError,
  });

  final int sourceVersion;
  final int targetVersion;
  final String status;
  final int retryCount;
  final String? backupManifestPath;
  final String? lastError;
}

class MigrationRepository {
  MigrationRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final LibraryDatabase _database;
  final Uuid _uuid;

  Future<MigrationStatus> status() async {
    final rows = await (await _database.database).query(
      'migration_state',
      where: 'migration_id = 1',
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Migration state is missing');
    final row = rows.single;
    return MigrationStatus(
      sourceVersion: row['source_version']! as int,
      targetVersion: row['target_version']! as int,
      status: row['status']! as String,
      retryCount: row['retry_count']! as int,
      backupManifestPath: row['backup_manifest_path'] as String?,
      lastError: row['last_error'] as String?,
    );
  }

  Future<List<int>> awaitingLegacySongIds() async {
    final rows = await (await _database.database).query(
      'legacy_song_map',
      columns: ['legacy_song_id'],
      where: 'match_status = ?',
      whereArgs: ['awaiting_scan'],
      orderBy: 'legacy_song_id',
    );
    return rows
        .map((row) => row['legacy_song_id']! as int)
        .toList(growable: false);
  }

  Future<void> linkLegacySong({
    required int legacySongId,
    required String trackId,
    required String fileId,
  }) async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final mapUpdated = await transaction.update(
        'legacy_song_map',
        {
          'track_id': trackId,
          'file_id': fileId,
          'match_status': 'matched',
          'matched_at': now,
        },
        where: 'legacy_song_id = ? AND match_status != ?',
        whereArgs: [legacySongId, 'matched'],
      );
      if (mapUpdated == 0) return;

      final favorite = await transaction.query(
        'favorites',
        where: 'song_id = ?',
        whereArgs: [legacySongId],
        limit: 1,
      );
      if (favorite.isNotEmpty) {
        await transaction.insert('track_preferences', {
          'track_id': trackId,
          'liked': 1,
          'liked_at': now,
          'recommendation_excluded': 0,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }

      final override = await transaction.query(
        'song_overrides',
        where: 'song_id = ?',
        whereArgs: [legacySongId],
        limit: 1,
      );
      if (override.isNotEmpty) {
        await transaction.insert('track_overrides', {
          'track_id': trackId,
          'title': override.single['title'],
          'artist': override.single['artist'],
          'album': override.single['album'],
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }

      final categories = await transaction.query(
        'category_songs',
        columns: ['category_id'],
        where: 'song_id = ?',
        whereArgs: [legacySongId],
      );
      for (final category in categories) {
        final playlists = await transaction.query(
          'playlists',
          columns: ['playlist_id'],
          where: 'legacy_category_id = ?',
          whereArgs: [category['category_id']],
          limit: 1,
        );
        if (playlists.isEmpty) continue;
        await transaction.insert('playlist_tracks', {
          'playlist_id': playlists.single['playlist_id'],
          'track_id': trackId,
          'position': 0,
          'added_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await _completeIfFinished(transaction, now);
    });
  }

  Future<void> markOrphan(int legacySongId, String reason) async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final legacyData = await _legacyData(transaction, legacySongId);
      await transaction.insert('migration_orphans', {
        'orphan_id': _uuid.v4(),
        'legacy_song_id': legacySongId,
        'reason': reason,
        'legacy_data_json': jsonEncode(legacyData),
        'status': 'pending',
        'created_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await transaction.update(
        'legacy_song_map',
        {'match_status': 'orphaned'},
        where: 'legacy_song_id = ?',
        whereArgs: [legacySongId],
      );
      await _completeIfFinished(transaction, now);
    });
  }

  Future<Map<String, Object?>> _legacyData(
    DatabaseExecutor db,
    int songId,
  ) async => {
    'songId': songId,
    'favorite': (await db.query(
      'favorites',
      where: 'song_id = ?',
      whereArgs: [songId],
    )).isNotEmpty,
    'categories': await db.query(
      'category_songs',
      where: 'song_id = ?',
      whereArgs: [songId],
    ),
    'override': await db.query(
      'song_overrides',
      where: 'song_id = ?',
      whereArgs: [songId],
    ),
    'metadata': await db.query(
      'metadata_cache',
      where: 'song_id = ?',
      whereArgs: [songId],
    ),
  };

  Future<void> _completeIfFinished(DatabaseExecutor db, int now) async {
    final rows = await db.rawQuery(
      "SELECT COUNT(*) AS count FROM legacy_song_map WHERE match_status = 'awaiting_scan'",
    );
    if ((rows.single['count']! as num).toInt() == 0) {
      await db.update('migration_state', {
        'status': 'completed',
        'completed_at': now,
        'last_error': null,
      }, where: 'migration_id = 1');
    }
  }
}
