import 'dart:math';

import 'library_track.dart';
import '../../utils/localized_text_sort.dart';

enum LibraryBrowseSort {
  frequent,
  title,
  year,
  artist,
  album,
  recentlyAdded,
  playCount,
}

extension AlbumBrowsing on AlbumLibrarySummary {
  /// The album wall represents collections the user intentionally owns.
  /// A lone online-style ALBUM tag should not turn every loose single into an
  /// album card. This is deliberately a display rule and does not mutate data.
  bool get isBrowsableCollection {
    if (_isPlaceholderAlbumTitle(album.title)) return false;
    // A single file carrying an ALBUM tag, track number or cover is still a
    // loose single in a personal library. Artwork and TRACKNUMBER are common
    // on downloaded singles, so neither is sufficient evidence of an
    // intentionally collected album. Keep the metadata on the song, but do
    // not create an album-wall entry until the collection has at least three
    // tracks. Two-song releases remain available as songs and search metadata.
    if (trackCount < 3) return false;
    return !onlyTrackTitleMatchesAlbum;
  }
}

bool _isPlaceholderAlbumTitle(String value) {
  final normalized = value.trim().toLowerCase().replaceAll(
    RegExp(r'[\s_.\-/—·（）()\[\]]+'),
    '',
  );
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
        'na',
      }.contains(normalized);
}

/// Returns the owner of a collaboration credit while leaving the original
/// [Track.artistDisplay] untouched for song rows and details.
String primaryArtistName(String credit) {
  final value = credit.trim();
  if (value.isEmpty) return value;
  final feature = RegExp(
    r'\s+(?:feat(?:uring)?\.?|ft\.?)\s+',
    caseSensitive: false,
  ).firstMatch(value);
  if (feature != null) return value.substring(0, feature.start).trim();

  final ampersand = RegExp(r'\s*(?:&|＆)\s*').firstMatch(value);
  if (ampersand != null) return value.substring(0, ampersand.start).trim();

  final slash = value.indexOf('/');
  if (slash > 0) {
    final left = value.substring(0, slash).trim();
    final right = value.substring(slash + 1).trim();
    final compactLatinName = RegExp(r'^[A-Za-z]+/[A-Za-z]+$').hasMatch(value);
    if (left.isNotEmpty && right.isNotEmpty && !compactLatinName) return left;
  }
  return value;
}

List<AlbumLibrarySummary> browsableAlbums(
  Iterable<AlbumLibrarySummary> albums,
) => albums
    .where((album) => album.isBrowsableCollection)
    .toList(growable: false);

List<ArtistLibrarySummary> sortLibraryArtists(
  Iterable<ArtistLibrarySummary> artists,
) {
  final result = artists.toList();
  result.sort((left, right) {
    final byName = compareLocalizedText(
      left.artist.displayName,
      right.artist.displayName,
    );
    return byName != 0
        ? byName
        : left.artist.artistId.compareTo(right.artist.artistId);
  });
  return List.unmodifiable(result);
}

List<AlbumLibrarySummary> sortLibraryAlbums(
  Iterable<AlbumLibrarySummary> albums,
) {
  final result = albums.toList();
  result.sort((left, right) {
    final byTitle = compareLocalizedText(left.album.title, right.album.title);
    if (byTitle != 0) return byTitle;
    final byYear = (left.album.year ?? 9999).compareTo(
      right.album.year ?? 9999,
    );
    return byYear != 0
        ? byYear
        : left.album.albumId.compareTo(right.album.albumId);
  });
  return List.unmodifiable(result);
}

List<AlbumLibrarySummary> sortLibraryAlbumsByListening(
  Iterable<AlbumLibrarySummary> albums,
  Iterable<LibraryTrack> tracks,
) {
  final byAlbum = <String, List<LibraryTrack>>{};
  for (final track in tracks) {
    final albumId = track.track.albumId;
    if (albumId != null) {
      byAlbum.putIfAbsent(albumId, () => []).add(track);
    }
  }
  final result = albums.toList();
  final scores = <String, double>{
    for (final album in result)
      album.album.albumId: _albumListeningScore(
        byAlbum[album.album.albumId] ?? const [],
      ),
  };
  result.sort((left, right) {
    final byListening = (scores[right.album.albumId] ?? 0).compareTo(
      scores[left.album.albumId] ?? 0,
    );
    if (byListening != 0) return byListening;
    return compareLocalizedText(left.album.title, right.album.title);
  });
  return List.unmodifiable(result);
}

