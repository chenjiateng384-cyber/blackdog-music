import 'dart:math';

import '../models/v4/library_track.dart';
import '../models/v4/listening_preference.dart';
import '../models/v4/recommendation_behavior.dart';
import '../models/v4/library_browsing.dart';
import 'recommendation_eligibility.dart';
import 'recommendation_affinity.dart';

/// Builds the short rolling queue used only by the home "随心听" entry.
class HomeQuickStartRadio {
  HomeQuickStartRadio({Random? random}) : _random = random ?? Random();

  static const int initialTrackCount = 12;
  static const int refillThreshold = 7;
  static const int refillTrackCount = 8;

  final Random _random;
  final List<String> _recentSelections = [];

  List<LibraryTrack> select({
    required List<LibraryTrack> library,
    required int count,
    required DateTime now,
    ListeningPreference preference = const ListeningPreference(),
    Set<String> excludingTrackIds = const {},
    Set<String> deEmphasizedTrackIds = const {},
    String? avoidFirstTrackId,
    List<LibraryTrack> previousTracks = const [],
    Map<String, RecommendationBehaviorSignal> behaviorSignals = const {},
  }) {
    if (count <= 0) return const [];
    final candidates = <String, LibraryTrack>{
      for (final track in RecommendationEligibility.filter(
        library,
        excludingTrackIds: excludingTrackIds,
      ))
        track.track.trackId: track,
    };
    if (candidates.isEmpty) return const [];

    final shares = _shares(preference.familiarity);
    final unsuppressed = candidates.values
        .where(
          (track) =>
              !(_signal(
                    track,
                    behaviorSignals,
                  )?.isTemporarilySuppressedAt(now) ??
                  false),
        )
        .toList(growable: true);
    final remaining = unsuppressed.isEmpty
        ? candidates.values.toList(growable: true)
        : unsuppressed;
    final affinity = RecommendationAffinityProfile.fromLibrary(
      candidates.values,
      behaviorSignals,
    );
    final target = min(count, remaining.length);
    // Do not round both trusted buckets up and squeeze exploration down to
    // a single token slot in a 12-track queue.
    final desiredFamiliarCount = target < 4
        ? (target * shares.familiar).round()
        : (target * shares.familiar).floor();
    final desiredRediscoveryCount = (target * shares.rediscovery).round();
    final desiredExplorationCount =
        target - desiredFamiliarCount - desiredRediscoveryCount;
    final availableFamiliar = remaining
        .where(
          (track) =>
              _groupFor(track, now, behaviorSignals: behaviorSignals) ==
              _RadioGroup.familiar,
        )
        .length;
    final availableRediscovery = remaining
        .where(
          (track) =>
              _groupFor(track, now, behaviorSignals: behaviorSignals) ==
              _RadioGroup.rediscovery,
        )
        .length;
    final availableExploration =
        remaining.length - availableFamiliar - availableRediscovery;
    var familiarCount = min(desiredFamiliarCount, availableFamiliar);
    var rediscoveryCount = min(desiredRediscoveryCount, availableRediscovery);
    var explorationCount = min(desiredExplorationCount, availableExploration);
    var unfilled = target - familiarCount - rediscoveryCount - explorationCount;
    var extra = min(unfilled, availableFamiliar - familiarCount);
    familiarCount += extra;
    unfilled -= extra;
    extra = min(unfilled, availableRediscovery - rediscoveryCount);
    rediscoveryCount += extra;
    unfilled -= extra;
    explorationCount += min(unfilled, availableExploration - explorationCount);
    if (availableFamiliar > 1 &&
        familiarCount == availableFamiliar &&
        (rediscoveryCount < availableRediscovery ||
            explorationCount < availableExploration)) {
      familiarCount -= 1;
      if (rediscoveryCount < availableRediscovery) {
        rediscoveryCount += 1;
      } else {
        explorationCount += 1;
      }
    }
    if (availableRediscovery > 1 &&
        rediscoveryCount == availableRediscovery &&
        explorationCount < availableExploration) {
      rediscoveryCount -= 1;
      explorationCount += 1;
    }
    if (availableFamiliar == 1 &&
        familiarCount == 1 &&
        _random.nextDouble() < 0.25 &&
        (rediscoveryCount < availableRediscovery ||
            explorationCount < availableExploration)) {
      familiarCount = 0;
      if (rediscoveryCount < availableRediscovery) {
        rediscoveryCount += 1;
      } else {
        explorationCount += 1;
      }
    }
    final availableTrusted = availableFamiliar + availableRediscovery;
    if (availableTrusted > 1 &&
        familiarCount + rediscoveryCount == availableTrusted &&
        explorationCount < availableExploration) {
      if (rediscoveryCount > 0) {
        rediscoveryCount -= 1;
      } else {
        familiarCount -= 1;
      }
      explorationCount += 1;
    }
    final schedule = <_RadioGroup>[
      ...List.filled(familiarCount, _RadioGroup.familiar),
      ...List.filled(rediscoveryCount, _RadioGroup.rediscovery),
      ...List.filled(explorationCount, _RadioGroup.exploration),
    ];
    schedule.shuffle(_random);

    final selected = <LibraryTrack>[];
    for (final group in schedule) {
      final preferred = remaining
          .where(
            (track) =>
                _groupFor(track, now, behaviorSignals: behaviorSignals) ==
                group,
          )
          .toList(growable: false);
      final picked = _pick(
        preferred.isEmpty ? remaining : preferred,
        allRemaining: remaining,
        selected: selected,
        previousTracks: previousTracks,
        now: now,
        avoidFirstTrackId: avoidFirstTrackId,
        behaviorSignals: behaviorSignals,
        affinity: affinity,
        deEmphasizedTrackIds: deEmphasizedTrackIds,
      );
      if (picked == null) break;
      selected.add(picked);
      remaining.removeWhere(
        (track) => track.track.trackId == picked.track.trackId,
      );
    }
    _recentSelections.addAll(selected.map((track) => track.track.trackId));
    if (_recentSelections.length > 48) {
      _recentSelections.removeRange(0, _recentSelections.length - 48);
    }
    return List.unmodifiable(selected);
  }

