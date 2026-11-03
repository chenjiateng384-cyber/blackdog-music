import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/library_repository.dart';
import 'package:my_music_library/data/playback_history_repository.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/playback.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temp;
  late LibraryDatabase database;
  late PlaybackHistoryRepository history;
  late LibraryTrack item;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('playback-history-');
    database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    history = PlaybackHistoryRepository(database);
    item = await _seedTrack(database);
  });
  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  test('开始播放立即记录事件、手动选择、来源和模式', () async {
    final started = DateTime(2026, 8, 20, 10);
    final eventId = await history.beginPlayback(
      item: item,
      startedAt: started,
      manuallySelected: true,
      context: const PlaybackContext(type: 'playlist', id: 'workout'),
      mode: PlaybackMode.smartShuffle,
    );
    final db = await database.database;
    final event = (await db.query(
      'play_events',
      where: 'event_id = ?',
      whereArgs: [eventId],
    )).single;
    final stats = (await db.query('track_stats')).single;

    expect(event['started_at'], started.millisecondsSinceEpoch);
    expect(event['ended_at'], isNull);
    expect(event['manually_selected'], 1);
    expect(event['context_type'], 'playlist');
    expect(event['context_id'], 'workout');
    expect(event['playback_mode'], 'smartShuffle');
    expect(stats['play_count'], 1);
    expect(stats['manually_selected_count'], 1);
    expect(stats['first_played_at'], started.millisecondsSinceEpoch);
  });

  test('结束事件只聚合一次，重复完成不会重复增加统计', () async {
    final started = DateTime(2026, 8, 20, 10);
    final eventId = await history.beginPlayback(
      item: item,
      startedAt: started,
      manuallySelected: false,
      context: PlaybackContext.library,
      mode: PlaybackMode.sequential,
    );

    expect(
      await history.finishPlayback(
        eventId: eventId,
        endedAt: started.add(const Duration(seconds: 12)),
        listenedDuration: const Duration(seconds: 12),
        completed: false,
        skipped: true,
      ),
      isTrue,
    );
    expect(
      await history.finishPlayback(
        eventId: eventId,
        endedAt: started.add(const Duration(seconds: 20)),
        listenedDuration: const Duration(seconds: 20),
        completed: false,
        skipped: true,
      ),
      isFalse,
    );

    final db = await database.database;
    final event = (await db.query('play_events')).single;
    final stats = (await db.query('track_stats')).single;
    expect(event['listened_duration_ms'], 12000);
    expect(event['skipped'], 1);
    expect(stats['play_count'], 1);
    expect(stats['skip_count'], 1);
    expect(stats['total_play_duration_ms'], 12000);
  });

  test('异常退出留下的开放事件在下次启动被安全关闭', () async {
    await history.beginPlayback(
      item: item,
      startedAt: DateTime(2026, 8, 20, 10),
      manuallySelected: true,
      context: PlaybackContext.library,
      mode: PlaybackMode.sequential,
    );
    final recoveredAt = DateTime(2026, 8, 20, 11);

    expect(await history.recoverInterruptedEvents(recoveredAt), 1);
    final event = (await (await database.database).query('play_events')).single;
    expect(event['ended_at'], recoveredAt.millisecondsSinceEpoch);
    expect(event['completed'], 0);
    expect(event['skipped'], 0);
  });

  test('时长检查点与最终结束采用增量幂等汇总', () async {
    final started = DateTime(2026, 8, 20, 10);
    final eventId = await history.beginPlayback(
      item: item,
      startedAt: started,
      manuallySelected: false,
      context: const PlaybackContext(type: 'album', id: 'jay'),
      mode: PlaybackMode.sequential,
      sessionId: 'session-1',
    );

    expect(
      await history.checkpointPlayback(
        eventId: eventId,
        listenedDuration: const Duration(seconds: 15),
        updatedAt: started.add(const Duration(seconds: 15)),
      ),
      isTrue,
    );
    expect(
      await history.checkpointPlayback(
        eventId: eventId,
        listenedDuration: const Duration(seconds: 15),
        updatedAt: started.add(const Duration(seconds: 15)),
      ),
      isFalse,
    );
    await history.finishPlayback(
      eventId: eventId,
      endedAt: started.add(const Duration(seconds: 23)),
      listenedDuration: const Duration(seconds: 23),
      completed: false,
      skipped: false,
    );

    final db = await database.database;
    final event = (await db.query('play_events')).single;
    final stats = (await db.query('track_stats')).single;
    expect(event['listened_duration_ms'], 23000);
    expect(event['session_id'], 'session-1');
    expect(stats['total_play_duration_ms'], 23000);
  });

  test('有效历史数量忽略开放事件和零时长事件', () async {
    final started = DateTime(2026, 8, 20, 10);
    final validId = await history.beginPlayback(
      item: item,
      startedAt: started,
      manuallySelected: true,
      context: PlaybackContext.library,
      mode: PlaybackMode.sequential,
    );
    await history.finishPlayback(
      eventId: validId,
      endedAt: started.add(const Duration(seconds: 10)),
      listenedDuration: const Duration(seconds: 10),
      completed: false,
      skipped: true,
    );
    final zeroId = await history.beginPlayback(
      item: item,
      startedAt: started.add(const Duration(minutes: 1)),
      manuallySelected: false,
      context: PlaybackContext.library,
      mode: PlaybackMode.sequential,
    );
    await history.finishPlayback(
      eventId: zeroId,
      endedAt: started.add(const Duration(minutes: 1)),
      listenedDuration: Duration.zero,
      completed: false,
      skipped: false,
    );
    await history.beginPlayback(
      item: item,
      startedAt: started.add(const Duration(minutes: 2)),
      manuallySelected: false,
      context: PlaybackContext.library,
      mode: PlaybackMode.sequential,
    );

    expect(await history.validEventCount(), 1);
  });

  test('推荐信号只把真实听完或有意义的主动收听视为接受', () async {
    final now = DateTime(2026, 8, 20, 20, 30);
    final completedId = await history.beginPlayback(
      item: item,
      startedAt: now.subtract(const Duration(minutes: 30)),
      manuallySelected: false,
      context: const PlaybackContext(type: 'home_quick_start'),
      mode: PlaybackMode.sequential,
    );
    await history.finishPlayback(
      eventId: completedId,
      endedAt: now.subtract(const Duration(minutes: 28)),
      listenedDuration: const Duration(seconds: 95),
      completed: true,
      skipped: false,
    );
    final directId = await history.beginPlayback(
      item: item,
      startedAt: now.subtract(const Duration(minutes: 20)),
      manuallySelected: true,
      context: const PlaybackContext(type: 'search'),
      mode: PlaybackMode.sequential,
    );
    await history.finishPlayback(
      eventId: directId,
      endedAt: now.subtract(const Duration(minutes: 19)),
      listenedDuration: const Duration(seconds: 60),
      completed: false,
      skipped: false,
    );
    final skippedId = await history.beginPlayback(
      item: item,
      startedAt: now.subtract(const Duration(minutes: 10)),
      manuallySelected: false,
      context: const PlaybackContext(type: 'home_smart_play'),
      mode: PlaybackMode.sequential,
    );
    await history.finishPlayback(
      eventId: skippedId,
      endedAt: now.subtract(const Duration(minutes: 9)),
      listenedDuration: const Duration(seconds: 10),
      completed: false,
      skipped: true,
    );

    final signal = (await history.recommendationSignals(
      now: now,
    ))[item.track.trackId]!;
    expect(signal.acceptedCount, 2);
    expect(signal.directAcceptedCount, 1);
    expect(signal.rejectedCount, 1);
    expect(signal.recentExposureCount, 3);
    expect(signal.matchingTimeAcceptedCount, 2);
    expect(signal.isTemporarilySuppressedAt(now), isFalse);
  });

  test('历史自动播放即使误记为手动选择也不会污染直接偏好', () async {
    final now = DateTime(2026, 8, 20, 20, 30);
    final eventId = await history.beginPlayback(
      item: item,
      startedAt: now.subtract(const Duration(minutes: 2)),
      manuallySelected: true,
      context: const PlaybackContext(type: 'home_quick_start'),
      mode: PlaybackMode.sequential,
    );
    await history.finishPlayback(
      eventId: eventId,
      endedAt: now.subtract(const Duration(minutes: 1)),
      listenedDuration: const Duration(seconds: 60),
      completed: false,
      skipped: false,
    );

    final signal = (await history.recommendationSignals(
      now: now,
    ))[item.track.trackId]!;
    expect(signal.acceptedCount, 0);
    expect(signal.directAcceptedCount, 0);
    expect(signal.recentExposureCount, 1);
  });

  test('近期连续跳过可压过更早的接受记录，短暂自动收听只作为弱负反馈', () async {
    final now = DateTime(2026, 8, 20, 20, 30);
    final acceptedId = await history.beginPlayback(
      item: item,
      startedAt: now.subtract(const Duration(days: 10)),
      manuallySelected: true,
      context: const PlaybackContext(type: 'search'),
      mode: PlaybackMode.sequential,
    );
    await history.finishPlayback(
      eventId: acceptedId,
      endedAt: now.subtract(const Duration(days: 10, minutes: -2)),
      listenedDuration: const Duration(seconds: 95),
      completed: true,
      skipped: false,
    );
    for (final minutes in [10, 5]) {
      final skippedId = await history.beginPlayback(
        item: item,
        startedAt: now.subtract(Duration(minutes: minutes)),
        manuallySelected: false,
        context: const PlaybackContext(type: 'home_quick_start'),
        mode: PlaybackMode.sequential,
      );
      await history.finishPlayback(
        eventId: skippedId,
        endedAt: now.subtract(Duration(minutes: minutes - 1)),
        listenedDuration: const Duration(seconds: 12),
        completed: false,
        skipped: true,
      );
    }
    final lowEngagementId = await history.beginPlayback(
      item: item,
      startedAt: now.subtract(const Duration(minutes: 2)),
      manuallySelected: false,
      context: const PlaybackContext(type: 'home_smart_play'),
      mode: PlaybackMode.sequential,
    );
    await history.finishPlayback(
      eventId: lowEngagementId,
      endedAt: now.subtract(const Duration(minutes: 1)),
      listenedDuration: const Duration(seconds: 25),
      completed: false,
      skipped: false,
    );

    final signal = (await history.recommendationSignals(
      now: now,
    ))[item.track.trackId]!;
    expect(signal.acceptedCount, 1);
    expect(signal.rejectedCount, 2);
    expect(signal.lowEngagementCount, 1);
    expect(signal.recentRejectStreak, 2);
    expect(signal.hasReliableAcceptance, isFalse);
    expect(signal.isTemporarilySuppressedAt(now), isTrue);
  });
}

Future<LibraryTrack> _seedTrack(LibraryDatabase database) async {
  const trackId = '11111111-2222-4333-8444-555555555555';
  const fileId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
  final now = DateTime(2026, 8, 20);
  final library = LibraryRepository(database);
  await library.createTrack(
    Track(
      trackId: trackId,
      title: '稻香',
      artistDisplay: '周杰伦',
      albumArtistDisplay: '周杰伦',
      albumDisplay: '魔杰座',
      durationMs: 100000,
      metadataState: 'complete',
      addedAt: now,
      updatedAt: now,
    ),
  );
  await library.saveMediaFile(
    MediaFile(
      fileId: fileId,
      trackId: trackId,
      contentUri: 'content://music/稻香',
      filename: '03_稻香.flac',
      normalizedFilename: '03_稻香.flac',
      extension: 'flac',
      mimeType: 'audio/flac',
      sizeBytes: 1000,
      durationMs: 100000,
      hashState: 'ready',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await library.setPreferredMediaFile(trackId, fileId);
  return (await library.libraryTrackById(trackId))!;
}
