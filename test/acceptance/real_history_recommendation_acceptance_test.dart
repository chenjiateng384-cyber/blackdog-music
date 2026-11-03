import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/library_repository.dart';
import 'package:my_music_library/data/playback_history_repository.dart';
import 'package:my_music_library/models/v4/library_browsing.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/services/home_quick_start_radio.dart';
import 'package:my_music_library/services/home_smart_play_pool.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final sourcePath = Platform.environment['REAL_HISTORY_DB'];
  final enabled = sourcePath != null && File(sourcePath).existsSync();

  setUpAll(sqfliteFfiInit);

  test('真实播放历史下随心听与智能播放保持随机、多样且互不雷同', () async {
    final temp = await Directory.systemTemp.createTemp(
      'harmony-recommendation-audit-',
    );
    final copiedPath = '${temp.path}${Platform.pathSeparator}library.db';
    await File(sourcePath!).copy(copiedPath);
    final database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: copiedPath,
    );

    try {
      final library = await LibraryRepository(database).allTracks();
      final db = await database.database;
      final latestRows = await db.rawQuery(
        'SELECT MAX(started_at) AS latest FROM play_events',
      );
      final latest = latestRows.single['latest'] as int?;
      final now = latest == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(latest)
                .add(const Duration(days: 1));
      final signals = await PlaybackHistoryRepository(database)
          .recommendationSignals(now: now);

      expect(library.length, greaterThanOrEqualTo(100));
      final groupCounts = _frequency(
        library.map(
          (track) => _auditGroup(track, signals[track.track.trackId], now),
        ),
      );
      // ignore: avoid_print
      print('quick_groups $groupCounts');

      final quickSessions = <List<LibraryTrack>>[];
      final smartPool = HomeSmartPlayPool();
      final todaySmart = smartPool.build(
        library: library,
        now: now,
        dayKey: _dayKey(now),
        behaviorSignals: signals,
      );
      final todaySmartIds = _ids(todaySmart).toSet();
      final radio = HomeQuickStartRadio(random: Random(42));
      String? previousFirst;
      for (var seed = 0; seed < 100; seed++) {
        final session = radio.select(
          library: library,
          count: HomeQuickStartRadio.initialTrackCount,
          now: now,
          avoidFirstTrackId: previousFirst,
          behaviorSignals: signals,
          deEmphasizedTrackIds: todaySmartIds,
        );
        expect(_ids(session).toSet().length, session.length);
        expect(_maxArtistRun(session), lessThanOrEqualTo(2));
        quickSessions.add(session);
        previousFirst = session.first.track.trackId;
      }

      final firstIds = quickSessions
          .map((session) => session.first.track.trackId)
          .toList(growable: false);
      final firstFrequency = _frequency(firstIds);
      final allQuickIds = quickSessions.expand(_ids).toList(growable: false);
      final allQuickFrequency = _frequency(allQuickIds);
      final uniqueQuickTracks = allQuickFrequency.length;
      final mostCommonFirstShare =
          firstFrequency.values.reduce(max) / quickSessions.length;
      final mostCommonOverallShare =
          allQuickFrequency.values.reduce(max) / allQuickIds.length;

      final topQuick = allQuickFrequency.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final entry in topQuick.take(3)) {
        final track = library.firstWhere(
          (item) => item.track.trackId == entry.key,
        );
        final signal = signals[entry.key];
        // ignore: avoid_print
        print(
          'quick_top title=${track.track.title} count=${entry.value} '
          'liked=${track.preference.liked} plays=${track.stats.playCount} '
          'completed=${track.stats.completedCount} skips=${track.stats.skipCount} '
          'accepted=${signal?.acceptedCount} direct=${signal?.directAcceptedCount} '
          'negative=${signal?.negativeEvidence} '
          'group=${_auditGroup(track, signal, now)}',
        );
      }

      expect(firstFrequency.length, greaterThanOrEqualTo(12));
      expect(mostCommonFirstShare, lessThanOrEqualTo(0.18));
      expect(uniqueQuickTracks, greaterThanOrEqualTo(45));
      expect(mostCommonOverallShare, lessThanOrEqualTo(0.08));

      final smartDays = <List<LibraryTrack>>[];
      for (var day = 0; day < 14; day++) {
        final date = now.add(Duration(days: day));
        final dayKey = _dayKey(date);
        final pool = smartPool.build(
          library: library,
          now: date,
          dayKey: dayKey,
          behaviorSignals: signals,
          previouslySuggestedTrackIds: day == 0
              ? const {}
              : _ids(smartDays.last).toSet(),
        );
        final repeated = smartPool.build(
          library: library,
          now: date,
          dayKey: dayKey,
          behaviorSignals: signals,
          previouslySuggestedTrackIds: day == 0
              ? const {}
              : _ids(smartDays.last).toSet(),
        );
        expect(_ids(pool), _ids(repeated));
        expect(_ids(pool).toSet().length, pool.length);
        expect(_maxArtistRun(pool), lessThanOrEqualTo(2));
        smartDays.add(pool);
      }

      final uniqueSmartTracks = smartDays.expand(_ids).toSet().length;
      final adjacentOverlap = <double>[];
      for (var index = 1; index < smartDays.length; index++) {
        adjacentOverlap.add(_jaccard(smartDays[index - 1], smartDays[index]));
      }
      final averageAdjacentOverlap =
          adjacentOverlap.reduce((a, b) => a + b) / adjacentOverlap.length;
      final quickSmartOverlap =
          quickSessions
              .map(
                (session) =>
                    _ids(session).where(todaySmartIds.contains).length /
                    session.length,
              )
              .reduce((a, b) => a + b) /
          quickSessions.length;

      expect(uniqueSmartTracks, greaterThanOrEqualTo(60));
      expect(averageAdjacentOverlap, lessThanOrEqualTo(0.65));
      // Jaccard was <= 12/27 even if every radio track appeared in smart play.
      // Measure the actual share of radio tracks already shown in smart play.
      expect(quickSmartOverlap, lessThanOrEqualTo(0.60));

      // One compact line makes later real-data audits easy to compare.
      // ignore: avoid_print
      print(
        'recommendation_audit '
        'library=${library.length} signals=${signals.length} '
        'quick_unique=$uniqueQuickTracks first_unique=${firstFrequency.length} '
        'top_first=${mostCommonFirstShare.toStringAsFixed(3)} '
        'top_overall=${mostCommonOverallShare.toStringAsFixed(3)} '
        'smart_unique=$uniqueSmartTracks '
        'smart_day_overlap=${averageAdjacentOverlap.toStringAsFixed(3)} '
        'quick_smart_overlap=${quickSmartOverlap.toStringAsFixed(3)}',
      );
    } finally {
      await database.close();
      await temp.delete(recursive: true);
    }
  }, skip: enabled ? false : '需要 REAL_HISTORY_DB 指向真机数据库备份');
}

