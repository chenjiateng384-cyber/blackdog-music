import 'dart:math';
import 'dart:isolate';

import '../models/v4/library_track.dart';
import '../models/v4/listening_preference.dart';
import '../models/v4/recommendation_behavior.dart';
import '../models/v4/library_browsing.dart';
import 'recommendation_eligibility.dart';
import 'recommendation_affinity.dart';

/// Builds the daily local exploration pool shown by "智能播放".
class HomeSmartPlayPool {
  static const int trackCount = 27;
  static const int algorithmVersion = 2;

  Future<List<LibraryTrack>> refreshAsync({
    required List<LibraryTrack> library,
    required List<LibraryTrack> current,
    required DateTime now,
    required String refreshKey,
    ListeningPreference preference = const ListeningPreference(),
    double behaviorStrength = 1,
    Map<String, RecommendationBehaviorSignal> behaviorSignals = const {},
    Set<String> viewedTrackIds = const {},
    Set<String> selectedTrackIds = const {},
    Set<String> visibleTrackIds = const {},
    String? currentTrackId,
  }) => Isolate.run(
    () => refresh(
      library: library,
      current: current,
      now: now,
      refreshKey: refreshKey,
      preference: preference,
      behaviorStrength: behaviorStrength,
      behaviorSignals: behaviorSignals,
      viewedTrackIds: viewedTrackIds,
      selectedTrackIds: selectedTrackIds,
      visibleTrackIds: visibleTrackIds,
      currentTrackId: currentTrackId,
    ),
  );

  List<LibraryTrack> refresh({
    required List<LibraryTrack> library,
    required List<LibraryTrack> current,
    required DateTime now,
    required String refreshKey,
    ListeningPreference preference = const ListeningPreference(),
    double behaviorStrength = 1,
    Map<String, RecommendationBehaviorSignal> behaviorSignals = const {},
    Set<String> viewedTrackIds = const {},
    Set<String> selectedTrackIds = const {},
    Set<String> visibleTrackIds = const {},
    String? currentTrackId,
  }) {
    final eligible = {
      for (final track in RecommendationEligibility.filter(library))
        if (!(behaviorSignals[track.track.trackId]?.isTemporarilySuppressedAt(
              now,
            ) ??
            false))
          track.track.trackId: track,
    };
    final seen = <String>{};
    final result = [
      for (final track in current)
        if (eligible.containsKey(track.track.trackId) &&
            seen.add(track.track.trackId))
          eligible[track.track.trackId]!,
    ];
    final fresh = build(
      library: eligible.values
          .where((track) => !seen.contains(track.track.trackId))
          .toList(),
      now: now,
      dayKey: refreshKey,
      preference: preference,
      behaviorStrength: behaviorStrength,
      behaviorSignals: behaviorSignals,
    );
    if (result.isEmpty) return fresh;
    final random = Random(_stableSeed(refreshKey));
    final positions = [
      for (var index = 0; index < result.length; index++)
        if (result[index].track.trackId != currentTrackId) index,
    ];
    final visiblePositions = {
      for (var index = 0; index < result.length; index++)
        if (visibleTrackIds.contains(result[index].track.trackId)) index,
    };
    int priority(int index) {
      final id = result[index].track.trackId;
      if (selectedTrackIds.contains(id)) return 3;
      if (visibleTrackIds.contains(id)) return 0;
      return viewedTrackIds.contains(id) ? 2 : 1;
    }

    final tieBreak = {
      for (final index in positions) index: random.nextDouble(),
    };
    positions.sort((a, b) {
      final order = priority(a).compareTo(priority(b));
      return order != 0 ? order : tieBreak[a]!.compareTo(tieBreak[b]!);
    });
    final count = min(
      6 + random.nextInt(4),
      min(fresh.length, positions.length),
    );
    for (var index = 0; index < count; index++) {
      result[positions[index]] = fresh[index];
    }
    // If the visible page was already selected, keep those songs elsewhere
    // in the pool but bring fresh content into view after the explicit pull.
    final freshIds = fresh
        .take(count)
        .map((track) => track.track.trackId)
        .toSet();
    for (final index in visiblePositions) {
      final id = result[index].track.trackId;
      if (!visibleTrackIds.contains(id) ||
          id == currentTrackId ||
          freshIds.contains(id)) {
        continue;
      }
      final newIndex = positions.firstWhere(
        (position) =>
            !visiblePositions.contains(position) &&
            freshIds.contains(result[position].track.trackId),
        orElse: () => -1,
      );
      if (newIndex < 0) break;
      final retained = result[index];
      result[index] = result[newIndex];
      result[newIndex] = retained;
    }
    return List.unmodifiable(result);
  }

