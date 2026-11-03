import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/listening_data.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/recommendation_behavior.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/services/home_quick_start_radio.dart';
import 'package:my_music_library/services/home_smart_play_pool.dart';

void main() {
  final now = DateTime(2026, 9, 7, 20);

  test('手动刷新只替换6至9首且没有重复，不修改原列表', () {
    final library = [for (var i = 0; i < 100; i++) _track('refresh-$i')];
    final builder = HomeSmartPlayPool();
    final initial = builder.build(library: library, now: now, dayKey: 'daily');
    final before = _ids(initial);
    final refreshed = builder.refresh(
      library: library,
      current: initial,
      now: now,
      refreshKey: 'daily-refresh-1',
    );
    final ids = _ids(refreshed);
    expect(refreshed, hasLength(27));
    expect(ids.toSet(), hasLength(27));
    expect(
      ids.where((id) => !before.contains(id)).length,
      inInclusiveRange(6, 9),
    );
    expect(_ids(initial), before);
    expect(
      ids.every((id) => library.any((track) => track.track.trackId == id)),
      isTrue,
    );
  });

  test('刷新保留正在播放的位置，已点击歌曲保留但可见区域能看到新歌', () {
    final library = [for (var i = 0; i < 100; i++) _track('visible-$i')];
    final builder = HomeSmartPlayPool();
    final initial = builder.build(
      library: library,
      now: now,
      dayKey: 'visible',
    );
    final before = _ids(initial);
    final refreshed = builder.refresh(
      library: library,
      current: initial,
      now: now,
      refreshKey: 'visible-refresh-1',
      visibleTrackIds: before.take(3).toSet(),
      viewedTrackIds: before.take(6).toSet(),
      selectedTrackIds: before.take(6).toSet(),
      currentTrackId: before.first,
    );
    final ids = _ids(refreshed);
    expect(ids.first, before.first);
    expect(ids, containsAll(before.take(6)));
    expect(before, isNot(contains(ids[1])));
    expect(before, isNot(contains(ids[2])));
    expect(
      ids.where((id) => !before.contains(id)).length,
      inInclusiveRange(6, 9),
    );
  });

  test('小曲库无新候选时保留原池，不凭空补歌', () {
    final builder = HomeSmartPlayPool();
    for (final count in [0, 1, 10, 27]) {
      final library = [for (var i = 0; i < count; i++) _track('small-$i')];
      final initial = builder.build(
        library: library,
        now: now,
        dayKey: 'small',
      );
      final refreshed = builder.refresh(
        library: library,
        current: initial,
        now: now,
        refreshKey: 'small-refresh',
        visibleTrackIds: _ids(initial).take(3).toSet(),
      );
      expect(_ids(refreshed), _ids(initial));
    }
  });

  test('连续刷新可换新，排除仅手动播放且后台计算与同步一致', () async {
    final library = [
      for (var i = 0; i < 100; i++) _track('eligible-$i'),
      _track('manual-only', recommendationExcluded: true),
    ];
    final builder = HomeSmartPlayPool();
    final initial = builder.build(
      library: library,
      now: now,
      dayKey: 'eligible',
    );
    final first = builder.refresh(
      library: library,
      current: initial,
      now: now,
      refreshKey: 'eligible-refresh-1',
    );
    final background = await builder.refreshAsync(
      library: library,
      current: initial,
      now: now,
      refreshKey: 'eligible-refresh-1',
    );
    expect(_ids(first), _ids(background));
    final second = builder.refresh(
      library: library,
      current: first,
      now: now,
      refreshKey: 'eligible-refresh-2',
    );
    expect(_ids(second), isNot(_ids(first)));
    expect(_ids(second), isNot(contains('manual-only')));
    expect(_ids(second).toSet(), hasLength(27));
  });

  test('后台生成与同步算法相同，可传递真实模型且不阻塞主线程定时器', () async {
    final library = [
      for (var index = 0; index < 500; index++) _track('track-$index'),
    ];
    final builder = HomeSmartPlayPool();
    final signals = {
      library.first.track.trackId: RecommendationBehaviorSignal(
        trackId: library.first.track.trackId,
        acceptedCount: 2,
        rejectedCount: 0,
        directAcceptedCount: 1,
        recentExposureCount: 0,
        matchingTimeAcceptedCount: 1,
        lastAcceptedAt: now.subtract(const Duration(days: 8)),
      ),
    };
    var mainThreadResponsive = false;
    final background = builder.buildAsync(
      library: library,
      now: now,
      dayKey: 'async',
      behaviorSignals: signals,
      previouslySuggestedTrackIds: {'track-20'},
    );
    await Future<void>.delayed(
      Duration.zero,
      () => mainThreadResponsive = true,
    );
    final result = await background;
    expect(mainThreadResponsive, isTrue);
    expect(
      _ids(result),
      _ids(
        builder.build(
          library: library,
          now: now,
          dayKey: 'async',
          behaviorSignals: signals,
          previouslySuggestedTrackIds: {'track-20'},
        ),
      ),
    );
  });

  test('1000首曲库生成推荐池有时间基线，不因多样性计算变慢', () {
    final library = [
      for (var index = 0; index < 1000; index++)
        _track(
          'track-$index',
          artist: '歌手${index % 30}',
          album: '专辑${index ~/ 10}',
        ),
    ];
    final watch = Stopwatch()..start();
    final result = HomeSmartPlayPool().build(
      library: library,
      now: now,
      dayKey: 'performance',
    );
    watch.stop();
    // ignore: avoid_print
    print('smart_pool_1000_tracks_ms=${watch.elapsedMilliseconds}');
    expect(result, hasLength(27));
    expect(watch.elapsedMilliseconds, lessThan(1200));
  });

  test('少量口味锚点下两种模式仍分工明确，不能只看宽松Jaccard', () {
    final library = [
      for (var index = 0; index < 6; index++)
        _track(
          'liked-$index',
          liked: true,
          lastPlayedAt: now.subtract(const Duration(days: 8)),
        ),
      for (var index = 0; index < 8; index++)
        _track(
          'old-$index',
          playCount: 5,
          completedCount: 4,
          lastPlayedAt: now.subtract(const Duration(days: 60)),
        ),
      for (var index = 0; index < 300; index++) _track('explore-$index'),
    ];
    final smart = HomeSmartPlayPool().build(
      library: library,
      now: now,
      dayKey: '2026-09-07',
    );
    final smartIds = _ids(smart).toSet();
    var overlap = 0;
    var trusted = 0;
    for (var seed = 0; seed < 200; seed++) {
      final quick = HomeQuickStartRadio(random: Random(seed)).select(
        library: library,
        count: 12,
        now: now,
        deEmphasizedTrackIds: smartIds,
      );
      overlap += quick.where((t) => smartIds.contains(t.track.trackId)).length;
      trusted += quick
          .where((t) => !t.track.trackId.startsWith('explore-'))
          .length;
    }
    final overlapShare = overlap / (200 * 12);
    final trustedShare = trusted / (200 * 12);
    // ignore: avoid_print
    print(
      'mode_audit overlap=$overlapShare trusted=$trustedShare smart_exploration=${_countPrefix(smart, 'explore-')}/${smart.length}',
    );
    expect(overlapShare, lessThan(0.5));
    expect(trustedShare, greaterThan(0.65));
    expect(_countPrefix(smart, 'explore-'), greaterThanOrEqualTo(16));
  });

  test('大歌手目录不会仅凭文件多而挤占智能播放前十首', () {
    final library = [
      for (var index = 0; index < 500; index++)
        _track('big-$index', artist: '大歌手'),
      for (var artist = 0; artist < 5; artist++)
        for (var index = 0; index < 30; index++)
          _track('other-$artist-$index', artist: '其他歌手$artist'),
    ];
    var dominantCount = 0;
    for (var day = 0; day < 30; day++) {
      final pool = HomeSmartPlayPool().build(
        library: library,
        now: now,
        dayKey: 'audit-$day',
      );
      dominantCount += pool
          .take(10)
          .where((t) => t.track.artistDisplay == '大歌手')
          .length;
    }
    expect(dominantCount / 30, lessThan(4));
  });

  test('昨日展示过但没听的歌曲也轮换，不能冒充已经播放或修改统计', () {
    final library = [
      for (var index = 0; index < 100; index++) _track('track-$index'),
    ];
    final builder = HomeSmartPlayPool();
    var repeated = 0;
    for (var day = 0; day < 30; day++) {
      final first = builder.build(
        library: library,
        now: now,
        dayKey: 'first-$day',
      );
      final ids = _ids(first).toSet();
      final next = builder.build(
        library: library,
        now: now.add(const Duration(days: 1)),
        dayKey: 'next-$day',
        previouslySuggestedTrackIds: ids,
      );
      repeated += next.where((t) => ids.contains(t.track.trackId)).length;
    }
    expect(repeated / (30 * 27), lessThan(0.18));
    expect(library.every((t) => t.stats.playCount == 0), isTrue);
  });

  test('熟悉歌曲很少时不能每天把同一小批全部塞进智能播放', () {
    final library = [
      for (var index = 0; index < 6; index++)
        _track(
          'liked-$index',
          liked: true,
          lastPlayedAt: now.subtract(const Duration(days: 8)),
        ),
      for (var index = 0; index < 240; index++) _track('explore-$index'),
    ];
    final frequency = <String, int>{};
    for (var day = 0; day < 14; day++) {
      final result = HomeSmartPlayPool().build(
        library: library,
        now: now.add(Duration(days: day)),
        dayKey: 'day-$day',
      );
      for (final track in result.where((t) => t.preference.liked)) {
        frequency.update(track.track.trackId, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    expect(frequency.values.reduce(max), lessThan(14));
  });

  test('当天池不因音乐库输入顺序改变而改变', () {
    final library = [
      for (var index = 0; index < 100; index++) _track('track-$index'),
    ];
    final pool = HomeSmartPlayPool();
    final first = pool.build(library: library, now: now, dayKey: '2026-09-07');
    final reversed = pool.build(
      library: library.reversed.toList(),
      now: now,
      dayKey: '2026-09-07',
    );
    expect(_ids(reversed), _ids(first));
  });

  test('智能播放生成27首且探索比例明显高于熟悉播放', () {
    final library = [
      for (var index = 0; index < 15; index++) _track('explore-$index'),
      for (var index = 0; index < 12; index++)
        _track(
          'familiar-$index',
          playCount: 8,
          completedCount: 7,
          manuallySelectedCount: 4,
          lastPlayedAt: now.subtract(const Duration(days: 7)),
        ),
      for (var index = 0; index < 10; index++)
        _track(
          'rediscovery-$index',
          playCount: 5,
          completedCount: 4,
          manuallySelectedCount: 2,
          lastPlayedAt: now.subtract(const Duration(days: 60)),
        ),
      for (var index = 0; index < 10; index++)
        _track(
          'surprise-$index',
          playCount: 2,
          completedCount: 1,
          manuallySelectedCount: 1,
          lastPlayedAt: now.subtract(const Duration(days: 10)),
        ),
    ];
    final smart = HomeSmartPlayPool().build(
      library: library,
      now: now,
      dayKey: '2026-09-07',
    );
    final quick = HomeQuickStartRadio(random: Random(7))
        .select(library: library, count: 15, now: now);

    expect(smart, hasLength(27));
    expect(smart.map((item) => item.track.trackId).toSet(), hasLength(27));
    expect(_countPrefix(smart, 'explore-'), 10);
    expect(_countPrefix(smart, 'familiar-'), 8);
    expect(_countPrefix(smart, 'rediscovery-'), 6);
    expect(_countPrefix(smart, 'surprise-'), 3);
    expect(
      _countPrefix(smart, 'explore-') / smart.length,
      greaterThan(_countPrefix(quick, 'explore-') / quick.length),
    );
  });

  test('同一自然日结果稳定，下一自然日生成不同池子', () {
    final library = [
      for (var index = 0; index < 50; index++)
        _track(
          'track-$index',
          playCount: index % 4,
          completedCount: index % 3,
          manuallySelectedCount: index % 2,
          lastPlayedAt: now.subtract(Duration(days: index + 1)),
        ),
    ];
    final builder = HomeSmartPlayPool();

    final first = builder.build(
      library: library,
      now: now,
      dayKey: '2026-09-07',
    );
    final sameDay = builder.build(
      library: library,
      now: now.add(const Duration(hours: 2)),
      dayKey: '2026-09-07',
    );
    final nextDay = builder.build(
      library: library,
      now: now.add(const Duration(days: 1)),
      dayKey: '2026-09-08',
    );

    expect(_ids(sameDay), _ids(first));
    expect(_ids(nextDay), isNot(_ids(first)));
  });

  test('排除歌曲不会入池，且有其它候选时不连续三首同歌手或专辑', () {
    final library = [
      for (var index = 0; index < 18; index++)
        _track(
          'core-$index',
          playCount: 8,
          completedCount: 7,
          manuallySelectedCount: 4,
          artist: '核心歌手',
          album: '核心专辑',
        ),
      for (var index = 0; index < 18; index++)
        _track('other-$index', artist: '歌手$index', album: '专辑$index'),
      _track('excluded', recommendationExcluded: true),
    ];

    final selected = HomeSmartPlayPool().build(
      library: library,
      now: now,
      dayKey: '2026-09-07',
    );

    expect(_ids(selected), isNot(contains('excluded')));
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
  });

  test('行为数据未成熟时不让播放次数和跳过记录主导评分', () {
    final track = _track(
      'history-heavy',
      playCount: 10,
      completedCount: 1,
      skipCount: 8,
      manuallySelectedCount: 1,
      lastPlayedAt: now.subtract(const Duration(days: 1)),
      lastSkippedAt: now.subtract(const Duration(days: 1)),
    );
    final pool = HomeSmartPlayPool();

    final immature = pool.scoreBreakdown(track, now: now, behaviorStrength: 0);
    final mature = pool.scoreBreakdown(track, now: now, behaviorStrength: 1);

    expect(immature.weight, 1);
    expect(immature.behaviorStrength, 0);
    expect(mature.skipRate, 0.8);
    expect(mature.weight, lessThan(immature.weight));
  });

  test('喜欢状态在行为历史不足时仍是可靠的明确偏好', () {
    final score = HomeSmartPlayPool().scoreBreakdown(
      _track('liked', liked: true),
      now: now,
      behaviorStrength: 0,
    );

    expect(score.group, 'familiar');
    expect(score.weight, 2.4);
  });

  test('旧播放与手动计数没有有效行为证据时仍按低曝光歌曲处理', () {
    final score = HomeSmartPlayPool().scoreBreakdown(
      _track(
        'polluted',
        playCount: 20,
        completedCount: 0,
        manuallySelectedCount: 20,
      ),
      now: now,
    );

    expect(score.group, 'exploration');
  });

  test('累计播放次数本身不会改变智能播放权重', () {
    final pool = HomeSmartPlayPool();
    final newTrack = pool.scoreBreakdown(_track('new-track'), now: now);
    final legacyHighCount = pool.scoreBreakdown(
      _track('legacy-high-count', playCount: 200),
      now: now,
    );

    expect(legacyHighCount.group, newTrack.group);
    expect(legacyHighCount.weight, newTrack.weight);
  });

  test('智能播放排除近期反复跳过且没有任何接受证据的歌曲', () {
    final rejected = _track(
      'rejected',
      playCount: 18,
      completedCount: 0,
      manuallySelectedCount: 0,
      skipCount: 12,
      lastPlayedAt: now.subtract(const Duration(days: 1)),
      lastSkippedAt: now.subtract(const Duration(days: 1)),
    );
    final library = [
      rejected,
      for (var index = 0; index < 35; index++) _track('normal-$index'),
    ];
    final signal = RecommendationBehaviorSignal(
      trackId: rejected.track.trackId,
      acceptedCount: 0,
      rejectedCount: 5,
      directAcceptedCount: 0,
      recentExposureCount: 5,
      matchingTimeAcceptedCount: 0,
      lastRejectedAt: now.subtract(const Duration(days: 1)),
    );

    final selected = HomeSmartPlayPool().build(
      library: library,
      now: now,
      dayKey: '2026-09-07',
      behaviorSignals: {rejected.track.trackId: signal},
    );

    expect(_ids(selected), isNot(contains('rejected')));
    expect(selected, hasLength(27));
  });

  test('少量旧接受不能把大量负反馈歌曲继续归为熟悉歌曲', () {
    final signal = RecommendationBehaviorSignal(
      trackId: 'bad-familiar',
      acceptedCount: 2,
      rejectedCount: 6,
      directAcceptedCount: 1,
      recentExposureCount: 4,
      matchingTimeAcceptedCount: 0,
      lowEngagementCount: 2,
      lastAcceptedAt: now.subtract(const Duration(days: 30)),
      lastRejectedAt: now.subtract(const Duration(days: 2)),
    );

    final score = HomeSmartPlayPool().scoreBreakdown(
      _track('bad-familiar', playCount: 20),
      now: now,
      behaviorSignal: signal,
    );

    expect(signal.hasReliableAcceptance, isFalse);
    expect(score.group, 'surprise');
  });
}

List<String> _ids(List<LibraryTrack> tracks) =>
    tracks.map((item) => item.track.trackId).toList(growable: false);

int _countPrefix(List<LibraryTrack> tracks, String prefix) =>
    tracks.where((item) => item.track.trackId.startsWith(prefix)).length;

LibraryTrack _track(
  String id, {
  int playCount = 0,
  int completedCount = 0,
  int manuallySelectedCount = 0,
  int skipCount = 0,
  bool liked = false,
  bool recommendationExcluded = false,
  String? artist,
  String? album,
  DateTime? lastPlayedAt,
  DateTime? lastSkippedAt,
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
      completedCount: completedCount,
      skipCount: skipCount,
      manuallySelectedCount: manuallySelectedCount,
      totalPlayDurationMs: completedCount * 180000,
      lastPlayedAt: lastPlayedAt,
      lastSkippedAt: lastSkippedAt,
      updatedAt: updatedAt,
    ),
  );
}