List<String> _ids(Iterable<LibraryTrack> tracks) =>
    tracks.map((track) => track.track.trackId).toList(growable: false);

Map<String, int> _frequency(Iterable<String> values) {
  final result = <String, int>{};
  for (final value in values) {
    result[value] = (result[value] ?? 0) + 1;
  }
  return result;
}

int _maxArtistRun(List<LibraryTrack> tracks) {
  var maximum = 0;
  var current = 0;
  String? previous;
  for (final track in tracks) {
    final artist = primaryArtistName(track.track.artistDisplay)
        .trim()
        .toLowerCase();
    current = artist.isNotEmpty && artist == previous ? current + 1 : 1;
    maximum = max(maximum, current);
    previous = artist;
  }
  return maximum;
}

double _jaccard(List<LibraryTrack> first, List<LibraryTrack> second) {
  final firstIds = _ids(first).toSet();
  final secondIds = _ids(second).toSet();
  final union = firstIds.union(secondIds);
  if (union.isEmpty) return 0;
  return firstIds.intersection(secondIds).length / union.length;
}

String _dayKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String _auditGroup(LibraryTrack track, dynamic signal, DateTime now) {
  final reliablyAccepted =
      track.preference.liked ||
      (signal?.hasReliableAcceptance ?? track.stats.completedCount >= 2);
  final lastPlayedAt = signal?.lastAcceptedAt ?? track.stats.lastPlayedAt;
  if (reliablyAccepted &&
      (lastPlayedAt == null || now.difference(lastPlayedAt).inDays >= 21)) {
    return 'rediscovery';
  }
  if (reliablyAccepted) return 'familiar';
  final lightlyAccepted =
      signal?.hasAcceptedPlayback ?? track.stats.completedCount > 0;
  if (lightlyAccepted && !(signal?.hasDominantNegativeEvidence ?? false)) {
    return 'rediscovery';
  }
  return 'exploration';
}
