import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/listening_data.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/recommendation_behavior.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/services/home_quick_start_radio.dart';

void main() {
  final now = DateTime(2026, 9, 7, 20);

  test('连续启动不反复提供上一批，冷却只影响推荐而不修改播放记录', () {
    final library = [
      for (var index = 0; index < 60; index++)
        _track(
          'familiar-$index',
          playCount: 8,
          lastPlayedAt: now.subtract(const Duration(days: 8)),
        ),
    ];
    final radio = HomeQuickStartRadio(random: Random(71));
    Set<String> previous = {};
    final firstIds = <String>{};
    var repeats = 0;
    for (var session = 0; session < 40; session++) {
      final result = radio.select(library: library, count: 12, now: now);
      firstIds.add(result.first.track.trackId);
      final ids = result.map((t) => t.track.trackId).toSet();
      repeats += ids.intersection(previous).length;
      previous = ids;
    }
    expect(firstIds.length, greaterThan(20));
    expect(repeats / 39, lessThan(2));
    expect(library.every((t) => t.stats.playCount == 8), isTrue);
  });

  test('刚听过的喜欢歌曲必须明显降权，而不是被权重压平', () {
    final recent = _track(
      'recent',
      liked: true,
      playCount: 8,
      lastPlayedAt: now,
    );
    final rested = _track(
      'rested',
      liked: true,
      playCount: 8,
      lastPlayedAt: now.subtract(const Duration(days: 8)),
    );
    var recentStarts = 0;
    for (var seed = 0; seed < 800; seed++) {
      final result = HomeQuickStartRadio(random: Random(seed))
          .select(library: [recent, rested], count: 1, now: now);
      if (result.single.track.trackId == 'recent') recentStarts++;
    }
    expect(recentStarts, lessThan(180));
  });

  test('随心听以熟悉歌曲为主体，同时混入重新发现和少量探索', () {
    final radio = HomeQuickStartRadio(random: Random(7));
    final library = [
      for (var index = 0; index < 12; index++)
        _track(
          'familiar-$index',
          playCount: 8,
          lastPlayedAt: now.subtract(const Duration(days: 8)),
        ),
      for (var index = 0; index < 8; index++)
        _track(
          'rediscovery-$index',
          playCount: 5,
          lastPlayedAt: now.subtract(const Duration(days: 60)),
        ),
      for (var index = 0; index < 10; index++) _track('explore-$index'),
    ];

    final selected = radio.select(library: library, count: 15, now: now);

    expect(selected.map((item) => item.track.trackId).toSet(), hasLength(15));
    expect(_countPrefix(selected, 'familiar-'), 9);
    expect(_countPrefix(selected, 'rediscovery-'), 4);
    expect(_countPrefix(selected, 'explore-'), 2);
  });

  test('没有久未听候选时优先补熟悉歌曲，但保留短队列的两首探索', () {
    final radio = HomeQuickStartRadio(random: Random(8));
    final library = [
      for (var index = 0; index < 20; index++)
        _track(
          'familiar-$index',
          playCount: 5,
          lastPlayedAt: now.subtract(const Duration(days: 8)),
        ),
      for (var index = 0; index < 20; index++) _track('explore-$index'),
    ];

    final selected = radio.select(library: library, count: 12, now: now);

    expect(_countPrefix(selected, 'familiar-'), 10);
    expect(_countPrefix(selected, 'explore-'), 2);
  });

  test('一次被动播完不足以建立可靠口味，主动选择则可以', () {
    final passive = RecommendationBehaviorSignal(
      trackId: 'passive',
      acceptedCount: 1,
      rejectedCount: 0,
      directAcceptedCount: 0,
      recentExposureCount: 1,
      matchingTimeAcceptedCount: 1,
    );
    final direct = RecommendationBehaviorSignal(
      trackId: 'direct',
      acceptedCount: 1,
      rejectedCount: 0,
      directAcceptedCount: 1,
      recentExposureCount: 1,
      matchingTimeAcceptedCount: 1,
    );

    expect(passive.hasReliableAcceptance, isFalse);
    expect(direct.hasReliableAcceptance, isTrue);
  });

  test('一次被动播完只进入重新发现池，不会升级为核心熟悉歌曲', () {
    final radio = HomeQuickStartRadio(random: Random(10));
    final library = [
      for (var index = 0; index < 9; index++)
        _track(
          'familiar-$index',
          playCount: 5,
          lastPlayedAt: now.subtract(const Duration(days: 8)),
        ),
      for (var index = 0; index < 6; index++) _track('passive-$index'),
      for (var index = 0; index < 10; index++) _track('explore-$index'),
    ];
    final signals = {
      for (var index = 0; index < 6; index++)
        'passive-$index': RecommendationBehaviorSignal(
          trackId: 'passive-$index',
          acceptedCount: 1,
          rejectedCount: 0,
          directAcceptedCount: 0,
          recentExposureCount: 0,
          matchingTimeAcceptedCount: 0,
          lastAcceptedAt: now.subtract(const Duration(days: 5)),
        ),
    };

    final selected = radio.select(
      library: library,
      count: 12,
      now: now,
      behaviorSignals: signals,
    );

    expect(_countPrefix(selected, 'familiar-'), 7);
    expect(_countPrefix(selected, 'passive-'), 3);
    expect(_countPrefix(selected, 'explore-'), 2);
  });

  test('第一首大多来自可靠口味但保留少量探索并持续变化', () {
    final radio = HomeQuickStartRadio(random: Random(9));
    final library = [
      for (var index = 0; index < 20; index++)
        _track('familiar-$index', playCount: 5),
      for (var index = 0; index < 20; index++) _track('explore-$index'),
    ];
    final firstTracks = <String>{};
    var trustedStarts = 0;
    String? previousFirst;
    for (var index = 0; index < 24; index++) {
      final selected = radio.select(
        library: library,
        count: 15,
        now: now,
        avoidFirstTrackId: previousFirst,
      );
      previousFirst = selected.first.track.trackId;
      if (previousFirst.startsWith('familiar-')) trustedStarts += 1;
      firstTracks.add(previousFirst);
    }

    expect(trustedStarts, greaterThanOrEqualTo(18));
    expect(firstTracks.length, greaterThanOrEqualTo(12));
  });

  test('连续启动尽量更换第一首，且补歌不会重复当前队列', () {
    final radio = HomeQuickStartRadio(random: Random(11));
    final library = [
      for (var index = 0; index < 40; index++)
        _track('track-$index', playCount: index.isEven ? 4 : 0),
    ];
    final sessions = <List<LibraryTrack>>[];
    String? previousFirst;
    for (var index = 0; index < 5; index++) {
      final session = radio.select(
        library: library,
        count: 15,
        now: now,
        avoidFirstTrackId: previousFirst,
      );
      if (previousFirst != null) {
        expect(session.first.track.trackId, isNot(previousFirst));
      }
      previousFirst = session.first.track.trackId;
      sessions.add(session);
    }
    final first = sessions.first;
    final refill = radio.select(
      library: library,
      count: 9,
      now: now,
      excludingTrackIds: first.map((item) => item.track.trackId).toSet(),
      previousTracks: first,
    );

    expect(
      sessions.map((items) => items.first.track.trackId).toSet().length,
      greaterThanOrEqualTo(4),
    );
    expect(
      sessions
          .map((items) => items.map((item) => item.track.trackId).join(','))
          .toSet(),
      hasLength(5),
    );
    expect(first.map((item) => item.track.trackId).toSet(), hasLength(15));
    expect(refill.map((item) => item.track.trackId).toSet(), hasLength(9));
    expect(
      refill
          .map((item) => item.track.trackId)
          .toSet()
          .intersection(first.map((item) => item.track.trackId).toSet()),
      isEmpty,
    );
  });

  test('存在其它候选时不会连续三首使用同一歌手或专辑', () {
    final radio = HomeQuickStartRadio(random: Random(23));
    final library = [
      for (var index = 0; index < 12; index++)
        _track(
          'core-$index',
          playCount: 20,
          liked: true,
          artist: '核心歌手',
          album: '核心专辑',
        ),
      for (var index = 0; index < 12; index++)
        _track(
          'other-$index',
          playCount: 3,
          artist: '歌手$index',
          album: '专辑$index',
        ),
    ];

    final selected = radio.select(library: library, count: 15, now: now);

    for (var index = 2; index < selected.length; index++) {
      final three = selected.sublist(index - 2, index + 1);
      expect(
        three.map((item) => item.track.artistDisplay).toSet().length,
        greaterThan(1),
      );
      expect(
        three.map((item) => item.track.albumDisplay).toSet().length,
        greaterThan(1),
      );
    }
    expect(selected.any((item) => item.track.artistDisplay == '核心歌手'), isTrue);
  });

  test('仅手动播放歌曲在初始选歌和动态补歌使用的同一入口中均被排除', () {
    final radio = HomeQuickStartRadio(random: Random(31));
    final library = [
      for (var index = 0; index < 20; index++)
        _track('normal-$index', playCount: index % 4),
      _track('manual-only', recommendationExcluded: true),
    ];

    final initial = radio.select(library: library, count: 15, now: now);
    final refill = radio.select(
      library: library,
      count: 9,
      now: now,
      excludingTrackIds: initial.map((item) => item.track.trackId).toSet(),
      previousTracks: initial,
    );

    expect(
      [...initial, ...refill].map((item) => item.track.trackId),
      isNot(contains('manual-only')),
    );
  });

  test('高播放但近期连续跳过且从未接受的歌曲不会被当成熟悉歌曲', () {
    final radio = HomeQuickStartRadio(random: Random(37));
    final rejected = _track(
      'rejected',
      playCount: 20,
      lastPlayedAt: now.subtract(const Duration(days: 1)),
    );
    final library = [
      rejected,
      for (var index = 0; index < 20; index++) _track('normal-$index'),
    ];
    final signal = RecommendationBehaviorSignal(
      trackId: rejected.track.trackId,
      acceptedCount: 0,
      rejectedCount: 4,
      directAcceptedCount: 0,
      recentExposureCount: 4,
      matchingTimeAcceptedCount: 0,
      lastRejectedAt: now.subtract(const Duration(days: 1)),
    );

    final selected = radio.select(
      library: library,
      count: 15,
      now: now,
      behaviorSignals: {rejected.track.trackId: signal},
    );

    expect(
      selected.map((item) => item.track.trackId),
      isNot(contains('rejected')),
    );
  });

  test('一次明确早退会冷却七天，但不会永久排除歌曲', () {
    final radio = HomeQuickStartRadio(random: Random(39));
    final rejected = _track('rejected-once', playCount: 10);
    final library = [
      rejected,
      for (var index = 0; index < 20; index++) _track('normal-$index'),
    ];
    final signal = RecommendationBehaviorSignal(
      trackId: rejected.track.trackId,
      acceptedCount: 0,
      rejectedCount: 1,
      directAcceptedCount: 0,
      recentExposureCount: 1,
      matchingTimeAcceptedCount: 0,
      lastRejectedAt: now.subtract(const Duration(days: 1)),
    );

    expect(signal.isTemporarilySuppressedAt(now), isTrue);
    expect(
      signal.isTemporarilySuppressedAt(now.add(const Duration(days: 8))),
      isFalse,
    );
    final selected = radio.select(
      library: library,
      count: 15,
      now: now,
      behaviorSignals: {rejected.track.trackId: signal},
    );
    expect(
      selected.map((item) => item.track.trackId),
      isNot(contains('rejected-once')),
    );
  });

  test('已有真实接受记录时，单次早退不会自动冷却歌曲', () {
    final signal = RecommendationBehaviorSignal(
      trackId: 'accepted-before',
      acceptedCount: 1,
      rejectedCount: 1,
      directAcceptedCount: 1,
      recentExposureCount: 2,
      matchingTimeAcceptedCount: 0,
      lastAcceptedAt: now.subtract(const Duration(days: 2)),
      lastRejectedAt: now.subtract(const Duration(days: 1)),
    );

    expect(signal.isTemporarilySuppressedAt(now), isFalse);
  });

  test('更早听完过的歌曲在近期连续跳过后会暂时退出随心听', () {
    final radio = HomeQuickStartRadio(random: Random(40));
    final rejected = _track('accepted-then-rejected', playCount: 20);
    final library = [
      rejected,
      for (var index = 0; index < 20; index++) _track('normal-$index'),
    ];
    final signal = RecommendationBehaviorSignal(
      trackId: rejected.track.trackId,
      acceptedCount: 2,
      rejectedCount: 5,
      directAcceptedCount: 1,
      recentExposureCount: 5,
      matchingTimeAcceptedCount: 0,
      recentRejectStreak: 2,
      lastAcceptedAt: now.subtract(const Duration(days: 20)),
      lastRejectedAt: now.subtract(const Duration(days: 1)),
    );

    final selected = radio.select(
      library: library,
      count: 12,
      now: now,
      behaviorSignals: {rejected.track.trackId: signal},
    );

    expect(signal.isTemporarilySuppressedAt(now), isTrue);
    expect(
      selected.map((item) => item.track.trackId),
      isNot(contains(rejected.track.trackId)),
    );
  });

  test('接受一首歌后会适度发现同一主要歌手的其他歌曲', () {
    final radio = HomeQuickStartRadio(random: Random(41));
    final seed = _track('seed', artist: '周杰伦 & 杨瑞代');
    final library = [
      seed,
      for (var index = 0; index < 12; index++)
        _track('jay-$index', artist: '周杰伦'),
      for (var index = 0; index < 40; index++)
        _track('other-$index', artist: '其他歌手$index'),
    ];
    final signal = RecommendationBehaviorSignal(
      trackId: seed.track.trackId,
      acceptedCount: 12,
      rejectedCount: 0,
      directAcceptedCount: 5,
      recentExposureCount: 0,
      matchingTimeAcceptedCount: 3,
      lastAcceptedAt: now.subtract(const Duration(days: 12)),
    );

    final selected = radio.select(
      library: library,
      count: 15,
      now: now,
      behaviorSignals: {seed.track.trackId: signal},
    );

    expect(
      selected.where((track) => track.track.artistDisplay == '周杰伦').length,
      greaterThanOrEqualTo(3),
    );
  });

  test('同一时间段反复接受的歌曲会获得可感知但不垄断的优先级', () {
    final matching = _track('matching-time');
    final neutral = _track('neutral-time');
    final baseStartedAt = now.subtract(const Duration(days: 8));
    final signals = {
      matching.track.trackId: RecommendationBehaviorSignal(
        trackId: matching.track.trackId,
        acceptedCount: 5,
        rejectedCount: 0,
        directAcceptedCount: 2,
        recentExposureCount: 0,
        matchingTimeAcceptedCount: 5,
        lastAcceptedAt: baseStartedAt,
      ),
      neutral.track.trackId: RecommendationBehaviorSignal(
        trackId: neutral.track.trackId,
        acceptedCount: 5,
        rejectedCount: 0,
        directAcceptedCount: 2,
        recentExposureCount: 0,
        matchingTimeAcceptedCount: 0,
        lastAcceptedAt: baseStartedAt,
      ),
    };
    var matchingStarts = 0;
    for (var seed = 0; seed < 400; seed++) {
      final selected = HomeQuickStartRadio(random: Random(seed)).select(
        library: [matching, neutral],
        count: 1,
        now: now,
        behaviorSignals: signals,
      );
      if (selected.single.track.trackId == matching.track.trackId) {
        matchingStarts++;
      }
    }

    expect(matchingStarts, greaterThan(220));
    expect(matchingStarts, lessThan(350));
  });
}

