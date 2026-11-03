import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/v4/scan_models.dart';
import '../services/library_database.dart';

class FileIdentitySummary {
  const FileIdentitySummary({
    required this.movedFiles,
    required this.exactDuplicates,
    required this.suspectedVersions,
    required this.hashFailures,
  });

  final int movedFiles;
  final int exactDuplicates;
  final int suspectedVersions;
  final int hashFailures;
}

class FileIdentityRepository {
  FileIdentityRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final LibraryDatabase _database;
  final Uuid _uuid;

  Future<List<FileHashJob>> pendingHashJobs(String scanId) async {
    final db = await _database.database;
    final rows = await db.query(
      'media_files',
      where:
          'last_seen_scan_id = ? AND status = ? '
          'AND (hash_state != ? OR sha256 IS NULL)',
      whereArgs: [scanId, 'active', 'ready'],
      orderBy: 'created_at, file_id',
    );
    final jobs = <FileHashJob>[];
    for (final row in rows) {
      final uri = (row['document_uri'] ?? row['content_uri']) as String?;
      if (uri == null || uri.isEmpty) {
        await db.update(
          'media_files',
          {'hash_state': 'failed'},
          where: 'file_id = ?',
          whereArgs: [row['file_id']],
        );
        continue;
      }
      jobs.add(
        FileHashJob(
          fileId: row['file_id']! as String,
          uri: uri,
          sizeBytes: row['size_bytes']! as int,
          modifiedAt: _date(row['modified_at']),
        ),
      );
    }
    await _setPendingCount(db, scanId, jobs.length);
    return jobs;
  }