  LibraryTrack? _pick(
    List<LibraryTrack> preferred, {
    required List<LibraryTrack> allRemaining,
    required List<LibraryTrack> selected,
    required List<LibraryTrack> previousTracks,
    required DateTime now,
    required String? avoidFirstTrackId,
    required Map<String, RecommendationBehaviorSignal> behaviorSignals,
    required RecommendationAffinityProfile affinity,
    required Set<String> deEmphasizedTrackIds,
  }) {
    if (allRemaining.isEmpty) return null;
    var pool = preferred.isEmpty ? allRemaining : preferred;
    final history = [...previousTracks, ...selected];

    if (selected.isEmpty && avoidFirstTrackId != null) {
      final alternatives = pool
          .where((track) => track.track.trackId != avoidFirstTrackId)
          .toList(growable: false);
      if (alternatives.isNotEmpty) {
        pool = alternatives;
      } else {
        final globalAlternatives = allRemaining
            .where((track) => track.track.trackId != avoidFirstTrackId)
            .toList(growable: false);
        if (globalAlternatives.isNotEmpty) pool = globalAlternatives;
      }
    }

    if (history.length >= 2) {
      final lastTwo = history.skip(history.length - 2).toList();
      final artist = _artistKey(lastTwo.last);
      final album = _albumKey(lastTwo.last);
      final blockedArtist =
          artist.isNotEmpty &&
              lastTwo.every((item) => _artistKey(item) == artist)
          ? artist
          : null;
      final blockedAlbum =
          album.isNotEmpty && lastTwo.every((item) => _albumKey(item) == album)
          ? album
          : null;
      if (blockedArtist != null || blockedAlbum != null) {
        bool allowed(LibraryTrack track) =>
            (blockedArtist == null || _artistKey(track) != blockedArtist) &&
            (blockedAlbum == null || _albumKey(track) != blockedAlbum);
        final preferredAlternatives = pool
            .where(allowed)
            .toList(growable: false);
        final globalAlternatives = preferredAlternatives.isNotEmpty
            ? preferredAlternatives
            : allRemaining.where(allowed).toList(growable: false);
        if (globalAlternatives.isNotEmpty) pool = globalAlternatives;
      }
    }

    final weights = <double>[];
    var total = 0.0;
    for (final track in pool) {
      final weight = _weight(
        track,
        history: history,
        now: now,
        behaviorSignals: behaviorSignals,
        affinity: affinity,
        deEmphasizedTrackIds: deEmphasizedTrackIds,
      );
      weights.add(weight);
      total += weight;
    }
    var cursor = _random.nextDouble() * total;
    for (var index = 0; index < pool.length; index++) {
      cursor -= weights[index];
      if (cursor <= 0) return pool[index];
    }
    return pool.last;
  }

