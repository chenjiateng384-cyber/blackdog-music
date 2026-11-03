import 'package:sqflite/sqflite.dart';

import '../models/v4/artwork.dart';
import '../models/v4/library_browsing.dart';
import '../models/v4/library_entities.dart';
import '../models/v4/library_search.dart';
import '../models/v4/library_track.dart';
import '../models/v4/listening_data.dart';
import '../models/v4/media_file.dart';
import '../models/v4/metadata_layers.dart';
import '../models/v4/track.dart';
import '../services/library_database.dart';

class LibraryRepository {
  const LibraryRepository(this._database);

  final LibraryDatabase _database;

  Future<void> createTrack(Track track) async {
    await (await _database.database).insert('tracks', track.toMap());
  }

  Future<Track?> trackById(String trackId) async {
    final rows = await (await _database.database).query(
      'tracks',
      where: 'track_id = ?',
      whereArgs: [trackId],
      limit: 1,
    );
    return rows.isEmpty ? null : Track.fromMap(rows.first);
  }

  Future<LibraryTrack?> libraryTrackById(String trackId) async {
    final rows = await _queryLibraryTracks(
      where: 't.track_id = ? AND t.deleted_at IS NULL',
      whereArgs: [trackId],
      limit: 1,
      includeUnavailable: true,
    );
    return rows.isEmpty ? null : rows.single;
  }

  Future<List<LibraryTrack>> allTracks({
    LibraryTrackSort sort = LibraryTrackSort.title,
    int? limit,
    int offset = 0,
    bool includeUnavailable = false,
  }) => _queryLibraryTracks(
    where: 't.deleted_at IS NULL',
    orderBy: _trackOrder(sort),
    limit: limit,
    offset: offset,
    includeUnavailable: includeUnavailable,
  );

  Future<List<LibraryTrack>> tracksByIds(List<String> trackIds) async {
    if (trackIds.isEmpty) return const [];
    final placeholders = List.filled(trackIds.length, '?').join(',');
    final rows = await _queryLibraryTracks(
      where: 't.deleted_at IS NULL AND t.track_id IN ($placeholders)',
      whereArgs: trackIds,
    );
    final byId = {for (final item in rows) item.track.trackId: item};
    return trackIds
        .map((id) => byId[id])
        .whereType<LibraryTrack>()
        .toList(growable: false);
  }

  Future<List<LibraryTrack>> tracksForArtist(
    String artistId, {
    int? limit,
    int offset = 0,
  }) => tracksForArtists([artistId], limit: limit, offset: offset);

  Future<List<LibraryTrack>> tracksForArtists(
    List<String> artistIds, {
    int? limit,
    int offset = 0,
  }) {
    if (artistIds.isEmpty) return Future.value(const []);
    final placeholders = List.filled(artistIds.length, '?').join(',');
    return _queryLibraryTracks(
      joins: 'JOIN track_artists filter_ta ON filter_ta.track_id = t.track_id',
      where:
          't.deleted_at IS NULL AND filter_ta.artist_id IN ($placeholders) '
          "AND filter_ta.role = 'primary'",
      whereArgs: artistIds,
      orderBy:
          'LOWER(t.album_display), COALESCE(t.disc_number, 1), '
          'COALESCE(t.track_number, 9999), LOWER(t.title)',
      limit: limit,
      offset: offset,
    );
  }

  Future<List<LibraryTrack>> tracksForAlbum(
    String albumId, {
    int? limit,
    int offset = 0,
  }) => _queryLibraryTracks(
    where: 't.deleted_at IS NULL AND t.album_id = ?',
    whereArgs: [albumId],
    orderBy:
        'COALESCE(t.disc_number, 1), COALESCE(t.track_number, 9999), '
        'LOWER(t.title)',
    limit: limit,
    offset: offset,
  );

  Future<List<LibraryTrack>> tracksForPlaylist(
    String playlistId, {
    int? limit,
    int offset = 0,
  }) => _queryLibraryTracks(
    joins: 'JOIN playlist_tracks filter_pt ON filter_pt.track_id = t.track_id',
    where: 't.deleted_at IS NULL AND filter_pt.playlist_id = ?',
    whereArgs: [playlistId],
    orderBy: 'filter_pt.position, filter_pt.added_at, LOWER(t.title)',
    limit: limit,
    offset: offset,
  );

  Future<List<LibraryTrack>> tracksForFolder(
    String scanRootId,
    String relativePath, {
    bool recursive = true,
    int? limit,
    int offset = 0,
  }) {
    final normalized = _normalizeFolderPath(relativePath);
    if (normalized.isEmpty) {
      return _queryLibraryTracks(
        joins: '''JOIN (SELECT DISTINCT folder_mf.track_id
                      FROM media_files folder_mf
                      WHERE folder_mf.scan_root_id = ?
                        AND folder_mf.status IN ('active','duplicate')
                        AND INSTR(folder_mf.relative_path, '/') = 0
                        AND INSTR(folder_mf.relative_path, CHAR(92)) = 0)
                     folder_filter ON folder_filter.track_id = t.track_id''',
        where: 't.deleted_at IS NULL',
        whereArgs: [scanRootId],
        orderBy: 'LOWER(t.title)',
        limit: limit,
        offset: offset,
      );
    }
    final escaped = _escapeLike(normalized);
    final pathFilter = recursive
        ? "folder_mf.relative_path LIKE ? ESCAPE '\\'"
        : "folder_mf.relative_path LIKE ? ESCAPE '\\' "
              "AND INSTR(SUBSTR(folder_mf.relative_path, LENGTH(?) + 2), '/') = 0";
    return _queryLibraryTracks(
      joins:
          '''JOIN (SELECT DISTINCT folder_mf.track_id
                    FROM media_files folder_mf
                    WHERE folder_mf.scan_root_id = ?
                      AND folder_mf.status IN ('active','duplicate')
                      AND $pathFilter) folder_filter
                   ON folder_filter.track_id = t.track_id''',
      where: 't.deleted_at IS NULL',
      whereArgs: [scanRootId, '$escaped/%', if (!recursive) normalized],
      orderBy:
          'LOWER(t.album_display), COALESCE(t.disc_number, 1), '
          'COALESCE(t.track_number, 9999), LOWER(t.title)',
      limit: limit,
      offset: offset,
    );
  }

