import 'dart:math';

import '../models/v4/library_browsing.dart';
import '../models/v4/library_track.dart';
import '../models/v4/recommendation_behavior.dart';

/// Generalises reliable track feedback to the same primary artist and album.
///
/// This lets an unheard song by a repeatedly accepted artist receive a modest
/// lift without turning artist affinity into a hard filter.
class RecommendationAffinityProfile {
  RecommendationAffinityProfile._(this._artists, this._albums);

  final Map<String, _AffinityEvidence> _artists;
  final Map<String, _AffinityEvidence> _albums;

  factory RecommendationAffinityProfile.fromLibrary(
    Iterable<LibraryTrack> library,
    Map<String, RecommendationBehaviorSignal> behaviorSignals,
  ) {
    final artists = <String, _AffinityEvidence>{};
    final albums = <String, _AffinityEvidence>{};
    for (final track in library) {
      final signal = behaviorSignals[track.track.trackId];
      final accepted =
          signal?.acceptedCount ?? min(2, track.stats.completedCount);
      final directAccepted = signal?.directAcceptedCount ?? 0;
      final passiveAccepted = max(0, accepted - directAccepted);
      final rejected =
          signal?.negativeEvidence ?? min(2, track.stats.skipCount).toDouble();
      final behaviorPositive = signal == null || signal.hasReliableAcceptance
          ? passiveAccepted * 0.35 + directAccepted * 1.6
          : directAccepted * 0.8;
      final positive =
          behaviorPositive +
          (track.preference.liked ? 4.0 : 0.0) +
          (signal?.matchingTimeAcceptedCount ?? 0) * 0.12;

      final artist = _artistKey(track);
      if (artist.isNotEmpty) {
        artists
            .putIfAbsent(artist, _AffinityEvidence.new)
            .add(positive: positive, rejected: rejected);
      }
      final album = _albumKey(track);
      if (album.isNotEmpty) {
        albums
            .putIfAbsent(album, _AffinityEvidence.new)
            .add(positive: positive, rejected: rejected);
      }
    }
    return RecommendationAffinityProfile._(artists, albums);
  }

  double multiplierFor(LibraryTrack track) {
    final artist =
        _artists[_artistKey(track)]?.multiplier(maximum: 1.65, minimum: 0.62) ??
        1.0;
    final album =
        _albums[_albumKey(track)]?.multiplier(maximum: 1.28, minimum: 0.78) ??
        1.0;
    return (artist * album).clamp(0.45, 2.1).toDouble();
  }

  static String _artistKey(LibraryTrack track) =>
      primaryArtistName(track.track.artistDisplay).trim().toLowerCase();

  static String _albumKey(LibraryTrack track) {
    final album = track.track.albumDisplay.trim().toLowerCase();
    if (album.isEmpty || album == '未知专辑' || album == '单曲') return '';
    return '${_artistKey(track)}\u0000$album';
  }
}

class _AffinityEvidence {
  double positive = 0;
  double rejected = 0;

  void add({required double positive, required double rejected}) {
    this.positive += positive;
    this.rejected += rejected;
  }

  double multiplier({required double maximum, required double minimum}) {
    final observations = positive + rejected;
    if (observations <= 0) return 1;
    final confidence = 1 - exp(-observations / 4);
    final acceptance = positive / (positive + rejected * 1.35);
    final direction = (acceptance - 0.5) * 2;
    final range = direction >= 0 ? maximum - 1 : 1 - minimum;
    return 1 + direction * confidence * range;
  }
}
