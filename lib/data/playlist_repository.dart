import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/v4/artwork.dart';
import '../models/v4/library_entities.dart';
import '../models/v4/library_track.dart';
import '../services/library_database.dart';

class PlaylistRepository {
  PlaylistRepository(
    this._database, {
    Uuid? uuid,
    Future<Directory> Function()? supportDirectory,
  }) : _uuid = uuid ?? const Uuid(),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final LibraryDatabase _database;
  final Uuid _uuid;
  final Future<Directory> Function() _supportDirectory;

  // Playlist UUID doubles as the ID of its optional manual artwork. No
  // schema migration is needed; existing manual-artwork backup handles it.
  Future<Map<String, ArtworkReference>> covers() async {
    final rows = await (await _database.database).rawQuery('''
SELECT a.* FROM artwork_assets a
JOIN playlists p ON p.playlist_id = a.artwork_id
WHERE a.source = 'manual' AND a.track_id IS NULL AND a.file_id IS NULL
''');
    return {
      for (final row in rows)
        row['artwork_id']! as String: ArtworkReference.fromAliasedMap(
          row,
          prefix: '',
        ),
    };
  }

  static const manualOnlyPlaylistId = '6d98f6f2-67a5-4da1-a31c-3baf562c7541';
  static const manualOnlyPlaylistName = '仅手动播放';

  Future<void> ensureManualOnlyPlaylist() async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _ensureManualOnlyPlaylist(transaction, now);

      final members = await transaction.query(
        'playlist_tracks',
        columns: ['track_id'],
        where: 'playlist_id = ?',
        whereArgs: [manualOnlyPlaylistId],
      );
      for (final member in members) {
        await transaction.update(
          'track_preferences',
          {
            'recommendation_excluded': 1,
            'exclusion_reason': 'manualOnlyPlaylist',
            'updated_at': now,
          },
          where: 'track_id = ?',
          whereArgs: [member['track_id']],
        );
      }