int _countPrefix(List<LibraryTrack> tracks, String prefix) =>
    tracks.where((item) => item.track.trackId.startsWith(prefix)).length;

LibraryTrack _track(
  String id, {
  int playCount = 0,
  bool liked = false,
  bool recommendationExcluded = false,
  String? artist,
  String? album,
  DateTime? lastPlayedAt,
}) {
  final updatedAt = DateTime(2026, 9, 1);
  return LibraryTrack(
    track: Track(
      trackId: id,
      title: id,
      artistDisplay: artist ?? '歌手-$id',
      albumArtistDisplay: artist ?? '歌手-$id',
      albumDisplay: album ?? '专辑-$id',
      durationMs: 180000,
      metadataState: 'complete',
      addedAt: updatedAt,
      updatedAt: updatedAt,
    ),
    preferredFile: MediaFile(
      fileId: '$id-file',
      trackId: id,
      documentUri: 'content://music/$id',
      filename: '$id.flac',
      normalizedFilename: '$id.flac',
      extension: 'flac',
      mimeType: 'audio/flac',
      sizeBytes: 100,
      durationMs: 180000,
      hashState: 'ready',
      status: 'active',
      createdAt: updatedAt,
      updatedAt: updatedAt,
    ),
    preference: TrackPreference(
      trackId: id,
      liked: liked,
      recommendationExcluded: recommendationExcluded,
      updatedAt: updatedAt,
    ),
    stats: TrackStats(
      trackId: id,
      playCount: playCount,
      completedCount: playCount,
      skipCount: 0,
      manuallySelectedCount: playCount ~/ 2,
      totalPlayDurationMs: playCount * 180000,
      lastPlayedAt: lastPlayedAt,
      updatedAt: updatedAt,
    ),
  );
}
