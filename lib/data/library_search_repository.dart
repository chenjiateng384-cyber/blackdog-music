import '../models/v4/library_search.dart';
import '../models/v4/library_browsing.dart';
import '../models/v4/library_track.dart';
import '../services/library_database.dart';
import 'library_repository.dart';

class LibrarySearchRepository {
  const LibrarySearchRepository(this._database, this._library);

  final LibraryDatabase _database;
  final LibraryRepository _library;

  Future<LibrarySearchResults> search(
    String query, {
    int limitPerType = 30,
  }) async {
    final term = query.trim();
    if (term.isEmpty || limitPerType <= 0) {
      return LibrarySearchResults.empty(term);
    }
    final normalized = term.toLowerCase();
    final contains = '%${_escapeLike(normalized)}%';
    final db = await _database.database;

    final trackRows = await db.rawQuery(
      '''
SELECT t.track_id,
       CASE WHEN LOWER(t.title) = ? THEN 0 ELSE 300 END AS score
FROM tracks t
WHERE t.deleted_at IS NULL
  AND (LOWER(t.title) LIKE ? ESCAPE '\\'
       OR LOWER(t.artist_display) LIKE ? ESCAPE '\\'
       OR LOWER(t.album_display) LIKE ? ESCAPE '\\')
  AND ${LibraryRepository.availableTrackSql('t')}
ORDER BY score, LENGTH(t.title), LOWER(t.title)
LIMIT ?
''',
      [normalized, contains, contains, contains, limitPerType],
    );
    final trackIds = trackRows
        .map((row) => row['track_id']! as String)
        .toList(growable: false);
    final tracks = await _library.tracksByIds(trackIds);
    final trackById = {for (final item in tracks) item.track.trackId: item};
    final orderedTracks = trackIds
        .map((id) => trackById[id])
        .whereType<LibraryTrack>()
        .toList(growable: false);

    // Search the same primary-artist projection used by the library page.
    // Raw credits such as “周杰伦 & 杨瑞代” stay on the Track, but must not
    // reappear as a second artist beside the merged “周杰伦” collection.
    final artistScores = <String, int>{};
    final artists =
        (await _library.artists())
            .where((summary) {
              final name = summary.artist.displayName.toLowerCase();
              final normalizedName = summary.artist.normalizedName
                  .toLowerCase();
              final score = name == normalized || normalizedName == normalized
                  ? 100
                  : name.startsWith(normalized) ||
                        normalizedName.startsWith(normalized)
                  ? 110
                  : name.contains(normalized) ||
                        normalizedName.contains(normalized)
                  ? 120
                  : null;
              if (score == null) return false;
              artistScores[summary.artist.artistId] = score;
              return true;
            })
            .toList(growable: true)
          ..sort((left, right) {
            final byScore = artistScores[left.artist.artistId]!.compareTo(
              artistScores[right.artist.artistId]!,
            );
            if (byScore != 0) return byScore;
            final byLength = left.artist.displayName.length.compareTo(
              right.artist.displayName.length,
            );
            if (byLength != 0) return byLength;
            return left.artist.normalizedName.compareTo(
              right.artist.normalizedName,
            );
          });
    if (artists.length > limitPerType) {
      artists.removeRange(limitPerType, artists.length);
    }

    final albumRows = await db.rawQuery(
      '''
SELECT a.album_id, a.title, a.normalized_title, a.album_artist_id,
       a.year, a.album_type, COUNT(DISTINCT t.track_id) AS track_count,
       CASE
         WHEN LOWER(a.title) = ? OR a.normalized_title = ? THEN 200
         WHEN LOWER(a.title) LIKE ? ESCAPE '\\' THEN 210
         ELSE 220
       END AS score
FROM albums a
JOIN tracks t ON t.album_id = a.album_id AND t.deleted_at IS NULL
WHERE (LOWER(a.title) LIKE ? ESCAPE '\\'
       OR a.normalized_title LIKE ? ESCAPE '\\')
  AND ${LibraryRepository.availableTrackSql('t')}
GROUP BY a.album_id, a.title, a.normalized_title, a.album_artist_id,
         a.year, a.album_type
ORDER BY score, LENGTH(a.title), a.normalized_title
LIMIT ?
''',
      [
        normalized,
        normalized,
        '${_escapeLike(normalized)}%',
        contains,
        contains,
        limitPerType,
      ],
    );
    final albumIds = albumRows
        .map((row) => row['album_id']! as String)
        .toList(growable: false);
    final albumScores = {
      for (final row in albumRows)
        row['album_id']! as String: (row['score']! as num).toInt(),
    };
    final albums = (await _library.albumsByIds(albumIds))
        .where((album) => album.isBrowsableCollection)
        .take(limitPerType)
        .toList(growable: false);

    final allFolders = await _library.folders(recursive: true);
    final folderScores = <LibraryFolder, int>{};
    for (final folder in allFolders) {
      final name = folder.name.toLowerCase();
      final path = folder.relativePath.toLowerCase();
      final score = name == normalized
          ? 250
          : name.startsWith(normalized)
          ? 260
          : name.contains(normalized) || path.contains(normalized)
          ? 270
          : null;
      if (score != null) folderScores[folder] = score;
    }
    final folders = folderScores.keys.toList(growable: true)
      ..sort((left, right) {
        final byScore = folderScores[left]!.compareTo(folderScores[right]!);
        if (byScore != 0) return byScore;
        return left.relativePath.compareTo(right.relativePath);
      });
    final limitedFolders = folders.take(limitPerType).toList(growable: false);

    final ordered =
        <RankedLibrarySearchResult>[
          for (var index = 0; index < orderedTracks.length; index++)
            RankedLibrarySearchResult(
              type: LibrarySearchResultType.track,
              score: (trackRows[index]['score']! as num).toInt(),
              label: orderedTracks[index].track.title,
              stableKey: orderedTracks[index].track.trackId,
              track: orderedTracks[index],
            ),
          for (var index = 0; index < artists.length; index++)
            RankedLibrarySearchResult(
              type: LibrarySearchResultType.artist,
              score: artistScores[artists[index].artist.artistId]!,
              label: artists[index].artist.displayName,
              stableKey: artists[index].artist.artistId,
              artist: artists[index],
            ),
          for (var index = 0; index < albums.length; index++)
            RankedLibrarySearchResult(
              type: LibrarySearchResultType.album,
              score: albumScores[albums[index].album.albumId]!,
              label: albums[index].album.title,
              stableKey: albums[index].album.albumId,
              album: albums[index],
            ),
          for (final folder in limitedFolders)
            RankedLibrarySearchResult(
              type: LibrarySearchResultType.folder,
              score: folderScores[folder]!,
              label: folder.name,
              stableKey: '${folder.scanRootId}:${folder.relativePath}',
              folder: folder,
            ),
        ]..sort((left, right) {
          final byScore = left.score.compareTo(right.score);
          if (byScore != 0) return byScore;
          return left.label.toLowerCase().compareTo(right.label.toLowerCase());
        });

    return LibrarySearchResults(
      query: term,
      tracks: orderedTracks,
      artists: artists,
      albums: albums,
      folders: limitedFolders,
      ordered: List.unmodifiable(ordered),
    );
  }

  static String _escapeLike(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
}
