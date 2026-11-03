import '../models/v4/library_track.dart';

/// Shared eligibility gate for Harmony's automatic local recommendations.
class RecommendationEligibility {
  static List<LibraryTrack> filter(
    Iterable<LibraryTrack> tracks, {
    Set<String> excludingTrackIds = const {},
  }) {
    final eligible = <String, LibraryTrack>{};
    for (final track in tracks) {
      final id = track.track.trackId;
      if (track.isPlayable &&
          !track.preference.recommendationExcluded &&
          !excludingTrackIds.contains(id)) {
        eligible.putIfAbsent(id, () => track);
      }
    }
    return eligible.values.toList(growable: false);
  }
}
