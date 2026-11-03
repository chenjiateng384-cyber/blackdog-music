// ignore_for_file: prefer_initializing_formals

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/v4/library_entities.dart';
import '../models/v4/library_browsing.dart';
import '../models/v4/scan_models.dart';
import '../services/library_database.dart';
import '../services/lrc_matcher.dart';
import '../services/metadata_inference.dart';
import '../services/metadata_resolver.dart';

class IngestBatchResult {
  const IngestBatchResult({required this.processed, required this.legacyLinks});

  final int processed;
  final List<LegacyScanLink> legacyLinks;
}

class LegacyScanLink {
  const LegacyScanLink({
    required this.legacySongId,
    required this.trackId,
    required this.fileId,
  });

  final int legacySongId;
  final String trackId;
  final String fileId;
}

class ScanRepository {
  ScanRepository(
    this._database, {
    Uuid? uuid,
    MetadataInference inference = const MetadataInference(),
    MetadataResolver resolver = const MetadataResolver(),
    LrcMatcher lyricsMatcher = const LrcMatcher(),
  }) : _uuid = uuid ?? const Uuid(),
       _inference = inference,
       _resolver = resolver,
       _lyricsMatcher = lyricsMatcher;

  final LibraryDatabase _database;
  final Uuid _uuid;
  final MetadataInference _inference;
  final MetadataResolver _resolver;
  final LrcMatcher _lyricsMatcher;

  Future<List<ScanRoot>> scanRoots({bool enabledOnly = false}) async {
    final rows = await (await _database.database).query(
      'scan_roots',
      where: enabledOnly ? 'enabled = 1' : null,
      orderBy: 'is_primary DESC, created_at',
    );
    return rows.map(_scanRootFromMap).toList(growable: false);
  }

  Future<ScanRoot> savePickedRoot(
    PickedScanRoot picked, {
    bool makePrimary = false,
  }) async {
    final db = await _database.database;
    final now = DateTime.now();
    late ScanRoot saved;
    await db.transaction((transaction) async {
      final existing = await transaction.query(
        'scan_roots',
        where: 'tree_uri = ?',
        whereArgs: [picked.treeUri],
        limit: 1,
      );
      final rootId = existing.isEmpty
          ? _uuid.v4()
          : existing.single['root_id']! as String;
      final createdAt = existing.isEmpty
          ? now
          : DateTime.fromMillisecondsSinceEpoch(
              existing.single['created_at']! as int,
            );
      final shouldBePrimary =
          makePrimary ||
          existing.isEmpty &&
              Sqflite.firstIntValue(
                    await transaction.rawQuery(
                      'SELECT COUNT(*) FROM scan_roots WHERE enabled = 1',
                    ),
                  ) ==
                  0;
      if (shouldBePrimary) {
        await transaction.update('scan_roots', {'is_primary': 0});
      }
      saved = ScanRoot(
        rootId: rootId,
        treeUri: picked.treeUri,
        displayName: picked.displayName,
        volumeName: picked.volumeName,
        relativePathHint: picked.relativePathHint,
        accessType: 'safTree',
        isPrimary:
            shouldBePrimary ||
            (existing.isNotEmpty && existing.single['is_primary'] == 1),
        permissionPersisted: picked.permissionPersisted,
        enabled: true,
        createdAt: createdAt,
      );
      await _safeUpsert(transaction, 'scan_roots', 'root_id', rootId, {
        ...saved.toMap(),
        'updated_at': now.millisecondsSinceEpoch,
      });
    });
    return saved;
  }