  Future<void> applyHashResults(
    String scanId,
    List<FileHashResult> results,
  ) async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      for (final result in results) {
        final rows = await transaction.query(
          'media_files',
          where: 'file_id = ? AND last_seen_scan_id = ?',
          whereArgs: [result.fileId, scanId],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final row = rows.single;
        final expectedSize = row['size_bytes']! as int;
        final expectedModifiedAt = row['modified_at'] as int?;
        final resultModifiedAt = result.modifiedAt?.millisecondsSinceEpoch;
        final unchanged =
            expectedSize == result.sizeBytes &&
            expectedModifiedAt == resultModifiedAt;
        if (result.succeeded && unchanged) {
          await transaction.update(
            'media_files',
            {
              'sha256': result.sha256,
              'hash_size': result.sizeBytes,
              'hash_modified_at': resultModifiedAt,
              'hash_state': 'ready',
              'updated_at': DateTime.now().millisecondsSinceEpoch,
            },
            where: 'file_id = ?',
            whereArgs: [result.fileId],
          );
        } else {
          await transaction.update(
            'media_files',
            {
              'sha256': null,
              'hash_size': null,
              'hash_modified_at': null,
              'hash_state': result.state == 'failed' ? 'failed' : 'stale',
              'updated_at': DateTime.now().millisecondsSinceEpoch,
            },
            where: 'file_id = ?',
            whereArgs: [result.fileId],
          );
        }
      }
      final remaining = Sqflite.firstIntValue(
        await transaction.rawQuery(
          'SELECT COUNT(*) FROM media_files '
          'WHERE last_seen_scan_id = ? AND status = ? '
          'AND (hash_state != ? OR sha256 IS NULL)',
          [scanId, 'active', 'ready'],
        ),
      );
      await _setPendingCount(transaction, scanId, remaining ?? 0);
    });
  }

  Future<FileIdentitySummary> finalizeIdentity({
    required String scanId,
    required String rootId,
  }) async {
    final db = await _database.database;
    return db.transaction((transaction) async {
      final moved = await _reconcileMovedFiles(transaction, scanId, rootId);
      final duplicates = await _classifyExactDuplicates(
        transaction,
        scanId,
        rootId,
      );
      final versions = await _rebuildSuspectedVersions(transaction);
      final failures =
          Sqflite.firstIntValue(
            await transaction.rawQuery(
              'SELECT COUNT(*) FROM media_files '
              'WHERE last_seen_scan_id = ? AND hash_state = ?',
              [scanId, 'failed'],
            ),
          ) ??
          0;
      await _setPendingCount(transaction, scanId, 0);
      return FileIdentitySummary(
        movedFiles: moved,
        exactDuplicates: duplicates,
        suspectedVersions: versions,
        hashFailures: failures,
      );
    });
  }

  Future<int> _reconcileMovedFiles(
    DatabaseExecutor db,
    String scanId,
    String rootId,
  ) async {
    final rows = await db.query(
      'media_files',
      where: 'scan_root_id = ? AND hash_state = ? AND sha256 IS NOT NULL',
      whereArgs: [rootId, 'ready'],
      orderBy: 'created_at, file_id',
    );
    final groups = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      groups.putIfAbsent(row['sha256']! as String, () => []).add(row);
    }
    var moved = 0;
    for (final group in groups.values) {
      final current = group
          .where((row) => row['last_seen_scan_id'] == scanId)
          .toList(growable: false);
      final staleCanonical = group
          .where(
            (row) =>
                row['last_seen_scan_id'] != scanId &&
                row['duplicate_of_file_id'] == null,
          )
          .toList(growable: false);
      if (current.isEmpty || staleCanonical.isEmpty) continue;
      final stable = staleCanonical.first;
      final observed = current.firstWhere(
        (row) => row['duplicate_of_file_id'] == null,
        orElse: () => current.first,
      );
      await _adoptObservedLocation(db, stable, observed, scanId);
      moved++;
    }
    return moved;
  }

  Future<void> _adoptObservedLocation(
    DatabaseExecutor db,
    Map<String, Object?> stable,
    Map<String, Object?> observed,
    String scanId,
  ) async {
    final stableFileId = stable['file_id']! as String;
    final observedFileId = observed['file_id']! as String;
    if (stableFileId == observedFileId) return;
    final stableTrackId = stable['track_id']! as String;
    final observedTrackId = observed['track_id']! as String;

    await db.update(
      'media_files',
      {'media_store_id': null, 'content_uri': null, 'document_uri': null},
      where: 'file_id = ?',
      whereArgs: [observedFileId],
    );
    await _replaceFileMetadata(
      db,
      'file_metadata_raw',
      stableFileId,
      observedFileId,
    );
    await _replaceFileMetadata(
      db,
      'inferred_metadata',
      stableFileId,
      observedFileId,
    );
    await db.update(
      'artwork_assets',
      {'file_id': stableFileId, 'track_id': stableTrackId},
      where: 'file_id = ?',
      whereArgs: [observedFileId],
    );
    await db.delete(
      'lyrics',
      where: 'media_file_id = ? AND source != ?',
      whereArgs: [stableFileId, 'manual'],
    );
    final hasSelectedLyrics =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM lyrics WHERE track_id = ? AND is_selected = 1',
            [stableTrackId],
          ),
        ) !=
        0;
    if (hasSelectedLyrics) {
      await db.update(
        'lyrics',
        {'is_selected': 0},
        where: 'media_file_id = ?',
        whereArgs: [observedFileId],
      );
    }
    await db.update(
      'lyrics',
      {'media_file_id': stableFileId, 'track_id': stableTrackId},
      where: 'media_file_id = ?',
      whereArgs: [observedFileId],
    );
    await db.update(
      'legacy_song_map',
      {'file_id': stableFileId, 'track_id': stableTrackId},
      where: 'file_id = ?',
      whereArgs: [observedFileId],
    );
    await db.update(
      'play_events',
      {'media_file_id': stableFileId, 'track_id': stableTrackId},
      where: 'media_file_id = ?',
      whereArgs: [observedFileId],
    );
    await db.delete(
      'media_file_relations',
      where: 'file_a_id = ? OR file_b_id = ?',
      whereArgs: [observedFileId, observedFileId],
    );
    await db.delete(
      'media_files',
      where: 'file_id = ?',
      whereArgs: [observedFileId],
    );

    await db.update(
      'media_files',
      {
        for (final field in _physicalFileFields) field: observed[field],
        'last_seen_scan_id': scanId,
        'missing_since': null,
        'status': 'active',
        'duplicate_of_file_id': null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'file_id = ?',
      whereArgs: [stableFileId],
    );

    final remainingSourceFiles =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM media_files WHERE track_id = ?',
            [observedTrackId],
          ),
        ) ??
        0;
    if (observedTrackId != stableTrackId && remainingSourceFiles == 0) {
      await _mergeEmptySourceTrack(db, observedTrackId, stableTrackId);
    }
  }

  Future<void> _replaceFileMetadata(
    DatabaseExecutor db,
    String table,
    String stableFileId,
    String observedFileId,
  ) async {
    final observed = await db.query(
      table,
      where: 'file_id = ?',
      whereArgs: [observedFileId],
      limit: 1,
    );
    if (observed.isEmpty) return;
    await db.delete(table, where: 'file_id = ?', whereArgs: [stableFileId]);
    await db.update(
      table,
      {'file_id': stableFileId},
      where: 'file_id = ?',
      whereArgs: [observedFileId],
    );
  }

  Future<void> _mergeEmptySourceTrack(
    DatabaseExecutor db,
    String sourceTrackId,
    String targetTrackId,
  ) async {
    await db.update(
      'artwork_assets',
      {'track_id': targetTrackId},
      where: 'track_id = ?',
      whereArgs: [sourceTrackId],
    );
    final targetHasSelectedLyrics =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM lyrics WHERE track_id = ? AND is_selected = 1',
            [targetTrackId],
          ),
        ) !=
        0;
    if (targetHasSelectedLyrics) {
      await db.update(
        'lyrics',
        {'is_selected': 0},
        where: 'track_id = ?',
        whereArgs: [sourceTrackId],
      );
    }
    await db.update(
      'lyrics',
      {'track_id': targetTrackId},
      where: 'track_id = ?',
      whereArgs: [sourceTrackId],
    );
    await _mergePreferences(db, sourceTrackId, targetTrackId);
    await _mergeStats(db, sourceTrackId, targetTrackId);
    final playlistRows = await db.query(
      'playlist_tracks',
      where: 'track_id = ?',
      whereArgs: [sourceTrackId],
    );
    for (final row in playlistRows) {
      await db.insert('playlist_tracks', {
        ...row,
        'track_id': targetTrackId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await db.delete(
      'playlist_tracks',
      where: 'track_id = ?',
      whereArgs: [sourceTrackId],
    );
    final targetOverrides = await db.query(
      'track_overrides',
      where: 'track_id = ?',
      whereArgs: [targetTrackId],
      limit: 1,
    );
    if (targetOverrides.isEmpty) {
      await db.update(
        'track_overrides',
        {'track_id': targetTrackId},
        where: 'track_id = ?',
        whereArgs: [sourceTrackId],
      );
    } else {
      await db.delete(
        'track_overrides',
        where: 'track_id = ?',
        whereArgs: [sourceTrackId],
      );
    }
    await db.update(
      'play_events',
      {'track_id': targetTrackId},
      where: 'track_id = ?',
      whereArgs: [sourceTrackId],
    );
    await db.update(
      'legacy_song_map',
      {'track_id': targetTrackId},
      where: 'track_id = ?',
      whereArgs: [sourceTrackId],
    );
    await db.delete(
      'tracks',
      where: 'track_id = ?',
      whereArgs: [sourceTrackId],
    );
  }

  Future<void> _mergePreferences(
    DatabaseExecutor db,
    String sourceTrackId,
    String targetTrackId,
  ) async {
    final source = await db.query(
      'track_preferences',
      where: 'track_id = ?',
      whereArgs: [sourceTrackId],
      limit: 1,
    );
    if (source.isEmpty) return;
    final target = await db.query(
      'track_preferences',
      where: 'track_id = ?',
      whereArgs: [targetTrackId],
      limit: 1,
    );
    if (target.isEmpty) {
      await db.update(
        'track_preferences',
        {'track_id': targetTrackId},
        where: 'track_id = ?',
        whereArgs: [sourceTrackId],
      );
      return;
    }
    await db.update(
      'track_preferences',
      {
        'liked': _booleanOr(source.single['liked'], target.single['liked']),
        'liked_at': _earliest(
          source.single['liked_at'],
          target.single['liked_at'],
        ),
        'recommendation_excluded': _booleanOr(
          source.single['recommendation_excluded'],
          target.single['recommendation_excluded'],
        ),
        'exclusion_reason':
            target.single['exclusion_reason'] ??
            source.single['exclusion_reason'],
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'track_id = ?',
      whereArgs: [targetTrackId],
    );
    await db.delete(
      'track_preferences',
      where: 'track_id = ?',
      whereArgs: [sourceTrackId],
    );
  }

  Future<void> _mergeStats(
    DatabaseExecutor db,
    String sourceTrackId,
    String targetTrackId,
  ) async {
    final source = await db.query(
      'track_stats',
      where: 'track_id = ?',
      whereArgs: [sourceTrackId],
      limit: 1,
    );
    if (source.isEmpty) return;
    final target = await db.query(
      'track_stats',
      where: 'track_id = ?',
      whereArgs: [targetTrackId],
      limit: 1,
    );
    if (target.isEmpty) {
      await db.update(
        'track_stats',
        {'track_id': targetTrackId},
        where: 'track_id = ?',
        whereArgs: [sourceTrackId],
      );
      return;
    }
    final sourceRow = source.single;
    final targetRow = target.single;
    await db.update(
      'track_stats',
      {
        for (final field in _additiveStats)
          field:
              (sourceRow[field] as int? ?? 0) + (targetRow[field] as int? ?? 0),
        'last_played_at': _latest(
          sourceRow['last_played_at'],
          targetRow['last_played_at'],
        ),
        'last_skipped_at': _latest(
          sourceRow['last_skipped_at'],
          targetRow['last_skipped_at'],
        ),
        'first_played_at': _earliest(
          sourceRow['first_played_at'],
          targetRow['first_played_at'],
        ),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'track_id = ?',
      whereArgs: [targetTrackId],
    );
    await db.delete(
      'track_stats',
      where: 'track_id = ?',
      whereArgs: [sourceTrackId],
    );
  }

  Future<int> _classifyExactDuplicates(
    DatabaseExecutor db,
    String scanId,
    String rootId,
  ) async {
    await db.update(
      'media_files',
      {'status': 'active', 'duplicate_of_file_id': null},
      where: 'scan_root_id = ? AND last_seen_scan_id = ?',
      whereArgs: [rootId, scanId],
    );
    final rows = await db.query(
      'media_files',
      where:
          'scan_root_id = ? AND last_seen_scan_id = ? '
          'AND hash_state = ? AND sha256 IS NOT NULL',
      whereArgs: [rootId, scanId, 'ready'],
      orderBy: 'created_at, file_id',
    );
    final groups = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      groups.putIfAbsent(row['sha256']! as String, () => []).add(row);
    }
    var duplicateCount = 0;
    for (final group in groups.values.where((values) => values.length > 1)) {
      final canonical = group.first;
      final canonicalId = canonical['file_id']! as String;
      final canonicalTrackId = canonical['track_id']! as String;
      for (final duplicate in group.skip(1)) {
        final duplicateId = duplicate['file_id']! as String;
        await db.update(
          'media_files',
          {'status': 'duplicate', 'duplicate_of_file_id': canonicalId},
          where: 'file_id = ?',
          whereArgs: [duplicateId],
        );
        await _saveRelation(
          db,
          canonicalId,
          duplicateId,
          type: 'exactDuplicate',
          score: 1,
          reason: {'sha256': canonical['sha256'], 'automatic': true},
        );
        await _mergeExactDuplicateTrack(
          db,
          duplicateId,
          duplicate['track_id']! as String,
          canonicalTrackId,
        );
        duplicateCount++;
      }
    }
    return duplicateCount;
  }

  Future<void> _mergeExactDuplicateTrack(
    DatabaseExecutor db,
    String duplicateFileId,
    String sourceTrackId,
    String targetTrackId,
  ) async {
    if (sourceTrackId == targetTrackId) return;
    final sourceFileCount =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM media_files WHERE track_id = ?',
            [sourceTrackId],
          ),
        ) ??
        0;
    // Never split a Track that the user already confirmed as a multi-file
    // recording. The exact duplicate relation remains available for review.
    if (sourceFileCount != 1) return;
    final sourceTrack = (await db.query(
      'tracks',
      columns: ['preferred_media_file_id', 'preferred_file_source'],
      where: 'track_id = ?',
      whereArgs: [sourceTrackId],
      limit: 1,
    )).single;
    final targetTrack = (await db.query(
      'tracks',
      columns: ['preferred_media_file_id', 'preferred_file_source'],
      where: 'track_id = ?',
      whereArgs: [targetTrackId],
      limit: 1,
    )).single;
    await db.update(
      'media_files',
      {'track_id': targetTrackId},
      where: 'file_id = ?',
      whereArgs: [duplicateFileId],
    );
    await _mergeEmptySourceTrack(db, sourceTrackId, targetTrackId);
    if (sourceTrack['preferred_file_source'] == 'manual' &&
        targetTrack['preferred_file_source'] != 'manual') {
      await db.update(
        'tracks',
        {
          'preferred_media_file_id': duplicateFileId,
          'preferred_file_source': 'manual',
        },
        where: 'track_id = ?',
        whereArgs: [targetTrackId],
      );
    }
  }

  Future<int> _rebuildSuspectedVersions(DatabaseExecutor db) async {
    await db.delete(
      'media_file_relations',
      where: 'relation_type = ?',
      whereArgs: ['suspectedVersion'],
    );
    final rows = await db.rawQuery(
      '''SELECT mf.file_id, mf.sha256, mf.extension, mf.size_bytes,
         mf.duration_ms, mf.bitrate, mf.sample_rate, mf.bit_depth,
         t.title, t.artist_display, t.album_display, a.album_type
         FROM media_files mf
         JOIN tracks t ON t.track_id = mf.track_id
         LEFT JOIN albums a ON a.album_id = t.album_id
         WHERE mf.status = 'active' AND mf.hash_state = 'ready'
           AND mf.sha256 IS NOT NULL AND t.deleted_at IS NULL''',
    );
    final groups = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final title = _normalizeIdentity(row['title'] as String?);
      final artist = _normalizeIdentity(row['artist_display'] as String?);
      if (title.isEmpty || artist.isEmpty || artist == '未知歌手') continue;
      groups.putIfAbsent('$artist\u0000$title', () => []).add(row);
    }
    var count = 0;
    for (final group in groups.values.where((values) => values.length > 1)) {
      for (var first = 0; first < group.length - 1; first++) {
        for (var second = first + 1; second < group.length; second++) {
          final a = group[first];
          final b = group[second];
          if (a['sha256'] == b['sha256']) continue;
          if (!_durationsMatch(a['duration_ms'], b['duration_ms'])) continue;
          final firstType = a['album_type'] as String?;
          final secondType = b['album_type'] as String?;
          if (firstType != secondType &&
              (firstType == 'live' || secondType == 'live')) {
            continue;
          }
          final sameAlbum =
              _normalizeIdentity(a['album_display'] as String?) ==
              _normalizeIdentity(b['album_display'] as String?);
          final score = sameAlbum ? 0.96 : 0.88;
          final suggested = _preferredByQuality(a, b);
          await _saveRelation(
            db,
            a['file_id']! as String,
            b['file_id']! as String,
            type: 'suspectedVersion',
            score: score,
            reason: {
              'sameTitle': true,
              'sameArtist': true,
              'sameAlbum': sameAlbum,
              'durationDeltaMs':
                  ((a['duration_ms'] as int? ?? 0) -
                          (b['duration_ms'] as int? ?? 0))
                      .abs(),
              'formats': [a['extension'], b['extension']],
              'suggestedPreferredFileId': suggested['file_id'],
              'automaticMerge': false,
            },
          );
          count++;
        }
      }
    }
    return count;
  }

  Future<void> _saveRelation(
    DatabaseExecutor db,
    String firstFileId,
    String secondFileId, {
    required String type,
    required double score,
    required Map<String, Object?> reason,
  }) async {
    final fileA = firstFileId.compareTo(secondFileId) <= 0
        ? firstFileId
        : secondFileId;
    final fileB = fileA == firstFileId ? secondFileId : firstFileId;
    final existing = await db.query(
      'media_file_relations',
      where: 'file_a_id = ? AND file_b_id = ?',
      whereArgs: [fileA, fileB],
      limit: 1,
    );
    if (existing.isNotEmpty &&
        {
          'confirmedVersion',
          'rejectedVersion',
        }.contains(existing.single['relation_type'])) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final values = {
      'relation_id': existing.isEmpty
          ? _uuid.v5(Namespace.url.value, 'file-relation:$fileA:$fileB')
          : existing.single['relation_id'],
      'file_a_id': fileA,
      'file_b_id': fileB,
      'relation_type': type,
      'similarity_score': score,
      'reason_json': jsonEncode(reason),
      'created_at': existing.isEmpty ? now : existing.single['created_at'],
      'updated_at': now,
    };
    if (existing.isEmpty) {
      await db.insert('media_file_relations', values);
    } else {
      await db.update(
        'media_file_relations',
        values,
        where: 'relation_id = ?',
        whereArgs: [existing.single['relation_id']],
      );
    }
  }

  Future<void> _setPendingCount(
    DatabaseExecutor db,
    String scanId,
    int count,
  ) => db.update(
    'scan_runs',
    {'hash_pending_count': count},
    where: 'scan_id = ?',
    whereArgs: [scanId],
  );

  bool _durationsMatch(Object? first, Object? second) {
    final a = first as int? ?? 0;
    final b = second as int? ?? 0;
    if (a <= 0 || b <= 0) return false;
    final tolerance = ((a > b ? a : b) * 0.02).round().clamp(2000, 5000);
    return (a - b).abs() <= tolerance;
  }

  Map<String, Object?> _preferredByQuality(
    Map<String, Object?> first,
    Map<String, Object?> second,
  ) => _qualityScore(first) >= _qualityScore(second) ? first : second;

  int _qualityScore(Map<String, Object?> row) {
    final extension = (row['extension'] as String? ?? '').toLowerCase();
    final lossless = _losslessExtensions.contains(extension);
    final bitrate = row['bitrate'] as int? ?? 0;
    final sampleRate = row['sample_rate'] as int? ?? 0;
    final bitDepth = row['bit_depth'] as int? ?? 0;
    if (lossless) return 1000000000 + bitDepth * 1000000 + sampleRate;
    return bitrate > 0 ? bitrate : (row['size_bytes'] as int? ?? 0);
  }

  String _normalizeIdentity(String? value) => (value ?? '')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s_.\-/—·（）()\[\]]+'), '');

  static const _physicalFileFields = <String>[
    'scan_root_id',
    'media_store_volume',
    'media_store_id',
    'content_uri',
    'document_uri',
    'relative_path',
    'parent_folder',
    'filename',
    'normalized_filename',
    'extension',
    'mime_type',
    'size_bytes',
    'modified_at',
    'duration_ms',
    'bitrate',
    'sample_rate',
    'bit_depth',
    'sha256',
    'hash_size',
    'hash_modified_at',
    'hash_state',
  ];
  static const _additiveStats = <String>[
    'play_count',
    'completed_count',
    'skip_count',
    'manually_selected_count',
    'total_play_duration_ms',
  ];
  static const _losslessExtensions = <String>{
    'flac',
    'wav',
    'wave',
    'alac',
    'aiff',
    'aif',
  };
}

int _booleanOr(Object? first, Object? second) =>
    first == 1 || second == 1 ? 1 : 0;

int? _earliest(Object? first, Object? second) {
  final values = [first, second].whereType<int>().toList(growable: false);
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a < b ? a : b);
}

int? _latest(Object? first, Object? second) {
  final values = [first, second].whereType<int>().toList(growable: false);
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a > b ? a : b);
}

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.fromMillisecondsSinceEpoch(value as int);