List<AlbumLibrarySummary> browsableAlbumsForArtist(
  Iterable<AlbumLibrarySummary> albums,
  String artistId,
) => browsableAlbumsForArtistIds(albums, [artistId]);

List<AlbumLibrarySummary> browsableAlbumsForArtistIds(
  Iterable<AlbumLibrarySummary> albums,
  Iterable<String> artistIds,
) {
  final ids = artistIds.toSet();
  return albums
      .where(
        (album) =>
            album.isBrowsableCollection &&
            ids.contains(album.album.albumArtistId),
      )
      .toList(growable: false);
}

List<LibraryTrack> standaloneTracks(
  Iterable<LibraryTrack> tracks,
  Iterable<AlbumLibrarySummary> displayedAlbums,
) {
  final displayedIds = displayedAlbums
      .map((album) => album.album.albumId)
      .toSet();
  return tracks
      .where(
        (track) =>
            track.track.albumId == null ||
            !displayedIds.contains(track.track.albumId),
      )
      .toList(growable: false);
}

List<LibraryTrack> sortLibraryTracks(
  Iterable<LibraryTrack> tracks,
  LibraryBrowseSort sort,
) {
  final result = tracks.toList();
  result.sort((left, right) {
    final comparison = switch (sort) {
      LibraryBrowseSort.frequent => _chain([
        _listeningScore(right).compareTo(_listeningScore(left)),
        _recentlyPlayed(right).compareTo(_recentlyPlayed(left)),
        right.track.addedAt.compareTo(left.track.addedAt),
        _text(left.track.title, right.track.title),
      ]),
      LibraryBrowseSort.title => _text(left.track.title, right.track.title),
      LibraryBrowseSort.year => _chain([
        _number(left.track.year, right.track.year),
        _text(left.track.title, right.track.title),
      ]),
      LibraryBrowseSort.artist => _chain([
        _text(left.track.artistDisplay, right.track.artistDisplay),
        _text(left.track.title, right.track.title),
      ]),
      LibraryBrowseSort.album => _chain([
        _text(left.track.albumDisplay, right.track.albumDisplay),
        _number(left.track.discNumber, right.track.discNumber),
        _number(left.track.trackNumber, right.track.trackNumber),
        _text(left.track.title, right.track.title),
      ]),
      LibraryBrowseSort.recentlyAdded => _chain([
        right.track.addedAt.compareTo(left.track.addedAt),
        _text(left.track.title, right.track.title),
      ]),
      LibraryBrowseSort.playCount => _chain([
        right.stats.playCount.compareTo(left.stats.playCount),
        _text(left.track.title, right.track.title),
      ]),
    };
    if (comparison != 0) return comparison;
    return left.track.trackId.compareTo(right.track.trackId);
  });
  return List.unmodifiable(result);
}

double _listeningScore(LibraryTrack track) {
  final stats = track.stats;
  final observations = stats.completedCount + stats.skipCount;
  final skipRate = observations == 0 ? 0.0 : stats.skipCount / observations;
  final completed = log(stats.completedCount + 1) * 4.0;
  final manuallySelected = log(stats.manuallySelectedCount + 1) * 5.0;
  final durationSessions = track.track.durationMs <= 0
      ? 0.0
      : (stats.totalPlayDurationMs / track.track.durationMs).clamp(0, 12);
  return (track.preference.liked ? 7.0 : 0.0) +
      completed +
      manuallySelected +
      durationSessions * 0.35 -
      skipRate * 5.0;
}

double _albumListeningScore(List<LibraryTrack> tracks) {
  if (tracks.isEmpty) return 0;
  final scores = tracks.map(_listeningScore).toList()
    ..sort((a, b) => b.compareTo(a));
  return scores.take(3).fold(0.0, (sum, score) => sum + score);
}

int _recentlyPlayed(LibraryTrack track) =>
    track.stats.lastPlayedAt?.millisecondsSinceEpoch ?? 0;

List<LibraryTrack> sortAlbumTracks(Iterable<LibraryTrack> tracks) {
  final result = tracks.toList();
  result.sort(
    (left, right) => _chain([
      _number(left.track.discNumber, right.track.discNumber),
      _number(left.track.trackNumber, right.track.trackNumber),
      _text(left.track.title, right.track.title),
      left.track.trackId.compareTo(right.track.trackId),
    ]),
  );
  return List.unmodifiable(result);
}

int _text(String left, String right) => compareLocalizedText(left, right);

int _number(int? left, int? right) => (left ?? 9999).compareTo(right ?? 9999);

int _chain(Iterable<int> values) =>
    values.firstWhere((value) => value != 0, orElse: () => 0);