  Future<void> setRootPermission(String rootId, bool persisted) async {
    await (await _database.database).update(
      'scan_roots',
      {
        'permission_persisted': persisted ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'root_id = ?',
      whereArgs: [rootId],
    );
  }

  Future<void> removeScanRoot(String rootId) async {
    await (await _database.database).delete(
      'scan_roots',
      where: 'root_id = ?',
      whereArgs: [rootId],
    );
  }

  Future<void> startScan({
    required String scanId,
    required String rootId,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((transaction) async {
      await _recoverInterruptedScans(transaction, now: now);
      await transaction.insert('scan_runs', {
        'scan_id': scanId,
        'root_id': rootId,
        'status': 'running',
        'started_at': now,
      });
    });
  }

  /// A database row cannot represent a live native scan after the process has
  /// restarted. Recovering it is safe because the scanner is single-flight.
  Future<int> recoverInterruptedScans() async {
    final db = await _database.database;
    return db.transaction(
      (transaction) => _recoverInterruptedScans(
        transaction,
        now: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> updateScanProgress({
    required String scanId,
    required int discovered,
    required int processed,
  }) async {
    await (await _database.database).update(
      'scan_runs',
      {'discovered_count': discovered, 'processed_count': processed},
      where: 'scan_id = ?',
      whereArgs: [scanId],
    );
  }

  Future<IngestBatchResult> ingestBatch({
    required String scanId,
    required ScanRoot root,
    required List<ScannedAudioFile> files,
  }) async {
    final db = await _database.database;
    final legacyLinks = <LegacyScanLink>[];
    await db.transaction((transaction) async {
      for (final file in files) {
        final link = await _ingestOne(transaction, scanId, root, file);
        if (link != null) legacyLinks.add(link);
      }
      await transaction.rawUpdate(
        'UPDATE scan_runs SET processed_count = processed_count + ? WHERE scan_id = ?',
        [files.length, scanId],
      );
    });
    return IngestBatchResult(
      processed: files.length,
      legacyLinks: List.unmodifiable(legacyLinks),
    );
  }

  Future<void> finishScan({
    required String scanId,
    required String rootId,
    required int total,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((transaction) async {
      await transaction.update(
        'media_files',
        {'status': 'missing', 'missing_since': now, 'updated_at': now},
        where:
            'scan_root_id = ? AND (last_seen_scan_id IS NULL OR last_seen_scan_id != ?) '
            'AND status IN (?, ?)',
        whereArgs: [rootId, scanId, 'active', 'duplicate'],
      );
      await _repairAutomaticPreferredFiles(transaction, now);
      await _deleteTrueOrphanEntities(transaction);
      await transaction.update(
        'scan_runs',
        {
          'status': 'completed',
          'discovered_count': total,
          'processed_count': total,
          'finished_at': now,
          'error': null,
        },
        where: 'scan_id = ? AND status = ?',
        whereArgs: [scanId, 'running'],
      );
      await transaction.update(
        'scan_roots',
        {'last_scan_at': now, 'updated_at': now},
        where: 'root_id = ?',
        whereArgs: [rootId],
      );
    });
  }

  Future<void> failScan(String scanId, String error) async {
    await (await _database.database).update(
      'scan_runs',
      {
        'status': 'failed',
        'finished_at': DateTime.now().millisecondsSinceEpoch,
        'error': error,
      },
      where: 'scan_id = ? AND status = ?',
      whereArgs: [scanId, 'running'],
    );
  }

  Future<void> cancelScan(String scanId) async {
    await (await _database.database).update(
      'scan_runs',
      {
        'status': 'cancelled',
        'finished_at': DateTime.now().millisecondsSinceEpoch,
        'error': 'cancelled',
      },
      where: 'scan_id = ? AND status = ?',
      whereArgs: [scanId, 'running'],
    );
  }

  Future<LegacyScanLink?> _ingestOne(
    DatabaseExecutor db,
    String scanId,
    ScanRoot root,
    ScannedAudioFile file,
  ) async {
    final now = DateTime.now();
    final existingFile = await _findExistingFile(db, root.rootId, file);
    final fileId = existingFile?['file_id'] as String? ?? _uuid.v4();
    final trackId = existingFile?['track_id'] as String? ?? _uuid.v4();
    final existingTrack = await db.query(
      'tracks',
      where: 'track_id = ?',
      whereArgs: [trackId],
      limit: 1,
    );
    final overrides = await db.query(
      'track_overrides',
      where: 'track_id = ?',
      whereArgs: [trackId],
      limit: 1,
    );
    final inferred = _inference.infer(file);
    final resolved = _resolver.resolve(
      raw: file.metadata,
      inferred: inferred,
      override: overrides.isEmpty ? const {} : overrides.single,
    );
    final primaryArtist = primaryArtistName(resolved.artist);
    final artistId = _uuid.v5(
      Namespace.url.value,
      'artist:${_normalize(primaryArtist)}',
    );
    final meaningfulAlbum = !_isPlaceholderAlbum(resolved.album);
    final albumArtist = primaryArtistName(resolved.albumArtist);
    final albumArtistId = _uuid.v5(
      Namespace.url.value,
      'artist:${_normalize(albumArtist)}',
    );
    final albumId = !meaningfulAlbum
        ? null
        : _uuid.v5(
            Namespace.url.value,
            'album:${_normalize(albumArtist)}:${_normalize(resolved.album)}:${resolved.year ?? ''}',
          );
    await _safeUpsert(db, 'artists', 'artist_id', artistId, {
      'artist_id': artistId,
      'display_name': primaryArtist,
      'normalized_name': _normalize(primaryArtist),
      'created_at': now.millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
    });
    await _saveArtistProfile(db, root, artistId, primaryArtist, file, now);
    if (albumId != null) {
      await _safeUpsert(db, 'artists', 'artist_id', albumArtistId, {
        'artist_id': albumArtistId,
        'display_name': albumArtist,
        'normalized_name': _normalize(albumArtist),
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      });
      await _safeUpsert(db, 'albums', 'album_id', albumId, {
        'album_id': albumId,
        'title': resolved.album,
        'normalized_title': _normalize(resolved.album),
        'album_artist_id': albumArtistId,
        'year': resolved.year,
        'album_type': resolved.albumType,
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      });
    }
    final addedAt = existingTrack.isEmpty
        ? file.dateAdded ?? now
        : DateTime.fromMillisecondsSinceEpoch(
            existingTrack.single['added_at']! as int,
          );
    await _safeUpsert(db, 'tracks', 'track_id', trackId, {
      'track_id': trackId,
      'title': resolved.title,
      'artist_display': resolved.artist,
      'album_artist_display': resolved.albumArtist,
      'album_display': meaningfulAlbum ? resolved.album : '未知专辑',
      'album_id': albumId,
      'year': resolved.year,
      'disc_number': resolved.discNumber,
      'track_number': resolved.trackNumber,
      'duration_ms': file.metadata.durationMs,
      'preferred_media_file_id': existingTrack.isEmpty
          ? null
          : existingTrack.single['preferred_media_file_id'],
      'preferred_file_source': existingTrack.isEmpty
          ? 'automatic'
          : existingTrack.single['preferred_file_source'],
      'metadata_state': resolved.metadataState,
      'added_at': addedAt.millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
      'deleted_at': null,
    });
    final createdAt = existingFile == null
        ? now
        : DateTime.fromMillisecondsSinceEpoch(
            existingFile['created_at']! as int,
          );
    final modifiedAt = file.modifiedAt?.millisecondsSinceEpoch;
    final hashReusable =
        existingFile?['hash_state'] == 'ready' &&
        existingFile?['sha256'] != null &&
        existingFile?['hash_size'] == file.sizeBytes &&
        modifiedAt != null &&
        existingFile?['hash_modified_at'] == modifiedAt;
    await _safeUpsert(db, 'media_files', 'file_id', fileId, {
      'file_id': fileId,
      'track_id': trackId,
      'scan_root_id': root.rootId,
      'media_store_volume': file.mediaStoreVolume,
      'media_store_id': file.mediaStoreId,
      'content_uri': file.contentUri,
      'document_uri': file.documentUri,
      'relative_path': file.relativePath,
      'parent_folder': file.parentFolder,
      'filename': file.filename,
      'normalized_filename': _normalizeFilename(file.filename),
      'extension': file.extension,
      'mime_type': file.mimeType,
      'size_bytes': file.sizeBytes,
      'modified_at': modifiedAt,
      'duration_ms': file.metadata.durationMs,
      'bitrate': file.metadata.bitrate,
      'sample_rate': file.metadata.sampleRate,
      'bit_depth': file.metadata.bitDepth,
      'sha256': hashReusable ? existingFile!['sha256'] : null,
      'hash_size': hashReusable ? existingFile!['hash_size'] : null,
      'hash_modified_at': hashReusable
          ? existingFile!['hash_modified_at']
          : null,
      'hash_state': hashReusable ? 'ready' : 'pending',
      'duplicate_of_file_id': null,
      'last_seen_scan_id': scanId,
      'missing_since': null,
      'status': 'active',
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
    });
    if (existingTrack.isEmpty ||
        existingTrack.single['preferred_media_file_id'] == null) {
      await db.update(
        'tracks',
        {
          'preferred_media_file_id': fileId,
          'preferred_file_source': 'automatic',
        },
        where: 'track_id = ?',
        whereArgs: [trackId],
      );
    }
    await db.delete(
      'track_artists',
      where: 'track_id = ? AND role = ?',
      whereArgs: [trackId, 'primary'],
    );
    await db.insert('track_artists', {
      'track_id': trackId,
      'artist_id': artistId,
      'role': 'primary',
      'position': 0,
    });
    await _saveMetadata(db, fileId, file, inferred, now);
    await _saveArtwork(db, trackId, fileId, file, now);
    await _saveLyrics(db, root, trackId, fileId, file, resolved, now);

    if (file.mediaStoreId == null) return null;
    final legacy = await db.query(
      'legacy_song_map',
      columns: ['legacy_song_id'],
      where: 'legacy_song_id = ? AND match_status = ?',
      whereArgs: [file.mediaStoreId, 'awaiting_scan'],
      limit: 1,
    );
    return legacy.isEmpty
        ? null
        : LegacyScanLink(
            legacySongId: file.mediaStoreId!,
            trackId: trackId,
            fileId: fileId,
          );
  }

  Future<Map<String, Object?>?> _findExistingFile(
    DatabaseExecutor db,
    String rootId,
    ScannedAudioFile file,
  ) async {
    var rows = await db.query(
      'media_files',
      where: 'document_uri = ?',
      whereArgs: [file.documentUri],
      limit: 1,
    );
    if (rows.isEmpty && file.contentUri != null) {
      rows = await db.query(
        'media_files',
        where: 'content_uri = ?',
        whereArgs: [file.contentUri],
        limit: 1,
      );
    }
    if (rows.isEmpty && file.mediaStoreId != null) {
      rows = await db.query(
        'media_files',
        where: 'media_store_volume = ? AND media_store_id = ?',
        whereArgs: [file.mediaStoreVolume, file.mediaStoreId],
        limit: 1,
      );
    }
    if (rows.isEmpty) {
      rows = await db.query(
        'media_files',
        where: 'scan_root_id = ? AND relative_path = ?',
        whereArgs: [rootId, file.relativePath],
        limit: 1,
      );
    }
    return rows.isEmpty ? null : rows.single;
  }

  Future<void> _saveMetadata(
    DatabaseExecutor db,
    String fileId,
    ScannedAudioFile file,
    InferredAudioMetadata inferred,
    DateTime now,
  ) async {
    final raw = file.metadata;
    await _safeUpsert(db, 'file_metadata_raw', 'file_id', fileId, {
      'file_id': fileId,
      'title': raw.title,
      'artist': raw.artist,
      'album_artist': raw.albumArtist,
      'album': raw.album,
      'year': raw.year,
      'disc_number': raw.discNumber,
      'track_number': raw.trackNumber,
      'embedded_lyrics': raw.embeddedLyrics,
      'embedded_artwork_key': raw.embeddedArtworkKey,
      'tag_format': raw.tagFormat,
      'raw_payload': raw.rawPayload,
      'read_status': raw.readStatus,
      'read_at': now.millisecondsSinceEpoch,
    });
    await _safeUpsert(db, 'inferred_metadata', 'file_id', fileId, {
      'file_id': fileId,
      'title': inferred.title,
      'artist': inferred.artist,
      'album_artist': inferred.albumArtist,
      'album': inferred.album,
      'year': inferred.year,
      'disc_number': inferred.discNumber,
      'track_number': inferred.trackNumber,
      'inference_method': inferred.inferenceMethod,
      'field_confidence_json': inferred.fieldConfidenceJson,
      'needs_review': inferred.needsReview ? 1 : 0,
      'created_at': now.millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
    });
  }

  Future<void> _saveArtwork(
    DatabaseExecutor db,
    String trackId,
    String fileId,
    ScannedAudioFile file,
    DateTime now,
  ) async {
    final raw = file.metadata;
    final key = raw.embeddedArtworkKey;
    if (key != null && raw.embeddedArtworkPath != null) {
      final artworkId = _uuid.v5(Namespace.url.value, 'artwork:$fileId:$key');
      await _safeUpsert(db, 'artwork_assets', 'artwork_id', artworkId, {
        'artwork_id': artworkId,
        'track_id': trackId,
        'file_id': fileId,
        'source': 'embedded',
        'cache_path': raw.embeddedArtworkPath,
        'mime_type': raw.embeddedArtworkMime,
        'sha256': key,
        'confidence': 1.0,
        'created_at': now.millisecondsSinceEpoch,
      });
    }

    final localKey = file.localArtworkKey;
    final localPath = file.localArtworkPath;
    if (localKey == null || localPath == null) return;
    final isSidecar = file.localArtworkSource == 'sidecar';
    // Database v4 deliberately keeps the original artwork source CHECK
    // constraint. Local sidecar/folder images are therefore stored as local
    // embedded-class assets and distinguished by confidence. This preserves
    // the required embedded > same-name image > folder image priority without
    // a schema migration during the UI stability phase.
    const source = 'embedded';
    final localArtworkId = _uuid.v5(
      Namespace.url.value,
      'artwork:$trackId:$source:$localKey',
    );
    await _safeUpsert(db, 'artwork_assets', 'artwork_id', localArtworkId, {
      'artwork_id': localArtworkId,
      'track_id': trackId,
      'file_id': fileId,
      'source': source,
      'cache_path': localPath,
      'mime_type': file.localArtworkMime,
      'sha256': localKey,
      'confidence': isSidecar ? 0.98 : 0.95,
      'created_at': now.millisecondsSinceEpoch,
    });
  }

  Future<void> _saveArtistProfile(
    DatabaseExecutor db,
    ScanRoot root,
    String artistId,
    String primaryArtist,
    ScannedAudioFile file,
    DateTime now,
  ) async {
    final folderName = file.libraryArtistFolderName;
    final relativeDirectory = file.libraryArtistRelativeDirectory;
    if (folderName == null ||
        relativeDirectory == null ||
        !_matchesCuratedArtistFolder(folderName, primaryArtist)) {
      return;
    }
    await _safeUpsert(db, 'artist_profiles', 'artist_id', artistId, {
      'artist_id': artistId,
      'scan_root_id': root.rootId,
      'relative_directory': relativeDirectory,
      'artwork_cache_path': file.artistArtworkPath,
      'artwork_mime_type': file.artistArtworkMime,
      'artwork_sha256': file.artistArtworkKey,
      'updated_at': now.millisecondsSinceEpoch,
    });
  }

  Future<void> _saveLyrics(
    DatabaseExecutor db,
    ScanRoot root,
    String trackId,
    String fileId,
    ScannedAudioFile file,
    ResolvedTrackMetadata resolved,
    DateTime now,
  ) async {
    final match = _lyricsMatcher.match(
      audio: file,
      resolvedTitle: resolved.title,
      resolvedArtist: resolved.artist,
    );
    if (match != null) {
      await db.update(
        'lyrics',
        {'is_selected': 0},
        where: 'track_id = ?',
        whereArgs: [trackId],
      );
      final id = _uuid.v5(
        Namespace.url.value,
        'lyrics:${match.candidate.documentUri}',
      );
      await _safeUpsert(db, 'lyrics', 'lyrics_id', id, {
        'lyrics_id': id,
        'track_id': trackId,
        'media_file_id': fileId,
        'scan_root_id': root.rootId,
        'document_uri': match.candidate.documentUri,
        'relative_path': match.candidate.relativePath,
        'filename': match.candidate.filename,
        'source': 'sidecarLrc',
        'match_method': match.method,
        'matched': 1,
        'confidence': match.confidence,
        'offset_ms': 0,
        'size_bytes': match.candidate.sizeBytes,
        'modified_at': match.candidate.modifiedAt?.millisecondsSinceEpoch,
        'is_selected': 1,
        'created_at': now.millisecondsSinceEpoch,
      });
      return;
    }
    if (file.metadata.embeddedLyrics == null) return;
    final id = _uuid.v5(Namespace.url.value, 'lyrics:embedded:$fileId');
    final selected =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM lyrics WHERE track_id = ? AND is_selected = 1',
            [trackId],
          ),
        ) ==
        0;
    await _safeUpsert(db, 'lyrics', 'lyrics_id', id, {
      'lyrics_id': id,
      'track_id': trackId,
      'media_file_id': fileId,
      'scan_root_id': root.rootId,
      'source': 'embedded',
      'match_method': 'embeddedTag',
      'matched': 1,
      'confidence': 1.0,
      'offset_ms': 0,
      'is_selected': selected ? 1 : 0,
      'created_at': now.millisecondsSinceEpoch,
    });
  }

  Future<void> _safeUpsert(
    DatabaseExecutor db,
    String table,
    String primaryKey,
    Object primaryKeyValue,
    Map<String, Object?> values,
  ) async {
    final updated = await db.update(
      table,
      values,
      where: '$primaryKey = ?',
      whereArgs: [primaryKeyValue],
    );
    if (updated == 0) await db.insert(table, values);
  }

  Future<int> _recoverInterruptedScans(
    DatabaseExecutor db, {
    required int now,
  }) => db.update(
    'scan_runs',
    {
      'status': 'failed',
      'finished_at': now,
      'error': 'interrupted: App exited before scan completed',
    },
    where: 'status = ?',
    whereArgs: ['running'],
  );

  Future<void> _repairAutomaticPreferredFiles(
    DatabaseExecutor db,
    int now,
  ) async {
    await db.rawUpdate(
      '''
UPDATE tracks
SET preferred_media_file_id = (
      SELECT candidate.file_id
      FROM media_files candidate
      WHERE candidate.track_id = tracks.track_id
        AND candidate.status IN ('active','duplicate')
        AND (candidate.document_uri IS NOT NULL OR candidate.content_uri IS NOT NULL)
      ORDER BY CASE
        WHEN LOWER(candidate.extension) IN ('flac','wav','alac','ape') THEN 0
        WHEN COALESCE(candidate.bitrate, 0) >= 256000 THEN 1
        ELSE 2
      END,
      COALESCE(candidate.bitrate, 0) DESC,
      candidate.created_at
      LIMIT 1
    ),
    updated_at = ?
WHERE preferred_file_source = 'automatic'
  AND EXISTS(
    SELECT 1 FROM media_files available
    WHERE available.track_id = tracks.track_id
      AND available.status IN ('active','duplicate')
      AND (available.document_uri IS NOT NULL OR available.content_uri IS NOT NULL)
  )
  AND (
    preferred_media_file_id IS NULL OR NOT EXISTS(
      SELECT 1 FROM media_files preferred
      WHERE preferred.file_id = tracks.preferred_media_file_id
        AND preferred.track_id = tracks.track_id
        AND preferred.status IN ('active','duplicate')
        AND (preferred.document_uri IS NOT NULL OR preferred.content_uri IS NOT NULL)
    )
  )
''',
      [now],
    );
  }

  Future<void> _deleteTrueOrphanEntities(DatabaseExecutor db) async {
    await db.rawDelete('''
DELETE FROM albums
WHERE NOT EXISTS(
  SELECT 1 FROM tracks WHERE tracks.album_id = albums.album_id
)
''');
    await db.rawDelete('''
DELETE FROM artists
WHERE NOT EXISTS(
  SELECT 1 FROM track_artists
  WHERE track_artists.artist_id = artists.artist_id
)
AND NOT EXISTS(
  SELECT 1 FROM albums WHERE albums.album_artist_id = artists.artist_id
)
''');
  }

  ScanRoot _scanRootFromMap(Map<String, Object?> row) => ScanRoot(
    rootId: row['root_id']! as String,
    treeUri: row['tree_uri']! as String,
    displayName: row['display_name']! as String,
    volumeName: row['volume_name'] as String?,
    relativePathHint: row['relative_path_hint'] as String?,
    accessType: row['access_type']! as String,
    isPrimary: row['is_primary'] == 1,
    permissionPersisted: row['permission_persisted'] == 1,
    enabled: row['enabled'] == 1,
    lastScanAt: _date(row['last_scan_at']),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
  );

  String _normalize(String value) => value.trim().toLowerCase().replaceAll(
    RegExp(r'[\s_.\-/—·（）()\[\]]+'),
    '',
  );

  String _normalizeFilename(String value) =>
      value.trim().toLowerCase().replaceAll('\\', '/');

  bool _matchesCuratedArtistFolder(String folderName, String artistName) {
    final folder = _normalize(folderName);
    final artist = _normalize(artistName);
    if (folder.isEmpty ||
        artist.isEmpty ||
        _nonArtistFolders.contains(folder)) {
      return false;
    }
    if (folder == artist) return true;
    return folder.length >= 2 &&
        artist.length >= 2 &&
        (folder.contains(artist) || artist.contains(folder));
  }

  bool _isPlaceholderAlbum(String value) {
    final normalized = _normalize(value);
    return normalized.isEmpty ||
        const {
          '未知专辑',
          'unknownalbum',
          'unknown',
          '单曲',
          '单曲集',
          'ep与单曲',
          'ep和单曲',
          'single',
          'singles',
          'n/a',
          'na',
        }.contains(normalized);
  }

  static const _nonArtistFolders = <String>{
    'music',
    '音乐',
    '音乐文件',
    '英文歌',
    '英语歌',
    '零散单曲',
    '单曲',
    '其他歌手',
    '待处理',
  };
}

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.fromMillisecondsSinceEpoch(value as int);
