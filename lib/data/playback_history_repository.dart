import 'package:uuid/uuid.dart';

import '../models/v4/library_track.dart';
import '../models/v4/playback.dart';
import '../models/v4/recommendation_behavior.dart';
import '../services/library_database.dart';

class PlaybackHistoryRepository {
  PlaybackHistoryRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final LibraryDatabase _database;
  final Uuid _uuid;

  Future<int> validEventCount() async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
SELECT COUNT(*) AS count
  FROM play_events
 WHERE ended_at IS NOT NULL
   AND listened_duration_ms > 0
''');
    return ((rows.single['count'] as num?) ?? 0).toInt();
  }

  Future<Map<String, RecommendationBehaviorSignal>> recommendationSignals({
    required DateTime now,
    int limit = 2000,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'play_events',
      columns: const [
        'track_id',
        'started_at',
        'listened_duration_ms',
        'track_duration_ms',
        'completed',
        'skipped',
        'manually_selected',
        'context_type',
      ],
      where: 'ended_at IS NOT NULL AND listened_duration_ms > 0',
      orderBy: 'started_at DESC',
      limit: limit,
    );
    final builders = <String, _RecommendationSignalBuilder>{};
    for (final row in rows) {
      final trackId = row['track_id']! as String;
      final startedAt = DateTime.fromMillisecondsSinceEpoch(
        row['started_at']! as int,
      );
      final listenedMs = row['listened_duration_ms']! as int;
      final durationMs = row['track_duration_ms']! as int;
      final contextType = row['context_type'] as String?;
      final rawManuallySelected = row['manually_selected'] == 1;
      final automaticPlayback = _isAutomaticPlayback(
        contextType,
        manuallySelected: rawManuallySelected,
      );
      final manuallySelected = rawManuallySelected && !automaticPlayback;
      final ratio = durationMs <= 0 ? 0.0 : listenedMs / durationMs;
      final accepted =
          row['completed'] == 1 ||
          ratio >= 0.7 ||
          (manuallySelected && (ratio >= 0.45 || listenedMs >= 90000));
      final rejected = row['skipped'] == 1 && !accepted;
      final lowEngagement =
          automaticPlayback &&
          !accepted &&
          !rejected &&
          listenedMs >= 5000 &&
          listenedMs < 60000 &&
          (durationMs <= 0 || ratio < 0.35);
      final builder = builders.putIfAbsent(
        trackId,
        () => _RecommendationSignalBuilder(trackId),
      );
      builder.recordRecentOutcome(accepted: accepted, rejected: rejected);
      if (accepted) {
        builder.acceptedCount++;
        if (manuallySelected) builder.directAcceptedCount++;
        if (_minutesApart(startedAt, now) <= 120) {
          builder.matchingTimeAcceptedCount++;
        }
        if (builder.lastAcceptedAt == null ||
            startedAt.isAfter(builder.lastAcceptedAt!)) {
          builder.lastAcceptedAt = startedAt;
        }
      }
      if (rejected) {
        builder.rejectedCount++;
        if (builder.lastRejectedAt == null ||
            startedAt.isAfter(builder.lastRejectedAt!)) {
          builder.lastRejectedAt = startedAt;
        }
      }
      if (lowEngagement) builder.lowEngagementCount++;
      if (!startedAt.isBefore(now.subtract(const Duration(days: 7)))) {
        builder.recentExposureCount++;
      }
    }
    return Map.unmodifiable({
      for (final entry in builders.entries) entry.key: entry.value.build(),
    });
  }

  Future<String> beginPlayback({
    required LibraryTrack item,
    required DateTime startedAt,
    required bool manuallySelected,
    required PlaybackContext context,
    required PlaybackMode mode,
    String? sessionId,
  }) async {
    final db = await _database.database;
    final eventId = _uuid.v4();
    final started = startedAt.millisecondsSinceEpoch;
    await db.transaction((transaction) async {
      await transaction.insert('play_events', {
        'event_id': eventId,
        'track_id': item.track.trackId,
        'media_file_id': item.preferredFile?.fileId,
        'session_id': sessionId,
        'started_at': started,
        'listened_duration_ms': 0,
        'track_duration_ms': item.track.durationMs,
        'completed': 0,
        'skipped': 0,
        'manually_selected': manuallySelected ? 1 : 0,
        'context_type': context.type,
        'context_id': context.id,
        'playback_mode': mode.dbValue,
      });
      final existing = await transaction.query(
        'track_stats',
        where: 'track_id = ?',
        whereArgs: [item.track.trackId],
        limit: 1,
      );
      if (existing.isEmpty) {
        await transaction.insert('track_stats', {
          'track_id': item.track.trackId,
          'play_count': 1,
          'completed_count': 0,
          'skip_count': 0,
          'manually_selected_count': manuallySelected ? 1 : 0,
          'total_play_duration_ms': 0,
          'last_played_at': started,
          'first_played_at': started,
          'updated_at': started,
        });
      } else {
        await transaction.rawUpdate(
          '''UPDATE track_stats
             SET play_count = play_count + 1,
                 manually_selected_count = manually_selected_count + ?,
                 last_played_at = ?,
                 first_played_at = COALESCE(first_played_at, ?),
                 updated_at = ?
             WHERE track_id = ?''',
          [
            manuallySelected ? 1 : 0,
            started,
            started,
            started,
            item.track.trackId,
          ],
        );
      }
    });
    return eventId;
  }

  Future<bool> finishPlayback({
    required String eventId,
    required DateTime endedAt,
    required Duration listenedDuration,
    required bool completed,
    required bool skipped,
  }) async {
    if (completed && skipped) {
      throw ArgumentError('A playback event cannot be completed and skipped');
    }
    final db = await _database.database;
    return db.transaction((transaction) async {
      final events = await transaction.query(
        'play_events',
        where: 'event_id = ?',
        whereArgs: [eventId],
        limit: 1,
      );
      if (events.isEmpty || events.single['ended_at'] != null) return false;
      final event = events.single;
      final ended = endedAt.millisecondsSinceEpoch;
      final trackDurationMs = event['track_duration_ms']! as int;
      final rawListenedMs = listenedDuration.inMilliseconds;
      final measuredListenedMs = trackDurationMs > 0
          ? rawListenedMs.clamp(0, trackDurationMs)
          : (rawListenedMs < 0 ? 0 : rawListenedMs);
      final persistedListenedMs = event['listened_duration_ms']! as int;
      final listenedMs = measuredListenedMs < persistedListenedMs
          ? persistedListenedMs
          : measuredListenedMs;
      final updated = await transaction.update(
        'play_events',
        {
          'ended_at': ended,
          'listened_duration_ms': listenedMs,
          'completed': completed ? 1 : 0,
          'skipped': skipped ? 1 : 0,
        },
        where: 'event_id = ? AND ended_at IS NULL',
        whereArgs: [eventId],
      );
      if (updated == 0) return false;
      await transaction.rawUpdate(
        '''UPDATE track_stats
           SET completed_count = completed_count + ?,
               skip_count = skip_count + ?,
               total_play_duration_ms = total_play_duration_ms + ?,
               last_skipped_at = CASE WHEN ? = 1 THEN ? ELSE last_skipped_at END,
               updated_at = ?
           WHERE track_id = ?''',
        [
          completed ? 1 : 0,
          skipped ? 1 : 0,
          listenedMs - persistedListenedMs,
          skipped ? 1 : 0,
          ended,
          ended,
          event['track_id'],
        ],
      );
      return true;
    });
  }

  Future<bool> checkpointPlayback({
    required String eventId,
    required Duration listenedDuration,
    required DateTime updatedAt,
  }) async {
    final db = await _database.database;
    return db.transaction((transaction) async {
      final events = await transaction.query(
        'play_events',
        where: 'event_id = ? AND ended_at IS NULL',
        whereArgs: [eventId],
        limit: 1,
      );
      if (events.isEmpty) return false;
      final event = events.single;
      final trackDurationMs = event['track_duration_ms']! as int;
      final rawListenedMs = listenedDuration.inMilliseconds;
      final listenedMs = trackDurationMs > 0
          ? rawListenedMs.clamp(0, trackDurationMs)
          : (rawListenedMs < 0 ? 0 : rawListenedMs);
      final persistedListenedMs = event['listened_duration_ms']! as int;
      if (listenedMs <= persistedListenedMs) return false;
      final updated = await transaction.update(
        'play_events',
        {'listened_duration_ms': listenedMs},
        where: 'event_id = ? AND ended_at IS NULL',
        whereArgs: [eventId],
      );
      if (updated == 0) return false;
      await transaction.rawUpdate(
        '''UPDATE track_stats
           SET total_play_duration_ms = total_play_duration_ms + ?,
               updated_at = ?
           WHERE track_id = ?''',
        [
          listenedMs - persistedListenedMs,
          updatedAt.millisecondsSinceEpoch,
          event['track_id'],
        ],
      );
      return true;
    });
  }

  Future<int> recoverInterruptedEvents(DateTime recoveredAt) async {
    final db = await _database.database;
    return db.update('play_events', {
      'ended_at': recoveredAt.millisecondsSinceEpoch,
      'completed': 0,
      'skipped': 0,
    }, where: 'ended_at IS NULL');
  }
}

bool _isAutomaticPlayback(
  String? contextType, {
  required bool manuallySelected,
}) =>
    contextType == 'home_quick_start' ||
    contextType == 'home_random' ||
    (contextType == 'home_smart_play' && !manuallySelected);

int _minutesApart(DateTime first, DateTime second) {
  final firstMinute = first.hour * 60 + first.minute;
  final secondMinute = second.hour * 60 + second.minute;
  final direct = (firstMinute - secondMinute).abs();
  return direct > 720 ? 1440 - direct : direct;
}

class _RecommendationSignalBuilder {
  _RecommendationSignalBuilder(this.trackId);

  final String trackId;
  int acceptedCount = 0;
  int rejectedCount = 0;
  int directAcceptedCount = 0;
  int recentExposureCount = 0;
  int matchingTimeAcceptedCount = 0;
  int lowEngagementCount = 0;
  int recentRejectStreak = 0;
  bool _recentOutcomeOpen = true;
  DateTime? lastAcceptedAt;
  DateTime? lastRejectedAt;

  void recordRecentOutcome({required bool accepted, required bool rejected}) {
    if (!_recentOutcomeOpen) return;
    if (rejected) {
      recentRejectStreak++;
    } else if (accepted) {
      _recentOutcomeOpen = false;
    }
  }

  RecommendationBehaviorSignal build() => RecommendationBehaviorSignal(
    trackId: trackId,
    acceptedCount: acceptedCount,
    rejectedCount: rejectedCount,
    directAcceptedCount: directAcceptedCount,
    recentExposureCount: recentExposureCount,
    matchingTimeAcceptedCount: matchingTimeAcceptedCount,
    lowEngagementCount: lowEngagementCount,
    recentRejectStreak: recentRejectStreak,
    lastAcceptedAt: lastAcceptedAt,
    lastRejectedAt: lastRejectedAt,
  );
}