  Future<List<LibraryTrack>> buildAsync({
    required List<LibraryTrack> library,
    required DateTime now,
    required String dayKey,
    ListeningPreference preference = const ListeningPreference(),
    double behaviorStrength = 1,
    Map<String, RecommendationBehaviorSignal> behaviorSignals = const {},
    Set<String> previouslySuggestedTrackIds = const {},
  }) => Isolate.run(
    () => build(
      library: library,
      now: now,
      dayKey: dayKey,
      preference: preference,
      behaviorStrength: behaviorStrength,
      behaviorSignals: behaviorSignals,
      previouslySuggestedTrackIds: previouslySuggestedTrackIds,
    ),
  );

  List<LibraryTrack> build({
    required List<LibraryTrack> library,
    required DateTime now,
    required String dayKey,
    ListeningPreference preference = const ListeningPreference(),
    double behaviorStrength = 1,
    Map<String, RecommendationBehaviorSignal> behaviorSignals = const {},
    Set<String> previouslySuggestedTrackIds = const {},
  }) {
    assert(behaviorStrength >= 0 && behaviorStrength <= 1);
    final unique = <String, LibraryTrack>{
      for (final track in RecommendationEligibility.filter(library))
        track.track.trackId: track,
    };
    if (unique.isEmpty) return const [];

    final evaluationNow = DateTime(now.year, now.month, now.day, 12);
    final random = Random(_stableSeed(dayKey));
    final unsuppressed = unique.values
        .where(
          (track) =>
              !(behaviorSignals[track.track.trackId]?.isTemporarilySuppressedAt(
                    evaluationNow,
                  ) ??
                  false),
        )
        .toList(growable: true);
    final remaining = unsuppressed.isEmpty
        ? unique.values.toList(growable: true)
        : unsuppressed;
    remaining.sort((a, b) => a.track.trackId.compareTo(b.track.trackId));
    final affinity = RecommendationAffinityProfile.fromLibrary(
      unique.values,
      behaviorSignals,
    );
    final artistCandidateCounts = <String, int>{};
    for (final track in remaining) {
      final artist = _artistKey(track);
      if (artist.isNotEmpty) {
        artistCandidateCounts.update(
          artist,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
    final target = min(trackCount, remaining.length);
    final shares = _shares(preference.familiarity);
    final groups = {
      for (final track in remaining)
        track.track.trackId: _groupFor(
          track,
          evaluationNow,
          behaviorStrength: behaviorStrength,
          behaviorSignals: behaviorSignals,
        ),
    };
    final available = {
      for (final group in _SmartGroup.values)
        group: groups.values.where((value) => value == group).length,
    };
    final requested = <_SmartGroup, int>{
      _SmartGroup.exploration: (target * shares.exploration).round(),
      _SmartGroup.familiar: (target * shares.familiar).round(),
      _SmartGroup.rediscovery: (target * shares.rediscovery).round(),
    };
    requested[_SmartGroup.surprise] = max(
      0,
      target - requested.values.fold<int>(0, (a, b) => a + b),
    );
    final counts = {
      for (final group in _SmartGroup.values)
        group: min(requested[group]!, available[group]!),
    };
    // When there are only a handful of taste anchors, rotate them rather
    // than exhaust the same small cohort every day. Small libraries can still
    // fall back to these tracks when there is nothing else to explore.
    for (final group in [_SmartGroup.familiar, _SmartGroup.rediscovery]) {
      if (available[group]! > 1 && available[group]! <= requested[group]! + 2) {
        counts[group] = min(counts[group]!, (available[group]! / 2).ceil());
      }
    }
    for (final group in [
      _SmartGroup.exploration,
      _SmartGroup.surprise,
      _SmartGroup.rediscovery,
      _SmartGroup.familiar,
    ]) {
      final deficit = target - counts.values.fold<int>(0, (a, b) => a + b);
      counts[group] =
          counts[group]! + min(deficit, available[group]! - counts[group]!);
    }
    final schedule = [
      for (final group in _SmartGroup.values)
        ...List.filled(counts[group]!, group),
    ];
    schedule.shuffle(random);

    final selected = <LibraryTrack>[];
    for (final group in schedule) {
      final preferred = remaining
          .where((track) => groups[track.track.trackId] == group)
          .toList(growable: false);
      final picked = _pick(
        preferred.isEmpty ? remaining : preferred,
        allRemaining: remaining,
        selected: selected,
        group: group,
        now: evaluationNow,
        random: random,
        behaviorStrength: behaviorStrength,
        behaviorSignals: behaviorSignals,
        affinity: affinity,
        previouslySuggestedTrackIds: previouslySuggestedTrackIds,
        artistCandidateCounts: artistCandidateCounts,
      );
      if (picked == null) break;
      selected.add(picked);
      remaining.removeWhere(
        (track) => track.track.trackId == picked.track.trackId,
      );
    }
    return List.unmodifiable(selected);
  }

  LibraryTrack? _pick(
    List<LibraryTrack> preferred, {
    required List<LibraryTrack> allRemaining,
    required List<LibraryTrack> selected,
    required _SmartGroup group,
    required DateTime now,
    required Random random,
    required double behaviorStrength,
    required Map<String, RecommendationBehaviorSignal> behaviorSignals,
    required RecommendationAffinityProfile affinity,
    required Set<String> previouslySuggestedTrackIds,
    required Map<String, int> artistCandidateCounts,
  }) {
    if (allRemaining.isEmpty) return null;
    var pool = preferred.isEmpty ? allRemaining : preferred;
    if (selected.length >= 2) {
      final lastTwo = selected.skip(selected.length - 2).toList();
      final artist = _artistKey(lastTwo.last);
      final album = _albumKey(lastTwo.last);
      final blockedArtist =
          artist.isNotEmpty &&
              lastTwo.every((track) => _artistKey(track) == artist)
          ? artist
          : null;
      final blockedAlbum =
          album.isNotEmpty &&
              lastTwo.every((track) => _albumKey(track) == album)
          ? album
          : null;
      if (blockedArtist != null || blockedAlbum != null) {
        bool allowed(LibraryTrack track) =>
            (blockedArtist == null || _artistKey(track) != blockedArtist) &&
            (blockedAlbum == null || _albumKey(track) != blockedAlbum);

        final preferredAlternatives = pool
            .where(allowed)
            .toList(growable: false);
        final alternatives = preferredAlternatives.isNotEmpty
            ? preferredAlternatives
            : allRemaining.where(allowed).toList(growable: false);
        if (alternatives.isNotEmpty) pool = alternatives;
      }
    }

    final weights = <double>[];
    var total = 0.0;
    final selectedArtistCounts = <String, int>{};
    final selectedAlbumCounts = <String, int>{};
    for (final track in selected) {
      selectedArtistCounts.update(
        _artistKey(track),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      selectedAlbumCounts.update(
        _albumKey(track),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    for (final track in pool) {
      final artist = _artistKey(track);
      final album = _albumKey(track);
      final artistCount = artist.isEmpty
          ? 0
          : selectedArtistCounts[artist] ?? 0;
      final weight =
          _weight(
            track,
            group: group,
            now: now,
            random: random,
            behaviorStrength: behaviorStrength,
            behaviorSignals: behaviorSignals,
            affinity: affinity,
          ) *
          (previouslySuggestedTrackIds.contains(track.track.trackId)
              ? 0.25
              : 1.0) *
          pow(0.65, artistCount) /
          sqrt(artistCandidateCounts[artist] ?? 1) *
          (album.isEmpty ? 1.0 : pow(0.55, selectedAlbumCounts[album] ?? 0));
      weights.add(weight);
      total += weight;
    }
    var cursor = random.nextDouble() * total;
    for (var index = 0; index < pool.length; index++) {
      cursor -= weights[index];
      if (cursor <= 0) return pool[index];
    }
    return pool.last;
  }

  double _weight(
    LibraryTrack track, {
    required _SmartGroup group,
    required DateTime now,
    required Random random,
    required double behaviorStrength,
    required Map<String, RecommendationBehaviorSignal> behaviorSignals,
    required RecommendationAffinityProfile affinity,
  }) {
    final score = _scoreBreakdown(
      track,
      now: now,
      group: group,
      behaviorStrength: behaviorStrength,
      behaviorSignals: behaviorSignals,
      affinity: affinity,
    );
    return max(0.02, score.weight * (0.78 + random.nextDouble() * 0.44));
  }

  SmartPlayScoreBreakdown scoreBreakdown(
    LibraryTrack track, {
    required DateTime now,
    double behaviorStrength = 1,
    RecommendationBehaviorSignal? behaviorSignal,
  }) {
    assert(behaviorStrength >= 0 && behaviorStrength <= 1);
    final behaviorSignals = behaviorSignal == null
        ? const <String, RecommendationBehaviorSignal>{}
        : {track.track.trackId: behaviorSignal};
    return _scoreBreakdown(
      track,
      now: now,
      group: _groupFor(
        track,
        now,
        behaviorStrength: behaviorStrength,
        behaviorSignals: behaviorSignals,
      ),
      behaviorStrength: behaviorStrength,
      behaviorSignals: behaviorSignals,
    );
  }

  SmartPlayScoreBreakdown _scoreBreakdown(
    LibraryTrack track, {
    required DateTime now,
    required _SmartGroup group,
    required double behaviorStrength,
    required Map<String, RecommendationBehaviorSignal> behaviorSignals,
    RecommendationAffinityProfile? affinity,
  }) {
    final stats = track.stats;
    final signal = behaviorSignals[track.track.trackId];
    final playCount = stats.playCount;
    final completionRate = playCount == 0
        ? 0.0
        : (stats.completedCount / playCount).clamp(0.0, 1.0);
    final skipRate = playCount == 0
        ? 0.0
        : (stats.skipCount / playCount).clamp(0.0, 1.0);
    final daysSincePlayed = stats.lastPlayedAt == null
        ? 365
        : max(0, now.difference(stats.lastPlayedAt!).inDays);
    final acceptedCount = signal?.acceptedCount ?? stats.completedCount;
    final rejectedCount =
        signal?.negativeEvidence ?? stats.skipCount.toDouble();
    final directAcceptedCount = signal?.directAcceptedCount ?? 0;
    final observations = acceptedCount + rejectedCount;
    final behaviorSkipRate = observations == 0
        ? skipRate
        : (rejectedCount / observations).clamp(0.0, 1.0);
    final recentExposure =
        signal?.recentExposureCount ??
        (stats.lastPlayedAt != null && daysSincePlayed <= 7 ? 1 : 0);
    final historyWeight = switch (group) {
      _SmartGroup.exploration => 2.2 / (1 + recentExposure * 0.35),
      _SmartGroup.familiar =>
        1.0 +
            (track.preference.liked ? 3.2 : 0) +
            min(2.2, log(acceptedCount + 1) * 1.3) +
            min(1.8, log(directAcceptedCount + 1)),
      _SmartGroup.rediscovery =>
        1.0 + min(1.8, log(acceptedCount + 1)) + min(1.8, daysSincePlayed / 45),
      _SmartGroup.surprise => 1.4 / (1 + recentExposure * 0.2),
    };
    final baselineWeight = track.preference.liked ? 2.4 : 1.0;
    var weight =
        baselineWeight + (historyWeight - baselineWeight) * behaviorStrength;
    var historyMultiplier = (1 - behaviorSkipRate * 0.7).clamp(0.25, 1.0);
    if (signal != null) {
      historyMultiplier *= pow(
        0.78,
        min(4, signal.recentExposureCount),
      ).toDouble();
      historyMultiplier *=
          1 + min(0.35, signal.matchingTimeAcceptedCount * 0.07);
    }
    if (stats.lastSkippedAt != null &&
        max(0, now.difference(stats.lastSkippedAt!).inDays) <= 7) {
      historyMultiplier *= 0.35;
    }
    if (daysSincePlayed <= 2) historyMultiplier *= 0.45;
    final appliedMultiplier = 1 + (historyMultiplier - 1) * behaviorStrength;
    weight = max(0.02, weight * appliedMultiplier);
    if (affinity != null) {
      final affinityMultiplier = affinity.multiplierFor(track);
      weight = max(
        0.02,
        weight *
            (signal?.hasDominantNegativeEvidence ?? false
                ? min(1.0, affinityMultiplier)
                : affinityMultiplier),
      );
    }
    return SmartPlayScoreBreakdown(
      group: group.name,
      behaviorStrength: behaviorStrength,
      liked: track.preference.liked,
      playCount: playCount,
      completionRate: completionRate,
      skipRate: skipRate,
      manuallySelectedCount: stats.manuallySelectedCount,
      daysSincePlayed: daysSincePlayed,
      weight: weight,
    );
  }

  _SmartGroup _groupFor(
    LibraryTrack track,
    DateTime now, {
    required double behaviorStrength,
    required Map<String, RecommendationBehaviorSignal> behaviorSignals,
  }) {
    final stats = track.stats;
    final signal = behaviorSignals[track.track.trackId];
    if (behaviorStrength == 0) {
      if (track.preference.liked) return _SmartGroup.familiar;
      if (stats.completedCount >= 2) return _SmartGroup.familiar;
      if (stats.completedCount > 0 &&
          stats.lastPlayedAt != null &&
          now.difference(stats.lastPlayedAt!).inDays >= 30) {
        return _SmartGroup.rediscovery;
      }
      return stats.completedCount == 0 && stats.skipCount == 0
          ? _SmartGroup.exploration
          : _SmartGroup.surprise;
    }
    final accepted = signal?.hasReliableAcceptance ?? stats.completedCount >= 2;
    final reliablyAccepted = signal == null
        ? stats.completedCount >= 2
        : signal.hasReliableAcceptance &&
              (signal.acceptedCount >= 2 || signal.directAcceptedCount >= 2);
    final lastAcceptedAt = signal?.lastAcceptedAt ?? stats.lastPlayedAt;
    if (accepted &&
        lastAcceptedAt != null &&
        now.difference(lastAcceptedAt).inDays >= 30) {
      return _SmartGroup.rediscovery;
    }
    if (track.preference.liked || reliablyAccepted) {
      return _SmartGroup.familiar;
    }
    if ((signal == null && stats.completedCount == 0 && stats.skipCount == 0) ||
        (signal != null &&
            signal.acceptedCount == 0 &&
            signal.negativeEvidence == 0)) {
      return _SmartGroup.exploration;
    }
    return _SmartGroup.surprise;
  }

  _SmartShares _shares(FamiliarityPreference preference) =>
      switch (preference) {
        FamiliarityPreference.explore => const _SmartShares(0.43, 0.25, 0.20),
        FamiliarityPreference.balanced => const _SmartShares(0.38, 0.29, 0.22),
        FamiliarityPreference.familiar => const _SmartShares(0.35, 0.32, 0.22),
      };

  int _stableSeed(String value) {
    var hash = 0x811C9DC5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7FFFFFFF;
    }
    return hash;
  }

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

enum _SmartGroup { exploration, familiar, rediscovery, surprise }

class _SmartShares {
  const _SmartShares(this.exploration, this.familiar, this.rediscovery);

  final double exploration;
  final double familiar;
  final double rediscovery;
}

class SmartPlayScoreBreakdown {
  const SmartPlayScoreBreakdown({
    required this.group,
    required this.behaviorStrength,
    required this.liked,
    required this.playCount,
    required this.completionRate,
    required this.skipRate,
    required this.manuallySelectedCount,
    required this.daysSincePlayed,
    required this.weight,
  });

  final String group;
  final double behaviorStrength;
  final bool liked;
  final int playCount;
  final double completionRate;
  final double skipRate;
  final int manuallySelectedCount;
  final int daysSincePlayed;
  final double weight;
}