  Future<List<LibraryFolder>> folders({
    String? scanRootId,
    String? parentPath,
    bool recursive = false,
  }) async {
    final where = <String>[
      "status IN ('active','duplicate')",
      'relative_path IS NOT NULL',
    ];
    final arguments = <Object?>[];
    if (scanRootId != null) {
      where.add('scan_root_id = ?');
      arguments.add(scanRootId);
    }
    final rows = await (await _database.database).query(
      'media_files',
      columns: ['scan_root_id', 'relative_path', 'track_id'],
      where: where.join(' AND '),
      whereArgs: arguments,
      orderBy: 'scan_root_id, relative_path',
    );
    final builders = <String, _FolderBuilder>{};
    for (final row in rows) {
      final rootId = row['scan_root_id'] as String?;
      final relative = (row['relative_path'] as String?)?.replaceAll('\\', '/');
      final trackId = row['track_id'] as String?;
      if (rootId == null || relative == null || trackId == null) continue;
      final parts = relative
          .split('/')
          .where((part) => part.isNotEmpty)
          .toList();
      if (parts.length == 1) {
        final builder = builders.putIfAbsent(
          '$rootId\u0000',
          () => _FolderBuilder(
            scanRootId: rootId,
            relativePath: '',
            name: '根目录歌曲',
            parentPath: null,
            depth: 0,
          ),
        );
        builder.directTrackIds.add(trackId);
        builder.descendantTrackIds.add(trackId);
        continue;
      }
      if (parts.isEmpty) continue;
      final folderParts = parts.sublist(0, parts.length - 1);
      for (var depth = 0; depth < folderParts.length; depth++) {
        final path = folderParts.sublist(0, depth + 1).join('/');
        final key = '$rootId\u0000$path';
        final builder = builders.putIfAbsent(
          key,
          () => _FolderBuilder(
            scanRootId: rootId,
            relativePath: path,
            name: folderParts[depth],
            parentPath: depth == 0
                ? null
                : folderParts.sublist(0, depth).join('/'),
            depth: depth + 1,
          ),
        );
        builder.descendantTrackIds.add(trackId);
        if (depth == folderParts.length - 1) {
          builder.directTrackIds.add(trackId);
        }
      }
    }
    final normalizedParent = parentPath == null
        ? null
        : _normalizeFolderPath(parentPath);
    final result =
        builders.values
            .where((folder) {
              if (scanRootId != null && folder.scanRootId != scanRootId) {
                return false;
              }
              if (recursive) {
                return normalizedParent == null ||
                    folder.relativePath == normalizedParent ||
                    folder.relativePath.startsWith('$normalizedParent/');
              }
              return folder.parentPath == normalizedParent;
            })
            .map((folder) => folder.build())
            .toList(growable: true)
          ..sort((left, right) {
            final byRoot = left.scanRootId.compareTo(right.scanRootId);
            if (byRoot != 0) return byRoot;
            return left.relativePath.toLowerCase().compareTo(
              right.relativePath.toLowerCase(),
            );
          });
    return List.unmodifiable(result);
  }

  Future<List<LibraryTrack>> recentlyAddedTracks({int limit = 8}) =>
      _queryLibraryTracks(
        where: 't.deleted_at IS NULL',
        orderBy: 't.added_at DESC, LOWER(t.title)',
        limit: limit,
      );

  Future<List<LibraryTrack>> likedTracks({int? limit, int offset = 0}) =>
      _queryLibraryTracks(
        where: 't.deleted_at IS NULL AND pref.liked = 1',
        orderBy: 'pref.liked_at DESC, LOWER(t.title)',
        limit: limit,
        offset: offset,
      );

  Future<List<LibraryTrack>> recentlyPlayedTracks({int limit = 20}) =>
      _queryLibraryTracks(
        where: 't.deleted_at IS NULL AND stats.last_played_at IS NOT NULL',
        orderBy: 'stats.last_played_at DESC, LOWER(t.title)',
        limit: limit,
      );

  Future<List<LibraryTrack>> mostPlayedTracks({
    int limit = 50,
    int offset = 0,
  }) => _queryLibraryTracks(
    where: 't.deleted_at IS NULL AND stats.play_count > 0',
    orderBy:
        'stats.play_count DESC, stats.total_play_duration_ms DESC, '
        'LOWER(t.title)',
    limit: limit,
    offset: offset,
  );