  double _weight(
    LibraryTrack track, {
    required List<LibraryTrack> history,
    required DateTime now,
    required Map<String, RecommendationBehaviorSignal> behaviorSignals,
    required RecommendationAffinityProfile affinity,
    required Set<String> deEmphasizedTrackIds,
  }) {
    final stats = track.stats;
    final signal = _signal(track, behaviorSignals);
    var weight = 1.0;
    if (track.preference.liked) weight += 4.5;
    if (signal != null) {
      weight += min(3.0, log(signal.acceptedCount + 1) * 1.25);
      weight += min(1.8, log(signal.directAcceptedCount + 1) * 1.1);
      weight += min(0.4, signal.matchingTimeAcceptedCount * 0.08);
      final observations = signal.acceptedCount + signal.negativeEvidence;
      if (observations > 0) {
        weight *= 1 - (signal.negativeEvidence / observations) * 0.72;
      }
      weight *= pow(0.72, min(4, signal.recentExposureCount));
    } else {
      final observations = stats.completedCount + stats.skipCount;
      final completionRate = observations == 0
          ? 0.0
          : stats.completedCount / observations;
      final skipRate = observations == 0 ? 0.0 : stats.skipCount / observations;
      weight += completionRate.clamp(0, 1) * 2.0;
      weight *= (1 - skipRate.clamp(0, 0.8) * 0.75);
    }

    final lastPlayedAt = stats.lastPlayedAt ?? signal?.lastAcceptedAt;
    if (lastPlayedAt != null) {
      final days = max(0, now.difference(lastPlayedAt).inDays);
      weight *= switch (days) {
        0 => 0.14,
        <= 2 => 0.3,
        <= 6 => 0.55,
        <= 13 => 0.78,
        >= 45 => 1.35,
        _ => 1.0,
      };
    }
    final lastSkippedAt = stats.lastSkippedAt;
    if (lastSkippedAt != null &&
        max(0, now.difference(lastSkippedAt).inDays) <= 7) {
      weight *= 0.45;
    }

    if (history.isNotEmpty) {
      final last = history.last;
      final artist = _artistKey(track);
      if (artist.isNotEmpty && artist == _artistKey(last)) weight *= 0.2;
      final album = _albumKey(track);
      if (album.isNotEmpty && album == _albumKey(last)) weight *= 0.25;
    }
    if (history.length >= 2) {
      final recent = history.skip(history.length - 2);
      if (recent.any((item) => _artistKey(item) == _artistKey(track))) {
        weight *= 0.6;
      }
    }
    final affinityMultiplier = affinity.multiplierFor(track);
    weight *= signal?.hasDominantNegativeEvidence ?? false
        ? min(1.0, affinityMultiplier)
        : affinityMultiplier;
    final recentSelections = _recentSelections
        .where((id) => id == track.track.trackId)
        .length;
    weight *= pow(0.3, min(3, recentSelections));
    // Soft separation: keep taste anchors eligible, but prefer songs not
    // already displayed in today's exploration pool.
    if (deEmphasizedTrackIds.contains(track.track.trackId)) weight *= 0.18;
    final randomized = max(0.02, weight * (0.85 + _random.nextDouble() * 0.3));
    final timeContextMultiplier = signal == null
        ? 1.0
        : 1 + min(0.35, signal.matchingTimeAcceptedCount * 0.07);
    return pow(randomized, 0.75).toDouble() * timeContextMultiplier;
  }

  _RadioGroup _groupFor(
    LibraryTrack track,
    DateTime now, {
    required Map<String, RecommendationBehaviorSignal> behaviorSignals,
  }) {
    final stats = track.stats;
    final signal = _signal(track, behaviorSignals);
    final reliablyAccepted =
        track.preference.liked ||
        (signal?.hasReliableAcceptance ?? stats.completedCount >= 2);
    final lastPlayedAt = signal?.lastAcceptedAt ?? stats.lastPlayedAt;
    if (reliablyAccepted &&
        (lastPlayedAt == null || now.difference(lastPlayedAt).inDays >= 21)) {
      return _RadioGroup.rediscovery;
    }
    if (reliablyAccepted) {
      return _RadioGroup.familiar;
    }
    final lightlyAccepted =
        signal?.hasAcceptedPlayback ?? stats.completedCount > 0;
    if (lightlyAccepted && !(signal?.hasDominantNegativeEvidence ?? false)) {
      return _RadioGroup.rediscovery;
    }
    return _RadioGroup.exploration;
  }

  RecommendationBehaviorSignal? _signal(
    LibraryTrack track,
    Map<String, RecommendationBehaviorSignal> behaviorSignals,
  ) => behaviorSignals[track.track.trackId];

  _RadioShares _shares(FamiliarityPreference preference) =>
      switch (preference) {
        FamiliarityPreference.explore => const _RadioShares(0.56, 0.27),
        FamiliarityPreference.balanced => const _RadioShares(0.63, 0.24),
        FamiliarityPreference.familiar => const _RadioShares(0.68, 0.22),
      };

  String _artistKey(LibraryTrack track) {
    final artist = primaryArtistName(track.track.artistDisplay)
        .trim()
        .toLowerCase();
    return artist == '未知歌手' ? '' : artist;
  }

  String _albumKey(LibraryTrack track) {
    final value = track.track.albumDisplay.trim().toLowerCase();
    return value.isEmpty || value == '未知专辑' || value == '单曲'
        ? ''
        : '${_artistKey(track)}\u0000$value';
  }
}

enum _RadioGroup { familiar, rediscovery, exploration }

class _RadioShares {
  const _RadioShares(this.familiar, this.rediscovery);

  final double familiar;
  final double rediscovery;
}