      final excluded = await transaction.query(
        'track_preferences',
        columns: ['track_id'],
        where: 'recommendation_excluded = 1',
      );
      var nextPosition =
          Sqflite.firstIntValue(
            await transaction.rawQuery(
              'SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_tracks '
              'WHERE playlist_id = ?',
              [manualOnlyPlaylistId],
            ),
          ) ??
          0;
      for (final preference in excluded) {
        final inserted = await transaction.insert('playlist_tracks', {
          'playlist_id': manualOnlyPlaylistId,
          'track_id': preference['track_id'],
          'position': nextPosition,
          'added_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        if (inserted != 0) nextPosition++;
      }
    });
  }

  Future<void> setManualOnly(String trackId, bool manualOnly) async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _ensureManualOnlyPlaylist(transaction, now);
      await transaction.insert('track_preferences', {
        'track_id': trackId,
        'liked': 0,
        'recommendation_excluded': manualOnly ? 1 : 0,
        'exclusion_reason': manualOnly ? 'manualOnlyPlaylist' : null,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await transaction.update(
        'track_preferences',
        {
          'recommendation_excluded': manualOnly ? 1 : 0,
          'exclusion_reason': manualOnly ? 'manualOnlyPlaylist' : null,
          'updated_at': now,
        },
        where: 'track_id = ?',
        whereArgs: [trackId],
      );
      if (manualOnly) {
        final nextPosition =
            Sqflite.firstIntValue(
              await transaction.rawQuery(
                'SELECT COALESCE(MAX(position), -1) + 1 '
                'FROM playlist_tracks WHERE playlist_id = ?',
                [manualOnlyPlaylistId],
              ),
            ) ??
            0;
        await transaction.insert('playlist_tracks', {
          'playlist_id': manualOnlyPlaylistId,
          'track_id': trackId,
          'position': nextPosition,
          'added_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      } else {
        await transaction.delete(
          'playlist_tracks',
          where: 'playlist_id = ? AND track_id = ?',
          whereArgs: [manualOnlyPlaylistId, trackId],
        );
        await _compactPositions(transaction, manualOnlyPlaylistId);
      }
      await _touch(transaction, manualOnlyPlaylistId, now);
    });
  }

  Future<void> _ensureManualOnlyPlaylist(
    DatabaseExecutor db,
    int timestamp,
  ) async {
    await db.insert('playlists', {
      'playlist_id': manualOnlyPlaylistId,
      'name': manualOnlyPlaylistName,
      'type': 'system',
      'created_at': timestamp,
      'updated_at': timestamp,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.update(
      'playlists',
      {'name': manualOnlyPlaylistName, 'type': 'system'},
      where: 'playlist_id = ?',
      whereArgs: [manualOnlyPlaylistId],
    );
  }

  Future<List<PlaylistLibrarySummary>> playlists() async {
    final rows = await (await _database.database).rawQuery('''
SELECT p.*, COUNT(pt.track_id) AS track_count
FROM playlists p
LEFT JOIN playlist_tracks pt ON pt.playlist_id = p.playlist_id
GROUP BY p.playlist_id
ORDER BY p.type, LOWER(p.name)
''');
    return rows
        .map(
          (row) => PlaylistLibrarySummary(
            playlist: Playlist.fromMap(row),
            trackCount: (row['track_count']! as num).toInt(),
          ),
        )
        .toList(growable: false);
  }

  Future<Playlist?> playlistById(String playlistId) async {
    final rows = await (await _database.database).query(
      'playlists',
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      limit: 1,
    );
    return rows.isEmpty ? null : Playlist.fromMap(rows.single);
  }

  Future<Playlist> create(String name, {String? coverPath}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(name, 'name');
    final db = await _database.database;
    final now = DateTime.now();
    final playlist = Playlist(
      playlistId: _uuid.v4(),
      name: trimmed,
      type: 'user',
      createdAt: now,
      updatedAt: now,
    );
    File? cover;
    try {
      if (coverPath != null) {
        final source = File(coverPath);
        if (await source.length() > 20 * 1024 * 1024) {
          throw ArgumentError('封面图片不能超过20MB');
        }
        final directory = Directory(
          p.join((await _supportDirectory()).path, 'harmony_user_assets'),
        );
        await directory.create(recursive: true);
        cover = await source.copy(
          p.join(
            directory.path,
            '${playlist.playlistId}${p.extension(source.path)}',
          ),
        );
      }
      await db.transaction((transaction) async {
        await transaction.insert('playlists', playlist.toMap());
        if (cover != null) {
          await transaction.insert('artwork_assets', {
            'artwork_id': playlist.playlistId,
            'source': 'manual',
            'cache_path': cover.path,
            'confidence': 1.0,
            'created_at': now.millisecondsSinceEpoch,
          });
        }
      });
    } catch (_) {
      if (cover != null && await cover.exists()) await cover.delete();
      rethrow;
    }
    return playlist;
  }

  Future<void> delete(String playlistId) async {
    if (playlistId == manualOnlyPlaylistId) {
      throw StateError('系统歌单不能删除');
    }
    final db = await _database.database;
    String? removedCoverPath;
    await db.transaction((transaction) async {
      final rows = await transaction.query(
        'playlists',
        columns: ['legacy_category_id'],
        where: 'playlist_id = ?',
        whereArgs: [playlistId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final covers = await transaction.query(
        'artwork_assets',
        where: "artwork_id = ? AND source = 'manual' AND track_id IS NULL AND file_id IS NULL",
        whereArgs: [playlistId],
      );
      if (covers.isNotEmpty) {
        removedCoverPath = covers.single['cache_path'] as String?;
        await transaction.delete(
          'artwork_assets',
          where: 'artwork_id = ?',
          whereArgs: [playlistId],
        );
      }
      final legacyCategoryId = rows.single['legacy_category_id'] as int?;
      await transaction.delete(
        'playlists',
        where: 'playlist_id = ?',
        whereArgs: [playlistId],
      );
      if (legacyCategoryId != null) {
        // A migrated V3 category is still a real user playlist. Removing its
        // V4 projection alone would make it reappear on the next sync.
        await transaction.delete(
          'category_songs',
          where: 'category_id = ?',
          whereArgs: [legacyCategoryId],
        );
        await transaction.delete(
          'categories',
          where: 'id = ?',
          whereArgs: [legacyCategoryId],
        );
      }
    });
    // Only remove the app-owned copy, never the user's selected source image.
    if (removedCoverPath != null) {
      final directory = p.join(
        (await _supportDirectory()).path,
        'harmony_user_assets',
      );
      if (p.isWithin(directory, removedCoverPath!)) {
        final file = File(removedCoverPath!);
        if (await file.exists()) await file.delete();
      }
    }
  }

  Future<void> rename(String playlistId, String name) async {
    if (playlistId == manualOnlyPlaylistId) {
      throw StateError('系统歌单不能重命名');
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(name, 'name');
    final updated = await (await _database.database).update(
      'playlists',
      {'name': trimmed, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
    );
    if (updated == 0) throw StateError('Playlist 不存在');
  }

  Future<void> setTrack(
    String playlistId,
    String trackId,
    bool included,
  ) async {
    if (!included) {
      await removeTracks(playlistId, [trackId]);
      return;
    }
    await addTracks(playlistId, [trackId]);
  }

  Future<Set<String>> playlistIdsForTrack(String trackId) async {
    final rows = await (await _database.database).query(
      'playlist_tracks',
      columns: ['playlist_id'],
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
    return rows.map((row) => row['playlist_id']! as String).toSet();
  }

  Future<void> addTracks(String playlistId, Iterable<String> trackIds) async {
    final uniqueTrackIds = trackIds.toSet().toList(growable: false);
    if (uniqueTrackIds.isEmpty) return;
    final db = await _database.database;
    await db.transaction((transaction) async {
      await _requirePlaylist(transaction, playlistId);
      var nextPosition =
          Sqflite.firstIntValue(
            await transaction.rawQuery(
              'SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_tracks '
              'WHERE playlist_id = ?',
              [playlistId],
            ),
          ) ??
          0;
      final now = DateTime.now().millisecondsSinceEpoch;
      var changed = false;
      for (final trackId in uniqueTrackIds) {
        final inserted = await transaction.insert('playlist_tracks', {
          'playlist_id': playlistId,
          'track_id': trackId,
          'position': nextPosition,
          'added_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        if (inserted != 0) {
          nextPosition++;
          changed = true;
        }
      }
      if (changed) await _touch(transaction, playlistId, now);
    });
  }

  Future<void> removeTracks(
    String playlistId,
    Iterable<String> trackIds,
  ) async {
    final uniqueTrackIds = trackIds.toSet().toList(growable: false);
    if (uniqueTrackIds.isEmpty) return;
    final db = await _database.database;
    await db.transaction((transaction) async {
      await _requirePlaylist(transaction, playlistId);
      final placeholders = List.filled(uniqueTrackIds.length, '?').join(',');
      final removed = await transaction.delete(
        'playlist_tracks',
        where: 'playlist_id = ? AND track_id IN ($placeholders)',
        whereArgs: [playlistId, ...uniqueTrackIds],
      );
      if (removed == 0) return;
      await _compactPositions(transaction, playlistId);
      await _touch(
        transaction,
        playlistId,
        DateTime.now().millisecondsSinceEpoch,
      );
    });
  }

  Future<void> reorder(String playlistId, List<String> trackIds) async {
    if (trackIds.length != trackIds.toSet().length) {
      throw ArgumentError('Playlist 顺序不能包含重复 Track');
    }
    final db = await _database.database;
    await db.transaction((transaction) async {
      await _requirePlaylist(transaction, playlistId);
      final existing = await transaction.query(
        'playlist_tracks',
        columns: ['track_id'],
        where: 'playlist_id = ?',
        whereArgs: [playlistId],
      );
      final existingIds = existing
          .map((row) => row['track_id']! as String)
          .toSet();
      if (existingIds.length != trackIds.length ||
          !existingIds.containsAll(trackIds)) {
        throw StateError('重排必须包含 Playlist 当前的全部 Track');
      }
      for (var position = 0; position < trackIds.length; position++) {
        await transaction.update(
          'playlist_tracks',
          {'position': position},
          where: 'playlist_id = ? AND track_id = ?',
          whereArgs: [playlistId, trackIds[position]],
        );
      }
      await _touch(
        transaction,
        playlistId,
        DateTime.now().millisecondsSinceEpoch,
      );
    });
  }

  Future<void> _requirePlaylist(DatabaseExecutor db, String playlistId) async {
    final rows = await db.query(
      'playlists',
      columns: ['playlist_id'],
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Playlist 不存在');
  }

  Future<void> _compactPositions(DatabaseExecutor db, String playlistId) async {
    final rows = await db.query(
      'playlist_tracks',
      columns: ['track_id'],
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'position, added_at, track_id',
    );
    for (var position = 0; position < rows.length; position++) {
      await db.update(
        'playlist_tracks',
        {'position': position},
        where: 'playlist_id = ? AND track_id = ?',
        whereArgs: [playlistId, rows[position]['track_id']],
      );
    }
  }

  Future<void> _touch(DatabaseExecutor db, String playlistId, int timestamp) =>
      db.update(
        'playlists',
        {'updated_at': timestamp},
        where: 'playlist_id = ?',
        whereArgs: [playlistId],
      );

  Future<Playlist?> playlistForLegacyCategory(int categoryId) async {
    final rows = await (await _database.database).query(
      'playlists',
      where: 'legacy_category_id = ?',
      whereArgs: [categoryId],
      limit: 1,
    );
    return rows.isEmpty ? null : Playlist.fromMap(rows.single);
  }

  Future<void> setLegacyCategoryTrack(
    int categoryId,
    String trackId,
    bool included,
  ) async {
    await synchronizeLegacyCategories();
    final playlist = await playlistForLegacyCategory(categoryId);
    if (playlist == null) return;
    await setTrack(playlist.playlistId, trackId, included);
  }

  Future<void> deleteLegacyCategoryPlaylist(int categoryId) async {
    await (await _database.database).delete(
      'playlists',
      where: 'legacy_category_id = ?',
      whereArgs: [categoryId],
    );
  }

  Future<void> synchronizeLegacyCategories() async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final categories = await transaction.query(
        'categories',
        columns: ['id', 'name'],
        orderBy: 'id',
      );
      for (final category in categories) {
        final categoryId = category['id']! as int;
        final existing = await transaction.query(
          'playlists',
          columns: ['playlist_id'],
          where: 'legacy_category_id = ?',
          whereArgs: [categoryId],
          limit: 1,
        );
        if (existing.isEmpty) {
          await transaction.insert('playlists', {
            'playlist_id': _uuid.v5(
              Namespace.url.value,
              'legacy-category:$categoryId',
            ),
            'name': category['name'],
            'type': 'user',
            'legacy_category_id': categoryId,
            'created_at': now,
            'updated_at': now,
          });
        }
      }

      final memberships = await transaction.rawQuery('''
SELECT cs.category_id, cs.song_id, lm.track_id
FROM category_songs cs
JOIN legacy_song_map lm ON lm.legacy_song_id = cs.song_id
WHERE lm.match_status = 'matched' AND lm.track_id IS NOT NULL
ORDER BY cs.category_id, cs.rowid
''');
      final positions = <int, int>{};
      for (final membership in memberships) {
        final categoryId = membership['category_id']! as int;
        final playlist = await transaction.query(
          'playlists',
          columns: ['playlist_id'],
          where: 'legacy_category_id = ?',
          whereArgs: [categoryId],
          limit: 1,
        );
        if (playlist.isEmpty) continue;
        await transaction.insert('playlist_tracks', {
          'playlist_id': playlist.single['playlist_id'],
          'track_id': membership['track_id'],
          'position': positions.update(
            categoryId,
            (value) => value + 1,
            ifAbsent: () => 0,
          ),
          'added_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }
}