  Future<List<ArtistLibrarySummary>> artists({
    int? limit,
    int offset = 0,
    bool includeMinor = false,
  }) async {
    final db = await _database.database;
    final sql = StringBuffer('''
SELECT a.artist_id, a.display_name, a.normalized_name,
       COUNT(DISTINCT t.track_id) AS track_count,
       COUNT(DISTINCT t.album_id) AS album_count,
       COALESCE(SUM(artist_stats.play_count), 0) AS play_count,
       CASE WHEN ap.artist_id IS NULL THEN 0 ELSE 1 END AS is_curated_folder,
       $_artistArtworkColumns
FROM artists a
JOIN track_artists ta ON ta.artist_id = a.artist_id AND ta.role = 'primary'
JOIN tracks t ON t.track_id = ta.track_id AND t.deleted_at IS NULL
LEFT JOIN track_stats artist_stats ON artist_stats.track_id = t.track_id
LEFT JOIN artist_profiles ap ON ap.artist_id = a.artist_id
WHERE $_availableTrack
GROUP BY a.artist_id, a.display_name, a.normalized_name, ap.artist_id
ORDER BY a.normalized_name''');
    final rows = await db.rawQuery(sql.toString());
    final raw = rows.map(artistSummaryFromRow).toList(growable: false);
    final groups = <String, _PrimaryArtistGroup>{};
    for (final summary in raw) {
      final primaryName = primaryArtistName(summary.artist.displayName);
      if (_isUnknownArtistName(primaryName)) continue;
      final key = primaryName.toLowerCase().trim();
      groups
          .putIfAbsent(key, () => _PrimaryArtistGroup(primaryName))
          .add(summary);
    }

    final allAlbums = await albums();
    for (final album in allAlbums.where((item) => item.isBrowsableCollection)) {
      final artistId = album.album.albumArtistId;
      if (artistId == null) continue;
      for (final group in groups.values) {
        if (group.sourceArtistIds.contains(artistId)) {
          group.collectionAlbumIds.add(album.album.albumId);
          break;
        }
      }
    }
    final visible =
        groups.values
            .where((group) => includeMinor || group.isMainLibraryArtist)
            .map((group) => group.build())
            .toList(growable: true)
          ..sort(
            (left, right) => left.artist.normalizedName.compareTo(
              right.artist.normalizedName,
            ),
          );
    final start = offset.clamp(0, visible.length);
    final end = limit == null
        ? visible.length
        : (start + limit).clamp(start, visible.length);
    return List.unmodifiable(visible.sublist(start, end));
  }

  Future<List<ArtistLibrarySummary>> artistsByIds(
    List<String> artistIds,
  ) async {
    if (artistIds.isEmpty) return const [];
    final placeholders = List.filled(artistIds.length, '?').join(',');
    final rows = await (await _database.database).rawQuery('''
SELECT a.artist_id, a.display_name, a.normalized_name,
       COUNT(DISTINCT t.track_id) AS track_count,
       COUNT(DISTINCT t.album_id) AS album_count,
       CASE WHEN ap.artist_id IS NULL THEN 0 ELSE 1 END AS is_curated_folder,
       $_artistArtworkColumns
FROM artists a
JOIN track_artists ta ON ta.artist_id = a.artist_id AND ta.role = 'primary'
JOIN tracks t ON t.track_id = ta.track_id AND t.deleted_at IS NULL
LEFT JOIN artist_profiles ap ON ap.artist_id = a.artist_id
WHERE a.artist_id IN ($placeholders) AND $_availableTrack
GROUP BY a.artist_id, a.display_name, a.normalized_name, ap.artist_id
''', artistIds);
    final byId = {
      for (final row in rows)
        row['artist_id']! as String: artistSummaryFromRow(row),
    };
    return artistIds
        .map((id) => byId[id])
        .whereType<ArtistLibrarySummary>()
        .toList(growable: false);
  }

  Future<List<AlbumLibrarySummary>> albums({
    String? artistId,
    List<String>? artistIds,
    int? limit,
    int offset = 0,
  }) async {
    final db = await _database.database;
    final where = <String>['t.deleted_at IS NULL', _availableTrack];
    final arguments = <Object?>[];
    final filterArtistIds = artistIds ?? (artistId == null ? null : [artistId]);
    if (filterArtistIds != null && filterArtistIds.isNotEmpty) {
      final placeholders = List.filled(filterArtistIds.length, '?').join(',');
      where.add('''EXISTS(
        SELECT 1 FROM track_artists album_ta
        WHERE album_ta.track_id = t.track_id
          AND album_ta.artist_id IN ($placeholders)
          AND album_ta.role = 'primary'
      )''');
      arguments.addAll(filterArtistIds);
    }
    final sql = StringBuffer('''
SELECT a.album_id, a.title, a.normalized_title, a.album_artist_id,
       a.year, a.album_type, COUNT(DISTINCT t.track_id) AS track_count,
       MAX(CASE WHEN t.track_number IS NOT NULL THEN 1 ELSE 0 END)
         AS has_explicit_track_number,
       CASE WHEN COUNT(DISTINCT t.track_id) = 1 AND
         MAX(CASE WHEN LOWER(TRIM(t.title)) = LOWER(TRIM(a.title))
             THEN 1 ELSE 0 END) = 1 THEN 1 ELSE 0 END
         AS only_track_title_matches_album,
       $_artworkColumns
FROM albums a
JOIN tracks t ON t.album_id = a.album_id
$_albumArtworkJoin
WHERE ${where.join(' AND ')}
GROUP BY a.album_id, a.title, a.normalized_title, a.album_artist_id,
         a.year, a.album_type, art.artwork_id
ORDER BY COALESCE(a.year, 9999), a.normalized_title''');
    _appendLimit(sql, arguments, limit, offset);
    final rows = await db.rawQuery(sql.toString(), arguments);
    return rows.map(albumSummaryFromRow).toList(growable: false);
  }

