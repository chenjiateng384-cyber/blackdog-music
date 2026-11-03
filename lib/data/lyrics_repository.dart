import '../models/v4/library_entities.dart';
import '../services/library_database.dart';

class LyricsRepository {
  const LyricsRepository(this._database);

  final LibraryDatabase _database;

  Future<List<LyricsReference>> referencesForTrack(String trackId) async {
    final rows = await (await _database.database).query(
      'lyrics',
      where: 'track_id = ?',
      whereArgs: [trackId],
      orderBy: 'is_selected DESC, matched DESC, confidence DESC, created_at',
    );
    return rows.map(LyricsReference.fromMap).toList(growable: false);
  }

  Future<LyricsReference?> selectedForTrack(String trackId) async {
    final rows = await (await _database.database).query(
      'lyrics',
      where: 'track_id = ? AND is_selected = 1',
      whereArgs: [trackId],
      limit: 1,
    );
    return rows.isEmpty ? null : LyricsReference.fromMap(rows.single);
  }

  Future<String?> embeddedContent(String mediaFileId) async {
    final rows = await (await _database.database).query(
      'file_metadata_raw',
      columns: ['embedded_lyrics'],
      where: 'file_id = ?',
      whereArgs: [mediaFileId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['embedded_lyrics'] as String?;
  }

  Future<void> setSelected(String trackId, String lyricsId) async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      final exists = await transaction.query(
        'lyrics',
        columns: ['lyrics_id'],
        where: 'lyrics_id = ? AND track_id = ?',
        whereArgs: [lyricsId, trackId],
        limit: 1,
      );
      if (exists.isEmpty) throw StateError('歌词不属于指定 Track');
      await transaction.update(
        'lyrics',
        {'is_selected': 0},
        where: 'track_id = ?',
        whereArgs: [trackId],
      );
      await transaction.update(
        'lyrics',
        {'is_selected': 1},
        where: 'lyrics_id = ?',
        whereArgs: [lyricsId],
      );
    });
  }

  Future<void> setOffset(String lyricsId, int offsetMs) async {
    await (await _database.database).update(
      'lyrics',
      {'offset_ms': offsetMs},
      where: 'lyrics_id = ?',
      whereArgs: [lyricsId],
    );
  }
}
