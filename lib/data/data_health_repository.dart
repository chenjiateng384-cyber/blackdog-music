import 'dart:io';

import '../models/v4/data_safety.dart';
import '../services/library_database.dart';

class DataHealthRepository {
  const DataHealthRepository(this._database);

  final LibraryDatabase _database;

  Future<DataHealthReport> inspect({String? activePlaybackEventId}) async {
    final db = await _database.database;
    final issues = <DataHealthIssue>[];
    final integrityRows = await db.rawQuery('PRAGMA integrity_check');
    final integrityMessages = integrityRows
        .expand((row) => row.values)
        .map((value) => '$value')
        .where((value) => value.toLowerCase() != 'ok')
        .toList(growable: false);
    final foreignKeys = await db.rawQuery('PRAGMA foreign_key_check');
    if (foreignKeys.isNotEmpty) {
      issues.add(
        DataHealthIssue(
          code: 'foreign_keys',
          message: '发现 ${foreignKeys.length} 条关联异常',
          count: foreignKeys.length,
        ),
      );
    }

    final unfinished = await _count(
      'SELECT COUNT(*) AS count FROM play_events WHERE ended_at IS NULL '
      'AND (? IS NULL OR event_id != ?)',
      [activePlaybackEventId, activePlaybackEventId],
    );
    if (unfinished > 0) {
      issues.add(
        DataHealthIssue(
          code: 'unfinished_playback',
          message: '有 $unfinished 条播放记录尚未正常结束',
          count: unfinished,
        ),
      );
    }

    final unavailableTracks = await _count('''
SELECT COUNT(*) AS count FROM tracks t
WHERE t.deleted_at IS NULL AND NOT EXISTS(
  SELECT 1 FROM media_files mf
  WHERE mf.track_id = t.track_id AND mf.status = 'active'
)''');
    if (unavailableTracks > 0) {
      issues.add(
        DataHealthIssue(
          code: 'unavailable_tracks',
          message: '有 $unavailableTracks 首歌曲当前没有可用文件',
          count: unavailableTracks,
        ),
      );
    }

    final missingAssets = await _missingPrivateAssets();
    if (missingAssets > 0) {
      issues.add(
        DataHealthIssue(
          code: 'missing_private_assets',
          message: '有 $missingAssets 个人工资源文件已失效',
          count: missingAssets,
        ),
      );
    }

    final orphanAlbums = await _count('''
SELECT COUNT(*) AS count FROM albums a
WHERE NOT EXISTS(
  SELECT 1 FROM tracks t
  WHERE t.album_id = a.album_id AND t.deleted_at IS NULL
)''');
    final orphanArtists = await _count('''
SELECT COUNT(*) AS count FROM artists a
WHERE NOT EXISTS(
  SELECT 1 FROM track_artists ta
  JOIN tracks t ON t.track_id = ta.track_id
  WHERE ta.artist_id = a.artist_id AND t.deleted_at IS NULL
)
AND NOT EXISTS(
  SELECT 1 FROM albums album
  JOIN tracks t ON t.album_id = album.album_id
  WHERE album.album_artist_id = a.artist_id AND t.deleted_at IS NULL
)''');
    if (orphanAlbums + orphanArtists > 0) {
      issues.add(
        DataHealthIssue(
          code: 'orphan_library_entities',
          message: '有 ${orphanAlbums + orphanArtists} 个未关联的歌手或专辑记录',
          count: orphanAlbums + orphanArtists,
        ),
      );
    }

    return DataHealthReport(
      checkedAt: DateTime.now(),
      integrityOk: integrityMessages.isEmpty && foreignKeys.isEmpty,
      issues: List.unmodifiable([
        for (final message in integrityMessages)
          DataHealthIssue(code: 'integrity', message: message),
        ...issues,
      ]),
    );
  }

  Future<int> _count(String sql, [List<Object?>? arguments]) async {
    final rows = await (await _database.database).rawQuery(sql, arguments);
    return ((rows.single['count'] as num?) ?? 0).toInt();
  }

  Future<int> _missingPrivateAssets() async {
    final rows = await (await _database.database).query(
      'artwork_assets',
      columns: ['cache_path'],
      where: "source = 'manual' AND cache_path IS NOT NULL",
    );
    var missing = 0;
    for (final row in rows) {
      final path = row['cache_path'] as String?;
      if (path != null && !path.startsWith('harmony-backup://')) {
        if (!await File(path).exists()) missing++;
      }
    }
    return missing;
  }
}