  Future<List<AlbumLibrarySummary>> albumsByIds(List<String> albumIds) async {
    if (albumIds.isEmpty) return const [];
    final placeholders = List.filled(albumIds.length, '?').join(',');
    final rows = await (await _database.database).rawQuery('''
SELECT a.album_id, a.title, a.normalized_title, a.album_artist_id,
       a.year, a.album_type, COUNT(DISTINCT t.track_id) AS track_count,
       MAX(CASE WHEN t.track_number IS NOT NULL THEN 1 ELSE 0 END)
         AS has_explicit_track_number,
       CASE WHEN COUNT(DISTINCT t.track_id) = 1 AND
         MAX(CASE WHEN LOWER(TRIM(t.title)) = LOWER(TRIM(a.title))
             THEN 1 ELSE 0 END) = 1 THEN 1 ELSE 0 END
         AS only_track_title_matches_album,
       $_artworkColumns
FROM albums a
JOIN tracks t ON t.album_id = a.album_id AND t.deleted_at IS NULL
$_albumArtworkJoin
WHERE a.album_id IN ($placeholders) AND $_availableTrack
GROUP BY a.album_id, a.title, a.normalized_title, a.album_artist_id,
         a.year, a.album_type, art.artwork_id
''', albumIds);
    final byId = {
      for (final row in rows)
        row['album_id']! as String: albumSummaryFromRow(row),
    };
    return albumIds
        .map((id) => byId[id])
        .whereType<AlbumLibrarySummary>()
        .toList(growable: false);
  }

  Future<LibraryCounts> counts() async {
    final db = await _database.database;
    final row = (await db.rawQuery('''
SELECT
  (SELECT COUNT(*) FROM tracks t
   WHERE t.deleted_at IS NULL AND $_availableTrack) AS track_count,
  (SELECT COUNT(DISTINCT ta.artist_id)
   FROM track_artists ta JOIN tracks t ON t.track_id = ta.track_id
   WHERE t.deleted_at IS NULL AND ta.role = 'primary' AND $_availableTrack)
    AS artist_count,
  (SELECT COUNT(DISTINCT t.album_id) FROM tracks t
   WHERE t.deleted_at IS NULL AND t.album_id IS NOT NULL AND $_availableTrack)
    AS album_count,
  (SELECT COUNT(*) FROM track_preferences pref
   JOIN tracks t ON t.track_id = pref.track_id
   WHERE pref.liked = 1 AND t.deleted_at IS NULL AND $_availableTrack)
    AS liked_count
''')).single;
    return LibraryCounts(
      trackCount: (row['track_count']! as num).toInt(),
      artistCount: (row['artist_count']! as num).toInt(),
      albumCount: (row['album_count']! as num).toInt(),
      likedCount: (row['liked_count']! as num).toInt(),
    );
  }

