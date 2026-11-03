import '../models/v4/music_archive.dart';
import '../services/library_database.dart';
import 'library_repository.dart';

class MusicArchiveRepository {
  const MusicArchiveRepository(this._database, this._libraryRepository);

  final LibraryDatabase _database;
  final LibraryRepository _libraryRepository;

  Future<MusicArchiveSnapshot> load(DateTime now) async {
    final db = await _database.database;
    final yearStart = DateTime(now.year).millisecondsSinceEpoch;
    final nextYear = DateTime(now.year + 1).millisecondsSinceEpoch;
    final yearArgs = <Object>[yearStart, nextYear];
    const validYearEvent =
        'e.ended_at IS NOT NULL AND e.listened_duration_ms > 0 '
        'AND e.started_at >= ? AND e.started_at < ?';

    final totals = (await db.rawQuery('''
SELECT COUNT(*) AS event_count,
       COUNT(DISTINCT e.track_id) AS track_count,
       COALESCE(SUM(e.listened_duration_ms), 0) AS listened_ms
  FROM play_events e
 WHERE $validYearEvent
''', yearArgs)).single;

    final topTrackRows = await db.rawQuery('''
SELECT e.track_id,
       SUM(e.listened_duration_ms) AS listened_ms,
       COUNT(*) AS event_count
  FROM play_events e
 WHERE $validYearEvent
 GROUP BY e.track_id
 ORDER BY listened_ms DESC, event_count DESC, e.track_id
 LIMIT 1
''', yearArgs);
    final topTrackId = topTrackRows.isEmpty
        ? null
        : topTrackRows.single['track_id'] as String?;

    final topArtistRows = await db.rawQuery('''
SELECT a.display_name,
       SUM(e.listened_duration_ms) AS listened_ms,
       COUNT(*) AS event_count
  FROM play_events e
  JOIN track_artists ta
    ON ta.track_id = e.track_id AND ta.role = 'primary'
  JOIN artists a ON a.artist_id = ta.artist_id
 WHERE $validYearEvent
   AND TRIM(a.display_name) != ''
   AND LOWER(TRIM(a.display_name)) NOT IN ('unknown artist', '未知歌手')
 GROUP BY a.artist_id
 ORDER BY listened_ms DESC, event_count DESC, a.normalized_name
 LIMIT 1
''', yearArgs);

    final topAlbumRows = await db.rawQuery('''
SELECT a.title,
       SUM(e.listened_duration_ms) AS listened_ms,
       COUNT(*) AS event_count
  FROM play_events e
  JOIN tracks t ON t.track_id = e.track_id
  JOIN albums a ON a.album_id = t.album_id
 WHERE $validYearEvent
   AND TRIM(a.title) != ''
   AND LOWER(TRIM(a.title)) NOT IN ('single', 'unknown album', '单曲', '未知专辑')
 GROUP BY a.album_id
 ORDER BY listened_ms DESC, event_count DESC, a.normalized_title
 LIMIT 1
''', yearArgs);

    final eventTimes = await db.rawQuery('''
SELECT e.started_at
  FROM play_events e
 WHERE $validYearEvent
 ORDER BY e.started_at
''', yearArgs);
    final listeningPeriod = eventTimes.length < 10
        ? null
        : _mostFrequentPeriod(
            eventTimes.map((row) => row['started_at']! as int),
          );

    final likedRows = await db.rawQuery('''
SELECT COUNT(*) AS count
  FROM track_preferences pref
  JOIN tracks t ON t.track_id = pref.track_id
 WHERE pref.liked = 1
   AND t.deleted_at IS NULL
   AND ${LibraryRepository.availableTrackSql('t')}
''');
    final playlistRows = await db.rawQuery(
      "SELECT COUNT(*) AS count FROM playlists WHERE type = 'user'",
    );
    final firstEventRows = await db.rawQuery('''
SELECT MIN(started_at) AS first_at
  FROM play_events
 WHERE listened_duration_ms > 0
''');
    final firstEventAt = firstEventRows.single['first_at'] as int?;
    final firstTrackRows = firstEventAt == null
        ? await db.rawQuery(
            'SELECT MIN(added_at) AS first_at FROM tracks '
            'WHERE deleted_at IS NULL',
          )
        : const <Map<String, Object?>>[];
    final recordStartedMs =
        firstEventAt ??
        (firstTrackRows.isEmpty
            ? null
            : firstTrackRows.single['first_at'] as int?);

    return MusicArchiveSnapshot(
      year: now.year,
      validEventCount: _int(totals['event_count']),
      distinctTrackCount: _int(totals['track_count']),
      listenedDurationMs: _int(totals['listened_ms']),
      likedCount: _int(likedRows.single['count']),
      playlistCount: _int(playlistRows.single['count']),
      topTrack: topTrackId == null
          ? null
          : await _libraryRepository.libraryTrackById(topTrackId),
      topArtist: topArtistRows.isEmpty
          ? null
          : topArtistRows.single['display_name'] as String?,
      topAlbum: topAlbumRows.isEmpty
          ? null
          : topAlbumRows.single['title'] as String?,
      listeningPeriod: listeningPeriod,
      recordStartedAt: recordStartedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(recordStartedMs),
    );
  }

  String _mostFrequentPeriod(Iterable<int> timestamps) {
    final counts = <String, int>{};
    for (final timestamp in timestamps) {
      final hour = DateTime.fromMillisecondsSinceEpoch(timestamp).hour;
      final label = switch (hour) {
        >= 22 => '晚上 10 点以后',
        < 6 => '深夜',
        < 12 => '上午',
        < 18 => '下午',
        _ => '晚上',
      };
      counts[label] = (counts[label] ?? 0) + 1;
    }
    return counts.entries.reduce((left, right) {
      if (right.value > left.value) return right;
      return left;
    }).key;
  }

  int _int(Object? value) => ((value as num?) ?? 0).toInt();
}
