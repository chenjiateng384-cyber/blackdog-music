import 'library_track.dart';

/// A deterministic view of data the V4 home page can already explain.
///
/// This is deliberately not a recommendation algorithm. It only combines
/// existing likes, listening history and recently added music without scores,
/// online data or a recommendation model. "Today" is a stable daily selection
/// from the local library, so playback updates do not reshuffle the section.
class HomeExperience {
  const HomeExperience({
    required this.quickStartTracks,
    required this.todayTracks,
    required this.frequentArtists,
  });

  final List<LibraryTrack> quickStartTracks;
  final List<LibraryTrack> todayTracks;
  final List<ArtistLibrarySummary> frequentArtists;

  factory HomeExperience.compose({
    required List<LibraryTrack> liked,
    required List<LibraryTrack> mostPlayed,
    required List<LibraryTrack> recentlyPlayed,
    required List<LibraryTrack> recentlyAdded,
    required List<ArtistLibrarySummary> artists,
    List<LibraryTrack> allTracks = const [],
    DateTime? day,
  }) {
    final quickStart = _roundRobin([
      mostPlayed,
      liked,
      recentlyPlayed,
      recentlyAdded,
    ], limit: 24);
    final today = allTracks.isEmpty
        ? _roundRobin([
            recentlyPlayed,
            liked,
            mostPlayed,
            recentlyAdded,
          ], limit: 30)
        : _dailyLocalSelection(allTracks, day ?? DateTime.now(), limit: 30);
    return HomeExperience(
      quickStartTracks: quickStart,
      todayTracks: today,
      frequentArtists: _frequentArtists(artists, [
        ...mostPlayed,
        ...recentlyPlayed,
      ]),
    );
  }

  static List<LibraryTrack> _dailyLocalSelection(
    List<LibraryTrack> tracks,
    DateTime day, {
    required int limit,
  }) {
    final unique = <String, LibraryTrack>{};
    for (final track in tracks) {
      if (!track.isPlayable || track.preference.recommendationExcluded) {
        continue;
      }
      unique.putIfAbsent(track.track.trackId, () => track);
    }
    final dateKey =
        '${day.year.toString().padLeft(4, '0')}'
        '${day.month.toString().padLeft(2, '0')}'
        '${day.day.toString().padLeft(2, '0')}';
    final result = unique.values.toList(growable: false)
      ..sort((left, right) {
        final leftRank = _stableDailyRank(dateKey, left.track.trackId);
        final rightRank = _stableDailyRank(dateKey, right.track.trackId);
        final rankOrder = leftRank.compareTo(rightRank);
        return rankOrder != 0
            ? rankOrder
            : left.track.trackId.compareTo(right.track.trackId);
      });
    return List.unmodifiable(result.take(limit));
  }

  static int _stableDailyRank(String dateKey, String trackId) {
    var hash = 0x811C9DC5;
    for (final unit in '$dateKey|$trackId'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  static List<LibraryTrack> _roundRobin(
    List<List<LibraryTrack>> sources, {
    required int limit,
  }) {
    final result = <LibraryTrack>[];
    final seen = <String>{};
    final maxLength = sources.fold<int>(
      0,
      (largest, source) => source.length > largest ? source.length : largest,
    );
    for (var index = 0; index < maxLength && result.length < limit; index++) {
      for (final source in sources) {
        if (index >= source.length) continue;
        final track = source[index];
        if (!track.isPlayable || track.preference.recommendationExcluded) {
          continue;
        }
        if (seen.add(track.track.trackId)) result.add(track);
        if (result.length == limit) break;
      }
    }
    return List.unmodifiable(result);
  }

  static List<ArtistLibrarySummary> _frequentArtists(
    List<ArtistLibrarySummary> artists,
    List<LibraryTrack> listeningOrder,
  ) {
    final byName = {
      for (final summary in artists)
        _normalize(summary.artist.displayName): summary,
    };
    final result = <ArtistLibrarySummary>[];
    final seen = <String>{};
    for (final track in listeningOrder) {
      if (track.stats.playCount <= 0 && track.stats.lastPlayedAt == null) {
        continue;
      }
      final key = _normalize(track.track.artistDisplay);
      final summary = byName[key];
      if (summary != null && seen.add(summary.artist.artistId)) {
        result.add(summary);
      }
      if (result.length == 8) break;
    }
    return List.unmodifiable(result);
  }

  static String _normalize(String value) => value.trim().toLowerCase();
}