  Future<void> setLiked(String trackId, bool liked) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('track_preferences', {
      'track_id': trackId,
      'liked': liked ? 1 : 0,
      'liked_at': liked ? now : null,
      'recommendation_excluded': 0,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.update(
      'track_preferences',
      {
        'liked': liked ? 1 : 0,
        'liked_at': liked ? now : null,
        'updated_at': now,
      },
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
  }

  Future<void> saveDisplayOverride(
    String trackId, {
    required String title,
    required String artist,
    required String album,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((transaction) async {
      final overrideValues = {
        'title': title,
        'artist': artist,
        'album': album,
        'updated_at': now,
      };
      final updated = await transaction.update(
        'track_overrides',
        overrideValues,
        where: 'track_id = ?',
        whereArgs: [trackId],
      );
      if (updated == 0) {
        await transaction.insert('track_overrides', {
          'track_id': trackId,
          ...overrideValues,
        });
      }
      await transaction.update(
        'tracks',
        {
          'title': title,
          'artist_display': artist,
          'album_display': album,
          'updated_at': now,
        },
        where: 'track_id = ?',
        whereArgs: [trackId],
      );
    });
  }

  Future<void> saveMediaFile(MediaFile file) async {
    await _safeUpsert('media_files', 'file_id', file.fileId, file.toMap());
  }

  Future<List<MediaFile>> mediaFilesForTrack(String trackId) async {
    final rows = await (await _database.database).query(
      'media_files',
      where: 'track_id = ?',
      whereArgs: [trackId],
      orderBy: 'created_at',
    );
    return rows.map(MediaFile.fromMap).toList(growable: false);
  }

  Future<void> setPreferredMediaFile(
    String trackId,
    String fileId, {
    bool manuallySelected = true,
  }) async {
    await (await _database.database).update(
      'tracks',
      {
        'preferred_media_file_id': fileId,
        'preferred_file_source': manuallySelected ? 'manual' : 'automatic',
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
  }

  Future<void> saveArtist(Artist artist, {required DateTime now}) async {
    await _safeUpsert('artists', 'artist_id', artist.artistId, {
      ...artist.toMap(),
      'created_at': now.millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
    });
  }

  Future<void> saveAlbum(Album album, {required DateTime now}) async {
    await _safeUpsert('albums', 'album_id', album.albumId, {
      ...album.toMap(),
      'created_at': now.millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
    });
  }

  Future<void> saveScanRoot(ScanRoot root) async {
    await _safeUpsert('scan_roots', 'root_id', root.rootId, {
      ...root.toMap(),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> saveRawMetadata(FileMetadataRaw metadata) async {
    await (await _database.database).insert('file_metadata_raw', {
      'file_id': metadata.fileId,
      ...metadata.fields(),
      'embedded_lyrics': metadata.embeddedLyrics,
      'embedded_artwork_key': metadata.embeddedArtworkKey,
      'tag_format': metadata.tagFormat,
      'raw_payload': metadata.rawPayload,
      'read_status': metadata.readStatus,
      'read_at': metadata.readAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveInferredMetadata(InferredMetadata metadata) async {
    await (await _database.database).insert('inferred_metadata', {
      'file_id': metadata.fileId,
      ...metadata.fields(),
      'inference_method': metadata.inferenceMethod,
      'field_confidence_json': metadata.fieldConfidenceJson,
      'needs_review': metadata.needsReview ? 1 : 0,
      'created_at': metadata.createdAt.millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveOnlineMetadata(OnlineMetadata metadata) async {
    await (await _database.database).insert('online_metadata', {
      'online_metadata_id': metadata.onlineMetadataId,
      'track_id': metadata.trackId,
      'provider': metadata.provider,
      'provider_recording_id': metadata.providerRecordingId,
      'provider_release_id': metadata.providerReleaseId,
      ...metadata.fields(),
      'duration_ms': metadata.durationMs,
      'confidence': metadata.confidence,
      'confirmed': metadata.confirmed ? 1 : 0,
      'rejected': metadata.rejected ? 1 : 0,
      'fetched_at': metadata.fetchedAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveTrackOverride(TrackOverride override) async {
    await (await _database.database).insert('track_overrides', {
      'track_id': override.trackId,
      ...override.fields(),
      'custom_artwork_id': override.customArtworkId,
      'updated_at': override.updatedAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> savePreference(TrackPreference preference) async {
    await (await _database.database).insert(
      'track_preferences',
      preference.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> saveStats(TrackStats stats) async {
    await (await _database.database).insert(
      'track_stats',
      stats.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> addPlayEvent(PlayEvent event) async {
    await (await _database.database).insert('play_events', event.toMap());
  }

  Future<void> createPlaylist(Playlist playlist) async {
    await (await _database.database).insert('playlists', playlist.toMap());
  }

  Future<void> addTrackToPlaylist(
    String playlistId,
    String trackId, {
    required int position,
    DateTime? addedAt,
  }) async {
    await (await _database.database).insert('playlist_tracks', {
      'playlist_id': playlistId,
      'track_id': trackId,
      'position': position,
      'added_at': (addedAt ?? DateTime.now()).millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<LibraryTrack>> _queryLibraryTracks({
    required String where,
    List<Object?> whereArgs = const [],
    String joins = '',
    String orderBy = 'LOWER(t.title)',
    int? limit,
    int offset = 0,
    bool includeUnavailable = false,
  }) async {
    final db = await _database.database;
    final effectiveWhere = includeUnavailable
        ? where
        : '($where) AND $_availableTrack';
    final sql = StringBuffer('''
SELECT t.*,
       mf.file_id AS mf_file_id, mf.track_id AS mf_track_id,
       mf.scan_root_id AS mf_scan_root_id,
       mf.media_store_volume AS mf_media_store_volume,
       mf.media_store_id AS mf_media_store_id,
       mf.content_uri AS mf_content_uri, mf.document_uri AS mf_document_uri,
       mf.relative_path AS mf_relative_path,
       mf.parent_folder AS mf_parent_folder,
       mf.filename AS mf_filename,
       mf.normalized_filename AS mf_normalized_filename,
       mf.extension AS mf_extension, mf.mime_type AS mf_mime_type,
       mf.size_bytes AS mf_size_bytes, mf.modified_at AS mf_modified_at,
       mf.duration_ms AS mf_duration_ms, mf.bitrate AS mf_bitrate,
       mf.sample_rate AS mf_sample_rate, mf.bit_depth AS mf_bit_depth,
       mf.sha256 AS mf_sha256, mf.hash_size AS mf_hash_size,
       mf.hash_modified_at AS mf_hash_modified_at,
       mf.hash_state AS mf_hash_state,
       mf.duplicate_of_file_id AS mf_duplicate_of_file_id,
       mf.last_seen_scan_id AS mf_last_seen_scan_id,
       mf.missing_since AS mf_missing_since, mf.status AS mf_status,
       mf.created_at AS mf_created_at, mf.updated_at AS mf_updated_at,
       pref.liked AS pref_liked, pref.liked_at AS pref_liked_at,
       pref.recommendation_excluded AS pref_recommendation_excluded,
       pref.exclusion_reason AS pref_exclusion_reason,
       pref.updated_at AS pref_updated_at,
       stats.play_count AS stats_play_count,
       stats.completed_count AS stats_completed_count,
       stats.skip_count AS stats_skip_count,
       stats.manually_selected_count AS stats_manually_selected_count,
       stats.total_play_duration_ms AS stats_total_play_duration_ms,
       stats.last_played_at AS stats_last_played_at,
       stats.last_skipped_at AS stats_last_skipped_at,
       stats.first_played_at AS stats_first_played_at,
       stats.updated_at AS stats_updated_at,
       $_artworkColumns,
       (SELECT MIN(lm.legacy_song_id) FROM legacy_song_map lm
        WHERE lm.track_id = t.track_id AND lm.match_status = 'matched')
        AS legacy_song_id
FROM tracks t
$joins
LEFT JOIN media_files mf ON mf.file_id = $_preferredFileId
$_trackArtworkJoin
LEFT JOIN track_preferences pref ON pref.track_id = t.track_id
LEFT JOIN track_stats stats ON stats.track_id = t.track_id
WHERE $effectiveWhere
ORDER BY $orderBy''');
    final arguments = List<Object?>.of(whereArgs);
    _appendLimit(sql, arguments, limit, offset);
    final rows = await db.rawQuery(sql.toString(), arguments);
    return rows.map(_libraryTrackFromRow).toList(growable: false);
  }

  LibraryTrack _libraryTrackFromRow(Map<String, Object?> row) {
    final track = Track.fromMap(row);
    final updatedAt = track.updatedAt;
    final fileId = row['mf_file_id'] as String?;
    final preferredFile = fileId == null
        ? null
        : MediaFile.fromMap({
            'file_id': fileId,
            'track_id': row['mf_track_id'],
            'scan_root_id': row['mf_scan_root_id'],
            'media_store_volume': row['mf_media_store_volume'],
            'media_store_id': row['mf_media_store_id'],
            'content_uri': row['mf_content_uri'],
            'document_uri': row['mf_document_uri'],
            'relative_path': row['mf_relative_path'],
            'parent_folder': row['mf_parent_folder'],
            'filename': row['mf_filename'],
            'normalized_filename': row['mf_normalized_filename'],
            'extension': row['mf_extension'],
            'mime_type': row['mf_mime_type'],
            'size_bytes': row['mf_size_bytes'],
            'modified_at': row['mf_modified_at'],
            'duration_ms': row['mf_duration_ms'],
            'bitrate': row['mf_bitrate'],
            'sample_rate': row['mf_sample_rate'],
            'bit_depth': row['mf_bit_depth'],
            'sha256': row['mf_sha256'],
            'hash_size': row['mf_hash_size'],
            'hash_modified_at': row['mf_hash_modified_at'],
            'hash_state': row['mf_hash_state'],
            'duplicate_of_file_id': row['mf_duplicate_of_file_id'],
            'last_seen_scan_id': row['mf_last_seen_scan_id'],
            'missing_since': row['mf_missing_since'],
            'status': row['mf_status'],
            'created_at': row['mf_created_at'],
            'updated_at': row['mf_updated_at'],
          });
    final preference = row['pref_updated_at'] == null
        ? TrackPreference.empty(track.trackId, updatedAt)
        : TrackPreference.fromMap({
            'track_id': track.trackId,
            'liked': row['pref_liked'],
            'liked_at': row['pref_liked_at'],
            'recommendation_excluded': row['pref_recommendation_excluded'],
            'exclusion_reason': row['pref_exclusion_reason'],
            'updated_at': row['pref_updated_at'],
          });
    final stats = row['stats_updated_at'] == null
        ? TrackStats.empty(track.trackId, updatedAt)
        : TrackStats.fromMap({
            'track_id': track.trackId,
            'play_count': row['stats_play_count'],
            'completed_count': row['stats_completed_count'],
            'skip_count': row['stats_skip_count'],
            'manually_selected_count': row['stats_manually_selected_count'],
            'total_play_duration_ms': row['stats_total_play_duration_ms'],
            'last_played_at': row['stats_last_played_at'],
            'last_skipped_at': row['stats_last_skipped_at'],
            'first_played_at': row['stats_first_played_at'],
            'updated_at': row['stats_updated_at'],
          });
    return LibraryTrack(
      track: track,
      preferredFile: preferredFile,
      artwork: ArtworkReference.maybeFromAliasedMap(row),
      preference: preference,
      stats: stats,
      legacySongId: row['legacy_song_id'] as int?,
    );
  }

  static void _appendLimit(
    StringBuffer sql,
    List<Object?> arguments,
    int? limit,
    int offset,
  ) {
    if (limit == null && offset == 0) return;
    sql.write(' LIMIT ? OFFSET ?');
    arguments
      ..add(limit ?? -1)
      ..add(offset);
  }

  static String _trackOrder(LibraryTrackSort sort) => switch (sort) {
    LibraryTrackSort.title => 'LOWER(t.title), LOWER(t.artist_display)',
    LibraryTrackSort.artist => 'LOWER(t.artist_display), LOWER(t.title)',
    LibraryTrackSort.album =>
      'LOWER(t.album_display), COALESCE(t.disc_number, 1), '
          'COALESCE(t.track_number, 9999), LOWER(t.title)',
    LibraryTrackSort.recentlyAdded => 't.added_at DESC, LOWER(t.title)',
    LibraryTrackSort.recentlyPlayed =>
      'stats.last_played_at DESC, LOWER(t.title)',
    LibraryTrackSort.playCount => 'stats.play_count DESC, LOWER(t.title)',
  };

  static ArtistLibrarySummary artistSummaryFromRow(Map<String, Object?> row) =>
      ArtistLibrarySummary(
        artist: Artist.fromMap(row),
        trackCount: (row['track_count']! as num).toInt(),
        albumCount: (row['album_count']! as num).toInt(),
        playCount: ((row['play_count'] as num?) ?? 0).toInt(),
        isCuratedFolder: ((row['is_curated_folder'] as num?) ?? 0).toInt() == 1,
        artwork: ArtworkReference.maybeFromAliasedMap(row),
      );

  static AlbumLibrarySummary albumSummaryFromRow(Map<String, Object?> row) =>
      AlbumLibrarySummary(
        album: Album.fromMap(row),
        trackCount: (row['track_count']! as num).toInt(),
        hasExplicitTrackNumber:
            ((row['has_explicit_track_number'] as num?) ?? 0).toInt() == 1,
        onlyTrackTitleMatchesAlbum:
            ((row['only_track_title_matches_album'] as num?) ?? 0).toInt() == 1,
        artwork: ArtworkReference.maybeFromAliasedMap(row),
      );

  static String availableTrackSql(String trackAlias) =>
      '''EXISTS(
    SELECT 1 FROM media_files available_mf
    WHERE available_mf.track_id = $trackAlias.track_id
      AND available_mf.status IN ('active','duplicate')
      AND COALESCE(available_mf.document_uri, available_mf.content_uri) IS NOT NULL
  )''';

  static const _availableTrack = '''EXISTS(
    SELECT 1 FROM media_files available_mf
    WHERE available_mf.track_id = t.track_id
      AND available_mf.status IN ('active','duplicate')
      AND COALESCE(available_mf.document_uri, available_mf.content_uri) IS NOT NULL
  )''';

  static String _normalizeFolderPath(String value) => value
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .join('/');

  static String _escapeLike(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

  static const _preferredFileId = '''COALESCE(
    (SELECT selected.file_id FROM media_files selected
     WHERE selected.file_id = t.preferred_media_file_id
       AND selected.status IN ('active','duplicate')
       AND COALESCE(selected.document_uri, selected.content_uri) IS NOT NULL),
    (SELECT candidate.file_id FROM media_files candidate
     WHERE candidate.track_id = t.track_id
       AND candidate.status IN ('active','duplicate')
       AND COALESCE(candidate.document_uri, candidate.content_uri) IS NOT NULL
     ORDER BY CASE candidate.status WHEN 'active' THEN 0 ELSE 1 END,
       CASE LOWER(candidate.extension)
         WHEN 'flac' THEN 0 WHEN 'wav' THEN 0 WHEN 'wave' THEN 0
         WHEN 'alac' THEN 0 WHEN 'aiff' THEN 0 WHEN 'aif' THEN 0 ELSE 1 END,
       COALESCE(candidate.bitrate, 0) DESC, candidate.size_bytes DESC,
       candidate.created_at
     LIMIT 1)
  )''';

  static const _artworkColumns = '''
       art.artwork_id AS art_artwork_id,
       art.track_id AS art_track_id,
       art.file_id AS art_file_id,
       art.source AS art_source,
       art.cache_path AS art_cache_path,
       art.content_uri AS art_content_uri,
       art.mime_type AS art_mime_type,
       art.sha256 AS art_sha256,
       art.confidence AS art_confidence,
       art.created_at AS art_created_at''';

  static const _trackArtworkJoin = '''LEFT JOIN artwork_assets art
  ON art.artwork_id = COALESCE((
    SELECT candidate.artwork_id
    FROM artwork_assets candidate
    JOIN tracks artwork_track ON artwork_track.track_id = candidate.track_id
    LEFT JOIN track_overrides artwork_override
      ON artwork_override.track_id = artwork_track.track_id
    WHERE candidate.track_id = t.track_id
      AND COALESCE(candidate.cache_path, candidate.content_uri) IS NOT NULL
      AND (candidate.source != 'online' OR (
        candidate.confidence >= 0.85 AND EXISTS(
        SELECT 1 FROM online_metadata confirmed_online
        WHERE confirmed_online.track_id = t.track_id
          AND confirmed_online.confirmed = 1
      )))
    ORDER BY CASE
      WHEN candidate.artwork_id = artwork_override.custom_artwork_id THEN 0
      WHEN candidate.source = 'manual' THEN 1
      WHEN candidate.source = 'embedded'
        AND candidate.file_id = artwork_track.preferred_media_file_id THEN 2
      WHEN candidate.source = 'embedded' THEN 3
      WHEN candidate.source = 'sidecar' THEN 4
      WHEN candidate.source = 'folder' THEN 5
      WHEN candidate.source = 'online' THEN 6
      ELSE 7
    END,
    candidate.confidence DESC,
    candidate.created_at DESC
    LIMIT 1
  ), (
    SELECT candidate.artwork_id
    FROM tracks cover_track
    JOIN artwork_assets candidate ON candidate.track_id = cover_track.track_id
    LEFT JOIN track_overrides artwork_override
      ON artwork_override.track_id = cover_track.track_id
    WHERE cover_track.album_id = t.album_id
      AND t.album_id IS NOT NULL
      AND cover_track.deleted_at IS NULL
      AND COALESCE(candidate.cache_path, candidate.content_uri) IS NOT NULL
      AND (candidate.source != 'online' OR (
        candidate.confidence >= 0.85 AND EXISTS(
        SELECT 1 FROM online_metadata confirmed_online
        WHERE confirmed_online.track_id = cover_track.track_id
          AND confirmed_online.confirmed = 1
      )))
    ORDER BY CASE
      WHEN candidate.artwork_id = artwork_override.custom_artwork_id THEN 0
      WHEN candidate.source = 'manual' THEN 1
      WHEN candidate.source = 'embedded'
        AND candidate.file_id = cover_track.preferred_media_file_id THEN 2
      WHEN candidate.source = 'embedded' THEN 3
      WHEN candidate.source = 'sidecar' THEN 4
      WHEN candidate.source = 'folder' THEN 5
      WHEN candidate.source = 'online' THEN 6
      ELSE 7
    END,
    candidate.confidence DESC,
    candidate.created_at DESC
    LIMIT 1
  ))''';

  static const _artistArtworkColumns = '''
       CASE WHEN ap.artwork_cache_path IS NULL THEN NULL ELSE ap.artist_id END
         AS art_artwork_id,
       NULL AS art_track_id,
       NULL AS art_file_id,
       'artistFolder' AS art_source,
       ap.artwork_cache_path AS art_cache_path,
       NULL AS art_content_uri,
       ap.artwork_mime_type AS art_mime_type,
       ap.artwork_sha256 AS art_sha256,
       1.0 AS art_confidence,
       ap.updated_at AS art_created_at''';

  static const _albumArtworkJoin = '''LEFT JOIN artwork_assets art
  ON art.artwork_id = (
    SELECT candidate.artwork_id
    FROM tracks cover_track
    JOIN artwork_assets candidate ON candidate.track_id = cover_track.track_id
    LEFT JOIN track_overrides artwork_override
      ON artwork_override.track_id = cover_track.track_id
    WHERE cover_track.album_id = a.album_id
      AND cover_track.deleted_at IS NULL
      AND COALESCE(candidate.cache_path, candidate.content_uri) IS NOT NULL
      AND (candidate.source != 'online' OR (
        candidate.confidence >= 0.85 AND EXISTS(
        SELECT 1 FROM online_metadata confirmed_online
        WHERE confirmed_online.track_id = cover_track.track_id
          AND confirmed_online.confirmed = 1
      )))
    ORDER BY CASE
      WHEN candidate.artwork_id = artwork_override.custom_artwork_id THEN 0
      WHEN candidate.source = 'manual' THEN 1
      WHEN candidate.source = 'embedded'
        AND candidate.file_id = cover_track.preferred_media_file_id THEN 2
      WHEN candidate.source = 'embedded' THEN 3
      WHEN candidate.source = 'sidecar' THEN 4
      WHEN candidate.source = 'folder' THEN 5
      WHEN candidate.source = 'online' THEN 6
      ELSE 7
    END,
    candidate.confidence DESC,
    candidate.created_at DESC
    LIMIT 1
  )''';

  Future<void> _safeUpsert(
    String table,
    String primaryKey,
    Object primaryKeyValue,
    Map<String, Object?> values,
  ) async {
    final db = await _database.database;
    final updated = await db.update(
      table,
      values,
      where: '$primaryKey = ?',
      whereArgs: [primaryKeyValue],
    );
    if (updated == 0) await db.insert(table, values);
  }
}

bool _isUnknownArtistName(String name) {
  final normalized = name.trim().toLowerCase();
  return normalized.isEmpty ||
      normalized == '未知歌手' ||
      normalized == '未知艺人' ||
      normalized == 'unknown artist' ||
      normalized == '<unknown>';
}

class _PrimaryArtistGroup {
  _PrimaryArtistGroup(this.primaryName);

  final String primaryName;
  final List<String> sourceArtistIds = [];
  final Set<String> collectionAlbumIds = {};
  ArtistLibrarySummary? _representative;
  ArtworkReference? _artwork;
  int trackCount = 0;
  int playCount = 0;
  bool isCuratedFolder = false;

  /// The primary artist shelf is intentionally selective: Harmony is a
  /// personal collection, so a credit only becomes a browsable artist after
  /// the user owns more than ten tracks by that primary artist. Smaller
  /// credits remain available on tracks and through search.
  bool get isMainLibraryArtist => trackCount > 10 || isCuratedFolder;

  void add(ArtistLibrarySummary summary) {
    sourceArtistIds.add(summary.artist.artistId);
    trackCount += summary.trackCount;
    playCount += summary.playCount;
    isCuratedFolder = isCuratedFolder || summary.isCuratedFolder;
    final isExact = summary.artist.displayName.trim() == primaryName;
    if (_representative == null || isExact) _representative = summary;
    if (summary.artwork != null && (_artwork == null || isExact)) {
      _artwork = summary.artwork;
    }
  }

  ArtistLibrarySummary build() {
    final representative = _representative!;
    return ArtistLibrarySummary(
      artist: Artist(
        artistId: representative.artist.artistId,
        displayName: primaryName,
        normalizedName: primaryName.toLowerCase(),
      ),
      trackCount: trackCount,
      albumCount: collectionAlbumIds.length,
      sourceArtistIds: List.unmodifiable(sourceArtistIds),
      playCount: playCount,
      isCuratedFolder: isCuratedFolder,
      artwork: _artwork,
    );
  }
}

class _FolderBuilder {
  _FolderBuilder({
    required this.scanRootId,
    required this.relativePath,
    required this.name,
    required this.parentPath,
    required this.depth,
  });

  final String scanRootId;
  final String relativePath;
  final String name;
  final String? parentPath;
  final int depth;
  final Set<String> directTrackIds = {};
  final Set<String> descendantTrackIds = {};

  LibraryFolder build() => LibraryFolder(
    scanRootId: scanRootId,
    relativePath: relativePath,
    name: name,
    parentPath: parentPath,
    depth: depth,
    directTrackCount: directTrackIds.length,
    descendantTrackCount: descendantTrackIds.length,
  );
}
