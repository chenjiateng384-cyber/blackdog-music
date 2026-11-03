import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/library_repository.dart';
import 'package:my_music_library/data/playback_history_repository.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/playback.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:my_music_library/services/playback_history_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temp;
  late LibraryDatabase database;
  late LibraryTrack item;
  late DateTime now;
  late Duration elapsed;
  late PlaybackHistoryService service;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('playback-service-');
    database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    item = await _seedTrack(database);
    now = DateTime(2026, 8, 20, 10);
    elapsed = Duration.zero;
    service = PlaybackHistoryService(
      PlaybackHistoryRepository(database),
      now: () => now,
      monotonicNow: () => elapsed,
    );
  });
  tearDown(() async {
    service.dispose();
    await database.close();
    await temp.delete(recursive: true);
  });

  test('20 秒内主动下一首计为快速跳过', () async {
    await service.start(
      item: item,
      manuallySelected: true,
      context: const PlaybackContext(type: 'playlist', id: 'fitness'),
      mode: PlaybackMode.shuffle,
    );
    service.setPlaying(true);
    now = now.add(const Duration(seconds: 12));
    elapsed += const Duration(seconds: 12);
    await service.finish(PlaybackEndReason.userSkipped);

    final db = await database.database;
    final event = (await db.query('play_events')).single;
    final stats = (await db.query('track_stats')).single;
    expect(event['listened_duration_ms'], 12000);
    expect(event['skipped'], 1);
    expect(event['context_type'], 'playlist');
    expect(event['context_id'], 'fitness');
    expect(event['playback_mode'], 'shuffle');
    expect(stats['skip_count'], 1);
    expect(stats['manually_selected_count'], 1);
  });

  test('自动播放约四十五秒后主动切歌仍会形成明确负反馈', () async {
    await service.start(
      item: item,
      manuallySelected: false,
      context: const PlaybackContext(type: 'home_quick_start'),
      mode: PlaybackMode.shuffle,
    );
    service.setPlaying(true);
    now = now.add(const Duration(seconds: 45));
    elapsed += const Duration(seconds: 45);
    await service.finish(PlaybackEndReason.userSkipped);

    final db = await database.database;
    final event = (await db.query('play_events')).single;
    final stats = (await db.query('track_stats')).single;
    expect(event['skipped'], 1);
    expect(stats['skip_count'], 1);
  });

  test('达到歌曲时长 90% 即计为完整播放，不再计跳过', () async {
    await service.start(
      item: item,
      manuallySelected: false,
      context: PlaybackContext.library,
      mode: PlaybackMode.sequential,
    );
    service.setPlaying(true);
    now = now.add(const Duration(seconds: 91));
    elapsed += const Duration(seconds: 91);
    await service.finish(PlaybackEndReason.userSelectedAnother);

    final db = await database.database;
    final event = (await db.query('play_events')).single;
    final stats = (await db.query('track_stats')).single;
    expect(event['completed'], 1);
    expect(event['skipped'], 0);
    expect(stats['completed_count'], 1);
    expect(stats['skip_count'], 0);
    expect(stats['total_play_duration_ms'], 91000);
  });

  test('暂停期间不累计实际播放时长', () async {
    await service.start(
      item: item,
      manuallySelected: true,
      context: PlaybackContext.library,
      mode: PlaybackMode.repeatAll,
    );
    service.setPlaying(true);
    now = now.add(const Duration(seconds: 10));
    elapsed += const Duration(seconds: 10);
    service.setPlaying(false);
    now = now.add(const Duration(seconds: 30));
    elapsed += const Duration(seconds: 30);
    service.setPlaying(true);
    now = now.add(const Duration(seconds: 5));
    elapsed += const Duration(seconds: 5);
    await service.finish(PlaybackEndReason.stopped);

    final event = (await (await database.database).query('play_events')).single;
    expect(event['listened_duration_ms'], 15000);
    expect(event['completed'], 0);
    expect(event['skipped'], 0);
  });

  test('切换歌曲会先结束前一首事件，再开始新事件', () async {
    await service.start(
      item: item,
      manuallySelected: true,
      context: PlaybackContext.library,
      mode: PlaybackMode.sequential,
    );
    service.setPlaying(true);
    now = now.add(const Duration(seconds: 5));
    elapsed += const Duration(seconds: 5);
    await service.start(
      item: item,
      manuallySelected: false,
      context: PlaybackContext.library,
      mode: PlaybackMode.repeatOne,
    );

    final events = await (await database.database).query(
      'play_events',
      orderBy: 'started_at, rowid',
    );
    expect(events, hasLength(2));
    expect(events.first['ended_at'], isNotNull);
    expect(events.first['skipped'], 1);
    expect(events.last['ended_at'], isNull);
    expect(events.last['playback_mode'], 'repeatOne');
  });

  test('播放历史写入后立即通知首页数据刷新', () async {
    var changes = 0;
    service.dispose();
    service = PlaybackHistoryService(
      PlaybackHistoryRepository(database),
      now: () => now,
      monotonicNow: () => elapsed,
      onHistoryChanged: () => changes += 1,
    );

    await service.start(
      item: item,
      manuallySelected: true,
      context: PlaybackContext.library,
      mode: PlaybackMode.sequential,
    );
    expect(changes, 1);

    await service.finish(PlaybackEndReason.stopped);
    expect(changes, 2);
  });

  test('检查点增量保存时长，最终结束只补尚未保存的差额', () async {
    await service.start(
      item: item,
      manuallySelected: true,
      context: const PlaybackContext(type: 'search'),
      mode: PlaybackMode.sequential,
    );
    service.setPlaying(true);
    elapsed += const Duration(seconds: 16);
    now = now.add(const Duration(seconds: 16));
    await service.checkpoint();
    await service.checkpoint();

    var db = await database.database;
    var event = (await db.query('play_events')).single;
    var stats = (await db.query('track_stats')).single;
    expect(event['listened_duration_ms'], 16000);
    expect(stats['total_play_duration_ms'], 16000);

    elapsed += const Duration(seconds: 5);
    now = now.add(const Duration(seconds: 5));
    await service.finish(PlaybackEndReason.stopped);
    db = await database.database;
    event = (await db.query('play_events')).single;
    stats = (await db.query('track_stats')).single;
    expect(event['listened_duration_ms'], 21000);
    expect(stats['total_play_duration_ms'], 21000);
  });

  test('连续听歌共用会话 ID，明确停止后创建新会话', () async {
    await service.start(
      item: item,
      manuallySelected: true,
      context: PlaybackContext.library,
      mode: PlaybackMode.sequential,
    );
    await service.finish(PlaybackEndReason.userSelectedAnother);
    await service.start(
      item: item,
      manuallySelected: false,
      context: PlaybackContext.library,
      mode: PlaybackMode.sequential,
    );
    await service.finish(PlaybackEndReason.stopped);
    await service.start(
      item: item,
      manuallySelected: true,
      context: PlaybackContext.library,
      mode: PlaybackMode.sequential,
    );

    final events = await (await database.database).query(
      'play_events',
      orderBy: 'started_at, rowid',
    );
    expect(events[0]['session_id'], isNotNull);
    expect(events[1]['session_id'], events[0]['session_id']);
    expect(events[2]['session_id'], isNot(events[1]['session_id']));
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
