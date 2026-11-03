import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/controllers/app_controller.dart';
import 'package:my_music_library/data/file_identity_repository.dart';
import 'package:my_music_library/data/library_repository.dart';
import 'package:my_music_library/data/migration_repository.dart';
import 'package:my_music_library/data/playback_history_repository.dart';
import 'package:my_music_library/data/playlist_repository.dart';
import 'package:my_music_library/data/scan_repository.dart';
import 'package:my_music_library/models/song.dart';
import 'package:my_music_library/models/v4/library_entities.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/listening_data.dart';
import 'package:my_music_library/models/v4/playback.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:my_music_library/services/harmony_backup_service.dart';
import 'package:my_music_library/models/v4/data_safety.dart';
import 'package:my_music_library/services/library_scan_service.dart';
import 'package:my_music_library/services/music_audio_handler.dart';
import 'package:my_music_library/services/music_platform.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('旧 UI 控制器优先读取 V4 Track，喜欢和编辑不再写回 Legacy Song 核心', () async {
    final temp = await Directory.systemTemp.createTemp('controller-v4-');
    final database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    final repository = LibraryRepository(database);
    final handler = MusicAudioHandler();
    final now = DateTime(2026, 8, 20);
    const trackId = '11111111-2222-4333-8444-555555555555';
    const fileId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    await repository.createTrack(
      Track(
        trackId: trackId,
        title: '稻香',
        artistDisplay: '周杰伦',
        albumArtistDisplay: '周杰伦',
        albumDisplay: '魔杰座',
        durationMs: 223000,
        metadataState: 'complete',
        addedAt: now,
        updatedAt: now,
      ),
    );
    await repository.saveMediaFile(
      MediaFile(
        fileId: fileId,
        trackId: trackId,
        documentUri: 'content://tree/music/稻香.flac',
        filename: '03_稻香.flac',
        normalizedFilename: '03_稻香.flac',
        extension: 'flac',
        mimeType: 'audio/flac',
        sizeBytes: 30000000,
        durationMs: 223000,
        hashState: 'ready',
        status: 'active',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repository.setPreferredMediaFile(trackId, fileId);
    await (await database.database).insert('track_overrides', {
      'track_id': trackId,
      'year': 2008,
      'track_number': 3,
      'updated_at': now.millisecondsSinceEpoch,
    });
    final controller = AppController(
      platform: _FailIfLegacyScanned(),
      database: database,
      audioHandler: handler,
    );
    addTearDown(() async {
      controller.dispose();
      await handler.disposeHandler();
      await database.close();
      await temp.delete(recursive: true);
    });

    await controller.refresh();

    expect(controller.error, isNull);
    expect(controller.libraryTracks.single.track.trackId, trackId);
    expect(controller.songs.single.title, '稻香');
    expect(handler.queueTrackIds, [trackId]);
    expect(controller.libraryCounts.trackCount, 1);
    expect(controller.recentlyAddedTracks.single.track.trackId, trackId);

    await controller.searchLibrary('稻香');
    expect(controller.searchResults.tracks.single.track.trackId, trackId);

    final compatibleSong = controller.songs.single;
    await controller.toggleFavorite(compatibleSong);
    expect((await repository.likedTracks()).single.track.trackId, trackId);
    expect(controller.likedTracks.single.track.trackId, trackId);
    expect(controller.libraryCounts.likedCount, 1);

    handler.setTrackLibrary(
      controller.libraryTracks,
      context: const PlaybackContext(type: 'playlist', id: 'night'),
    );
    await controller.refresh();
    expect(handler.queueSnapshot.context.type, 'playlist');
    expect(handler.queueSnapshot.context.id, 'night');

    await controller.searchLibrary('稻香');
    expect(controller.searchResults.tracks.single.preference.liked, isTrue);
    await controller.toggleTrackLiked(controller.searchResults.tracks.single);
    expect(controller.searchResults.tracks.single.preference.liked, isFalse);
    expect(controller.libraryCounts.likedCount, 0);
    await controller.toggleTrackLiked(controller.searchResults.tracks.single);
    expect(controller.searchResults.tracks.single.preference.liked, isTrue);
    expect(controller.libraryCounts.likedCount, 1);

    await controller.editSongInfo(
      compatibleSong,
      title: '稻香（人工）',
      artist: '周杰伦',
      album: '魔杰座',
    );
    expect(controller.songs.single.title, '稻香（人工）');
    expect(handler.queueTrackIds, [trackId]);
    expect(await database.songOverrides(), isEmpty);
    final override = (await (await database.database).query(
      'track_overrides',
      where: 'track_id = ?',
      whereArgs: [trackId],
    )).single;
    expect(override['year'], 2008);
    expect(override['track_number'], 3);

    await controller.createCategory('健身');
    final category = controller.categories.singleWhere(
      (item) => item.name == '健身',
    );
    await controller.setSongInCategory(category.id, compatibleSong.id, true);
    final playlistRepository = PlaylistRepository(database);
    final playlist = await playlistRepository.playlistForLegacyCategory(
      category.id,
    );
    expect(playlist, isNotNull);
    expect(
      (await repository.tracksForPlaylist(playlist!.playlistId))
          .map((item) => item.track.trackId),
      [trackId],
    );

    await controller.createPlaylist('夜晚');
    expect(
      controller.playlistSummaries.any((item) => item.playlist.name == '夜晚'),
      isTrue,
    );
  });

  test('首页集合播放建立独立队列并记录首页来源', () async {
    final handler = _RecordingAudioHandler();
    final controller = AppController(audioHandler: handler);
    final playable = _homeTrack('playable', playable: true);
    final unavailable = _homeTrack('unavailable', playable: false);
    addTearDown(() async {
      controller.dispose();
      await handler.disposeHandler();
    });

    await controller.playHomeCollection([
      playable,
      unavailable,
    ], contextType: 'home_today');

    expect(handler.queued.map((item) => item.track.trackId), ['playable']);
    expect(handler.queueContext?.type, 'home_today');
    expect(handler.played?.track.trackId, 'playable');
    expect(handler.playContext?.type, 'home_today');
    expect(controller.currentLibraryTrack?.track.trackId, 'playable');
  });

  test('随心听建立短动态队列，重复点击当前会话不会切歌', () async {
    final handler = _RecordingAudioHandler();
    final controller = AppController(
      audioHandler: handler,
      now: () => DateTime(2026, 8, 31, 18),
      homeRandom: Random(7),
    );
    final tracks = [
      _homeTrack('first', playable: true),
      _homeTrack('second', playable: true),
      _homeTrack('third', playable: true),
    ];
    addTearDown(() async {
      controller.dispose();
      await handler.disposeHandler();
    });

    await controller.playHomeCollection(
      tracks,
      contextType: 'home_quick_start',
    );
    final firstTrackId = handler.played!.track.trackId;
    expect(handler.queued.map((item) => item.track.trackId).toSet(), {
      'first',
      'second',
      'third',
    });
    expect(handler.queueContext?.id, startsWith('20260831-'));
    expect(handler.playCalls, 1);
    expect(handler.playedManuallySelected, isFalse);

    await controller.playHomeCollection(
      tracks,
      contextType: 'home_quick_start',
    );
    expect(handler.played!.track.trackId, firstTrackId);
    expect(handler.playCalls, 1);
    expect(controller.homeQuickStartActive, isTrue);

    await controller.playTrackCollection([
      _homeTrack('outside', playable: true),
    ], contextType: 'library');
    await controller.playHomeCollection(
      tracks,
      contextType: 'home_quick_start',
    );
    expect(handler.played!.track.trackId, isNot(firstTrackId));
    expect(handler.playCalls, 3);
  });

  test('随心听不会等待音频文件加载完成才提供播放页数据', () async {
    final handler = _DelayedRecordingAudioHandler();
    final controller = AppController(
      audioHandler: handler,
      now: () => DateTime(2026, 8, 31, 18),
    );
    final track = _homeTrack('instant', playable: true);
    addTearDown(() async {
      if (!handler.release.isCompleted) handler.release.complete();
      controller.dispose();
      await handler.disposeHandler();
    });

    final playback = controller.playHomeCollection([
      track,
    ], contextType: 'home_quick_start');

    expect(controller.currentLibraryTrack?.track.trackId, 'instant');
    expect(controller.currentSong?.title, 'instant');
    expect(controller.playerPageKind, PlayerPageKind.crystal);
    handler.release.complete();
    await playback;
  });

  test('随心听播放五首后提前追加八首且不改变当前播放位置', () async {
    final temp = await Directory.systemTemp.createTemp('quick-radio-');
    final database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    final repository = LibraryRepository(database);
    final handler = _RollingQueueAudioHandler();
    for (var index = 0; index < 30; index++) {
      final suffix = index.toString().padLeft(12, '0');
      final track = _homeTrack(
        '00000000-0000-4000-8000-$suffix',
        playable: true,
        fileId: '10000000-0000-4000-8000-$suffix',
      );
      await repository.createTrack(track.track);
      await repository.saveMediaFile(track.preferredFile!);
      await repository.setPreferredMediaFile(
        track.track.trackId,
        track.preferredFile!.fileId,
      );
    }
    final controller = AppController(
      platform: _FailIfLegacyScanned(),
      database: database,
      audioHandler: handler,
      now: () => DateTime(2026, 9, 7, 20),
      homeRandom: Random(13),
    );
    addTearDown(() async {
      controller.dispose();
      await handler.disposeHandler();
      await database.close();
      await temp.delete(recursive: true);
    });

    await controller.initialize();
    await controller.playHomeCollection(
      controller.libraryTracks,
      contextType: 'home_quick_start',
    );
    expect(handler.queueSnapshot.entries, hasLength(12));

    handler.advanceTo(4);
    for (
      var attempt = 0;
      attempt < 40 && handler.batchAppendCalls == 0;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(handler.batchAppendCalls, 1);
    expect(handler.queueSnapshot.currentIndex, 4);
    expect(handler.queueSnapshot.entries, hasLength(20));
    expect(
      handler.queueSnapshot.entries
          .map((entry) => entry.track.track.trackId)
          .toSet(),
      hasLength(20),
    );
    expect(handler.queueSnapshot.context.type, 'home_quick_start');
  });

  test('智能播放池同日跨控制器恢复，跨日自动更新', () async {
    final temp = await Directory.systemTemp.createTemp('smart-play-pool-');
    final database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    final repository = LibraryRepository(database);
    for (var index = 0; index < 36; index++) {
      final suffix = index.toString().padLeft(12, '0');
      final track = _homeTrack(
        '20000000-0000-4000-8000-$suffix',
        playable: true,
        fileId: '30000000-0000-4000-8000-$suffix',
      );
      await repository.createTrack(track.track);
      await repository.saveMediaFile(track.preferredFile!);
      await repository.setPreferredMediaFile(
        track.track.trackId,
        track.preferredFile!.fileId,
      );
    }
    final oldPoolIds = (await repository.allTracks())
        .take(27)
        .map((track) => track.track.trackId)
        .toList();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'harmony.home_smart_play_pool.v1',
      jsonEncode({'date': '2026-09-07', 'trackIds': oldPoolIds}),
    );
    var now = DateTime(2026, 9, 7, 20);
    final firstHandler = MusicAudioHandler();
    final firstController = AppController(
      platform: _FailIfLegacyScanned(),
      database: database,
      audioHandler: firstHandler,
      now: () => now,
    );
    await firstController.refresh();
    final firstIds = firstController.homePlayCountTracks
        .map((track) => track.track.trackId)
        .toList(growable: false);
    expect(firstIds, isNot(oldPoolIds));
    expect(
      (jsonDecode(preferences.getString('harmony.home_smart_play_pool.v1')!)
          as Map)['algorithmVersion'],
      2,
    );
    firstController.dispose();
    await firstHandler.disposeHandler();

    final secondHandler = MusicAudioHandler();
    final secondController = AppController(
      platform: _FailIfLegacyScanned(),
      database: database,
      audioHandler: secondHandler,
      now: () => now,
    );
    addTearDown(() async {
      secondController.dispose();
      await secondHandler.disposeHandler();
      await database.close();
      await temp.delete(recursive: true);
    });

    await secondController.refresh();
    final restoredIds = secondController.homePlayCountTracks
        .map((track) => track.track.trackId)
        .toList(growable: false);
    expect(firstIds, hasLength(27));
    expect(restoredIds, firstIds);

    now = DateTime(2026, 9, 8, 8);
    await secondController.refreshPlaybackExperience();
    final nextDayIds = secondController.homePlayCountTracks
        .map((track) => track.track.trackId)
        .toList(growable: false);
    expect(nextDayIds, hasLength(27));
    expect(nextDayIds, isNot(firstIds));
    final manualOnly = secondController.homePlayCountTracks.first;
    await secondController.setTrackManualOnly(manualOnly, true);
    await Future.wait([
      secondController.refreshExperience(),
      secondController.refreshPlaybackExperience(),
    ]);
    expect(
      secondController.homePlayCountTracks.map((track) => track.track.trackId),
      isNot(contains(manualOnly.track.trackId)),
    );
  });

  test('普通资料刷新不会打乱当天智能播放池', () async {
    final temp = await Directory.systemTemp.createTemp('smart-play-stable-');
    final database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    final repository = LibraryRepository(database);
    for (var index = 0; index < 40; index++) {
      final suffix = index.toString().padLeft(12, '0');
      final track = _homeTrack(
        '40000000-0000-4000-8000-$suffix',
        playable: true,
        fileId: '50000000-0000-4000-8000-$suffix',
      );
      await repository.createTrack(track.track);
      await repository.saveMediaFile(track.preferredFile!);
      await repository.setPreferredMediaFile(
        track.track.trackId,
        track.preferredFile!.fileId,
      );
    }
    final handler = MusicAudioHandler();
    final controller = AppController(
      platform: _FailIfLegacyScanned(),
      database: database,
      audioHandler: handler,
      now: () => DateTime(2026, 9, 7, 20),
    );
    addTearDown(() async {
      controller.dispose();
      await handler.disposeHandler();
      await database.close();
      await temp.delete(recursive: true);
    });

    await controller.refresh();
    final before = controller.homePlayCountTracks
        .map((track) => track.track.trackId)
        .toList(growable: false);
    final outsidePool = controller.libraryTracks.firstWhere(
      (track) => !before.contains(track.track.trackId),
    );
    await controller.toggleTrackLiked(outsidePool);
    final after = controller.homePlayCountTracks
        .map((track) => track.track.trackId)
        .toList(growable: false);

    expect(after, before);

    final history = PlaybackHistoryRepository(database);
    final historyTrack = controller.libraryTracks.first;
    final startedAt = DateTime(2026, 9, 7, 10);
    for (var index = 0; index < 35; index++) {
      final eventId = await history.beginPlayback(
        item: historyTrack,
        startedAt: startedAt.add(Duration(minutes: index * 3)),
        manuallySelected: true,
        context: const PlaybackContext(type: 'search'),
        mode: PlaybackMode.sequential,
      );
      await history.finishPlayback(
        eventId: eventId,
        endedAt: startedAt.add(Duration(minutes: index * 3 + 2)),
        listenedDuration: const Duration(seconds: 100),
        completed: true,
        skipped: false,
      );
    }
    await controller.refreshPlaybackExperience();
    final afterHistoryGrowth = controller.homePlayCountTracks
        .map((track) => track.track.trackId)
        .toList(growable: false);
    expect(afterHistoryGrowth, before);
  });

  test('下拉刷新合并请求、保存结果且不改变播放队列和位置', () async {
    final temp = await Directory.systemTemp.createTemp('smart-play-refresh-');
    final database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    final repository = LibraryRepository(database);
    for (var i = 0; i < 80; i++) {
      final suffix = i.toString().padLeft(12, '0');
      final track = _homeTrack(
        '60000000-0000-4000-8000-$suffix',
        playable: true,
        fileId: '70000000-0000-4000-8000-$suffix',
      );
      await repository.createTrack(track.track);
      await repository.saveMediaFile(track.preferredFile!);
      await repository.setPreferredMediaFile(
        track.track.trackId,
        track.preferredFile!.fileId,
      );
    }
    final handler = _RollingQueueAudioHandler();
    final controller = AppController(
      platform: _FailIfLegacyScanned(),
      database: database,
      audioHandler: handler,
      now: () => DateTime(2026, 9, 7, 20),
    );
    final restoredHandler = MusicAudioHandler();
    final restored = AppController(
      platform: _FailIfLegacyScanned(),
      database: database,
      audioHandler: restoredHandler,
      now: () => DateTime(2026, 9, 7, 20),
    );
    addTearDown(() async {
      controller.dispose();
      restored.dispose();
      await handler.disposeHandler();
      await restoredHandler.disposeHandler();
      await database.close();
      await temp.delete(recursive: true);
    });
    await controller.refresh();
    final tracks = controller.homePlayCountTracks;
    final before = tracks.map((track) => track.track.trackId).toList();
    await controller.playTrackCollection(
      tracks,
      startTrack: tracks.first,
      contextType: 'home_smart_play',
    );
    handler.playbackState.add(
      PlaybackState(updatePosition: const Duration(seconds: 37)),
    );
    final snapshot = handler.queueSnapshot;
    controller.markSmartPlayVisibleTracks(before.take(3));
    controller.markSmartPlayVisibleTracks(const []);
    final firstRefresh = controller.refreshHomeRecommendations();
    final repeatedRefresh = controller.refreshHomeRecommendations();
    expect(identical(firstRefresh, repeatedRefresh), isTrue);
    await controller.refreshPlaybackExperience();
    await firstRefresh;
    final after = controller.homePlayCountTracks
        .map((track) => track.track.trackId)
        .toList();
    expect(
      after.where((id) => !before.contains(id)).length,
      inInclusiveRange(6, 9),
    );
    expect(after.first, before.first);
    expect(before, isNot(contains(after[1])));
    expect(before, isNot(contains(after[2])));
    expect(identical(handler.queueSnapshot, snapshot), isTrue);
    expect(controller.currentLibraryTrack?.track.trackId, before.first);
    expect(
      handler.playbackState.value.updatePosition,
      const Duration(seconds: 37),
    );
    final preferences = await SharedPreferences.getInstance();
    final saved = jsonDecode(
      preferences.getString('harmony.home_smart_play_pool.v1')!,
    ) as Map;
    expect(saved['refreshSerial'], 1);
    await restored.refresh();
    expect(
      restored.homePlayCountTracks.map((track) => track.track.trackId).toList(),
      after,
    );
    await restored.refreshExperience();
    expect(
      restored.homePlayCountTracks.map((track) => track.track.trackId).toList(),
      after,
    );
    await restored.refreshHomeRecommendations();
    expect(
      restored.homePlayCountTracks.map((track) => track.track.trackId).toList(),
      isNot(after),
    );
    expect(
      (jsonDecode(preferences.getString('harmony.home_smart_play_pool.v1')!)
          as Map)['refreshSerial'],
      2,
    );
  });

  test('首页随机播放不会选到仅手动播放歌曲', () async {
    final handler = _RecordingAudioHandler();
    final controller = AppController(
      audioHandler: handler,
      homeRandom: Random(1),
    );
    final manualOnly = _homeTrack(
      'manual-only-random',
      playable: true,
      recommendationExcluded: true,
    );
    final normal = _homeTrack('normal-random', playable: true);
    controller.libraryTracks = [manualOnly, normal];
    addTearDown(() async {
      controller.dispose();
      await handler.disposeHandler();
    });

    final selected = await controller.playHomeRandom();

    expect(selected?.track.trackId, normal.track.trackId);
    expect(handler.queued.map((track) => track.track.trackId), [
      normal.track.trackId,
    ]);
  });

  test('播放页类型同步跟随最新来源，不受异步队列快照影响', () async {
    final handler = _RecordingAudioHandler();
    final controller = AppController(audioHandler: handler);
    final track = _homeTrack('route', playable: true);
    addTearDown(() async {
      controller.dispose();
      await handler.disposeHandler();
    });

    await controller.playTrackCollection(
      [track],
      contextType: 'home_quick_start',
      startTrack: track,
    );
    expect(controller.playerPageKind, PlayerPageKind.crystal);

    await controller.playTrackCollection(
      [track],
      contextType: 'library',
      startTrack: track,
    );
    expect(controller.playerPageKind, PlayerPageKind.immersive);
  });

  test('重复点当前暂停歌曲只继续播放，不重新加载而丢失进度', () async {
    final handler = _RecordingAudioHandler();
    final controller = AppController(audioHandler: handler);
    final track = _homeTrack('resume-current', playable: true);
    addTearDown(() async {
      controller.dispose();
      await handler.disposeHandler();
    });

    await controller.playTrackCollection(
      [track],
      contextType: 'search',
      startTrack: track,
    );
    await controller.playTrackCollection(
      [track],
      contextType: 'search',
      startTrack: track,
    );

    expect(handler.playCalls, 1);
    expect(handler.resumeCalls, 1);
  });

  test('启动恢复最后歌曲和保存位置，但不会自动开始播放', () async {
    final temp = await Directory.systemTemp.createTemp('playback-session-');
    final database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    final repository = LibraryRepository(database);
    const trackId = '11111111-2222-4333-8444-777777777777';
    const fileId = 'aaaaaaaa-bbbb-4ccc-8ddd-777777777777';
    final track = _homeTrack(trackId, playable: true, fileId: fileId);
    await repository.createTrack(track.track);
    await repository.saveMediaFile(track.preferredFile!);
    await repository.setPreferredMediaFile(
      track.track.trackId,
      track.preferredFile!.fileId,
    );
    SharedPreferences.setMockInitialValues({
      'harmony.playback_session.v1': jsonEncode({
        'trackId': track.track.trackId,
        'positionMs': 73500,
        'contextType': 'search',
      }),
    });
    final handler = _RecordingAudioHandler();
    final controller = AppController(
      platform: _FailIfLegacyScanned(),
      database: database,
      audioHandler: handler,
    );
    addTearDown(() async {
      controller.dispose();
      await handler.disposeHandler();
      await database.close();
      await temp.delete(recursive: true);
    });

    await controller.initialize();

    expect(controller.currentLibraryTrack?.track.trackId, trackId);
    expect(controller.currentSong?.title, trackId);
    expect(handler.restored?.track.trackId, trackId);
    expect(handler.restoredPosition, const Duration(milliseconds: 73500));
    expect(handler.playCalls, 0);
    expect(handler.resumeCalls, 0);
  });

  test('恢复的随心听歌曲不会把整座音乐库误当成仍在运行的电台队列', () async {
    final temp = await Directory.systemTemp.createTemp('restored-radio-');
    final database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    final repository = LibraryRepository(database);
    const trackId = '11111111-2222-4333-8444-888888888888';
    const fileId = 'aaaaaaaa-bbbb-4ccc-8ddd-888888888888';
    final track = _homeTrack(trackId, playable: true, fileId: fileId);
    await repository.createTrack(track.track);
    await repository.saveMediaFile(track.preferredFile!);
    await repository.setPreferredMediaFile(trackId, fileId);
    SharedPreferences.setMockInitialValues({
      'harmony.playback_session.v1': jsonEncode({
        'trackId': trackId,
        'positionMs': 12000,
        'contextType': 'home_quick_start',
        'contextId': '20260920-1',
      }),
    });
    final handler = _RecordingAudioHandler();
    final controller = AppController(
      platform: _FailIfLegacyScanned(),
      database: database,
      audioHandler: handler,
      now: () => DateTime(2026, 9, 21, 18),
    );
    addTearDown(() async {
      controller.dispose();
      await handler.disposeHandler();
      await database.close();
      await temp.delete(recursive: true);
    });

    await controller.initialize();

    expect(controller.playerPageKind, PlayerPageKind.crystal);
    expect(controller.homeQuickStartActive, isFalse);

    await controller.playHomeCollection(
      controller.libraryTracks,
      contextType: 'home_quick_start',
    );

    expect(controller.homeQuickStartActive, isTrue);
    expect(handler.queueContext?.type, 'home_quick_start');
    expect(handler.queueContext?.id, startsWith('20260921-'));
  });

  test('已有扫描目录时启动只读取缓存音乐库，不自动递归重扫文件', () async {
    final temp = await Directory.systemTemp.createTemp('startup-no-scan-');
    final database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    final repository = LibraryRepository(database);
    final handler = MusicAudioHandler();
    const trackId = '11111111-2222-4333-8444-666666666666';
    const fileId = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff';
    final now = DateTime(2026, 8, 20);
    final cachedTrack = Track(
      trackId: trackId,
      title: '缓存歌曲',
      artistDisplay: '周杰伦',
      albumArtistDisplay: '周杰伦',
      albumDisplay: '专辑',
      durationMs: 180000,
      metadataState: 'complete',
      addedAt: now,
      updatedAt: now,
    );
    final cachedFile = MediaFile(
      fileId: fileId,
      trackId: trackId,
      contentUri: 'content://music/cached',
      filename: '缓存歌曲.flac',
      normalizedFilename: '缓存歌曲.flac',
      extension: 'flac',
      mimeType: 'audio/flac',
      sizeBytes: 1000,
      durationMs: 180000,
      hashState: 'ready',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    );
    await repository.createTrack(cachedTrack);
    await repository.saveMediaFile(cachedFile);
    await repository.setPreferredMediaFile(trackId, fileId);
    final scanService = _RecordingScanService(database);
    final controller = AppController(
      platform: _FailIfLegacyScanned(),
      database: database,
      audioHandler: handler,
      scanService: scanService,
    );
    addTearDown(() async {
      controller.dispose();
      await scanService.dispose();
      await handler.disposeHandler();
      await database.close();
      await temp.delete(recursive: true);
    });

    await controller.initialize();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(controller.libraryTracks.single.track.trackId, trackId);
    expect(controller.scanRoots.single.displayName, '音乐文件');
    expect(scanService.scanAllCalls, 0);
  });

  test('扫描与备份互斥，包含异步扫描启动前的窗口', () async {
    final temp = await Directory.systemTemp.createTemp('controller-backup-');
    final database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    final scan = _RecordingScanService(database);
    final backup = _HeldBackupService(database);
    final handler = _RecordingAudioHandler();
    final controller = AppController(
      database: database,
      scanService: scan,
      backupService: backup,
      audioHandler: handler,
    );
    addTearDown(() async {
      controller.dispose();
      await scan.dispose();
      await handler.disposeHandler();
      await database.close();
      await temp.delete(recursive: true);
    });
    controller.scanRoots = await scan.scanRoots();
    final exporting = controller.exportBackup();
    expect(controller.backupBusy, isTrue);
    await controller.scanConfiguredRoots();
    expect(scan.scanAllCalls, 0);
    expect(await controller.chooseMusicFolderAndScan(), isFalse);
    expect(await controller.restoreBackup(), isFalse);
    expect(backup.restoreCalls, 0);
    backup.release.complete();
    await exporting;
    expect(controller.backupBusy, isFalse);

    scan.scanRelease = Completer<void>();
    final scanning = controller.scanConfiguredRoots();
    expect(controller.scanningLibrary, isTrue);
    expect(await controller.restoreBackup(), isFalse);
    await controller.exportBackup();
    expect(backup.exportCalls, 1);
    expect(backup.restoreCalls, 0);
    scan.scanRelease!.complete();
    await scanning;
    expect(controller.scanningLibrary, isFalse);
  });

  test('恢复后重建运行队列并刷新搜索，不保留旧曲库歌曲', () async {
    final temp = await Directory.systemTemp.createTemp('controller-restore-');
    final database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    final db = await database.database;
    const id = '00000000-0000-4000-8000-000000000901';
    const file = '00000000-0000-4000-8000-000000000902';
    await db.insert('tracks', {
      'track_id': id,
      'title': '新曲库',
      'added_at': 1,
      'updated_at': 1,
    });
    await db.insert('media_files', {
      'file_id': file,
      'track_id': id,
      'filename': '新曲库.flac',
      'normalized_filename': '新曲库.flac',
      'document_uri': 'content://music/new',
      'status': 'active',
      'created_at': 1,
      'updated_at': 1,
    });
    await db.update('tracks', {'preferred_media_file_id': file});
    final handler = _RollingQueueAudioHandler();
    final scan = _RecordingScanService(database);
    final backup = _HeldBackupService(database)..restoreSuccessfully = true;
    final controller = AppController(
      database: database,
      scanService: scan,
      backupService: backup,
      audioHandler: handler,
      platform: _FailIfLegacyScanned(),
    );
    addTearDown(() async {
      controller.dispose();
      await scan.dispose();
      await handler.disposeHandler();
      await database.close();
      await temp.delete(recursive: true);
    });
    await controller.refresh();
    handler.setTrackLibrary([_homeTrack('old-library', playable: true)]);
    await controller.searchLibrary('旧歌');

    expect(await controller.restoreBackup(), isTrue);

    expect(
      handler.queueSnapshot.entries.map((entry) => entry.track.track.trackId),
      [id],
    );
    expect(controller.currentLibraryTrack, isNull);
    expect(controller.searchResults.query, '旧歌');
    expect(controller.searchResults.tracks, isEmpty);
    expect(controller.backupBusy, isFalse);
  });
}

class _HeldBackupService extends HarmonyBackupService {
  _HeldBackupService(LibraryDatabase db) : super(database: db);
  final release = Completer<void>();
  int exportCalls = 0;
  int restoreCalls = 0;
  bool restoreSuccessfully = false;

  @override
  Future<BackupExportResult?> exportBackup() async {
    exportCalls++;
    await release.future;
    return null;
  }

  @override
  Future<BackupRestoreResult?> restoreBackup() async {
    restoreCalls++;
    return restoreSuccessfully
        ? BackupRestoreResult(
            manifest: BackupManifest(
              formatVersion: 1,
              databaseVersion: 6,
              appVersion: 'test',
              createdAt: DateTime(2026),
              files: const {},
              rowCounts: const {},
            ),
          )
        : null;
  }
}

class _RecordingAudioHandler extends MusicAudioHandler {
  List<LibraryTrack> queued = const [];
  LibraryTrack? played;
  PlaybackContext? queueContext;
  PlaybackContext? playContext;
  int playCalls = 0;
  int resumeCalls = 0;
  bool? playedManuallySelected;
  LibraryTrack? restored;
  Duration? restoredPosition;

  @override
  void setTrackLibrary(
    List<LibraryTrack> tracks, {
    PlaybackContext context = PlaybackContext.library,
  }) {
    queued = List.unmodifiable(tracks);
    queueContext = context;
  }

  @override
  Future<void> playTrack(
    LibraryTrack item, {
    bool manuallySelected = true,
    PlaybackContext? context,
  }) async {
    playCalls++;
    played = item;
    playedManuallySelected = manuallySelected;
    playContext = context;
    mediaItem.add(MediaItem(id: item.track.trackId, title: item.track.title));
  }

  @override
  Future<void> play() async {
    resumeCalls++;
  }

  @override
  Future<void> restoreTrack(
    LibraryTrack item, {
    required Duration position,
    PlaybackContext context = PlaybackContext.library,
  }) async {
    restored = item;
    restoredPosition = position;
    mediaItem.add(MediaItem(id: item.track.trackId, title: item.track.title));
  }
}

class _DelayedRecordingAudioHandler extends _RecordingAudioHandler {
  final Completer<void> release = Completer<void>();

  @override
  Future<void> playTrack(
    LibraryTrack item, {
    bool manuallySelected = true,
    PlaybackContext? context,
  }) async {
    playCalls++;
    played = item;
    playedManuallySelected = manuallySelected;
    playContext = context;
    await release.future;
  }
}

class _RollingQueueAudioHandler extends MusicAudioHandler {
  final StreamController<PlaybackQueueSnapshot> _snapshots =
      StreamController<PlaybackQueueSnapshot>.broadcast();
  PlaybackQueueSnapshot _snapshot = const PlaybackQueueSnapshot.empty();
  int _nextEntryId = 0;
  int batchAppendCalls = 0;

  @override
  Future<void> stop() async {}

  @override
  Stream<PlaybackQueueSnapshot> get queueSnapshotStream => _snapshots.stream;

  @override
  PlaybackQueueSnapshot get queueSnapshot => _snapshot;

  @override
  void setTrackLibrary(
    List<LibraryTrack> tracks, {
    PlaybackContext context = PlaybackContext.library,
  }) {
    _snapshot = PlaybackQueueSnapshot(
      entries: tracks
          .where((track) => track.isPlayable)
          .map(
            (track) =>
                QueueEntry(entryId: 'fake-${++_nextEntryId}', track: track),
          )
          .toList(growable: false),
      currentIndex: -1,
      mode: PlaybackMode.sequential,
      context: context,
    );
    _snapshots.add(_snapshot);
  }

  @override
  Future<void> playTrack(
    LibraryTrack item, {
    bool manuallySelected = true,
    PlaybackContext? context,
  }) async {
    final index = _snapshot.entries.indexWhere(
      (entry) => entry.track.track.trackId == item.track.trackId,
    );
    _snapshot = PlaybackQueueSnapshot(
      entries: _snapshot.entries,
      currentIndex: index,
      mode: _snapshot.mode,
      context: context ?? _snapshot.context,
    );
    mediaItem.add(MediaItem(id: item.track.trackId, title: item.track.title));
    _snapshots.add(_snapshot);
  }

  @override
  Future<void> addTracksToQueue(Iterable<LibraryTrack> items) async {
    batchAppendCalls++;
    final additions = items
        .map(
          (track) =>
              QueueEntry(entryId: 'fake-${++_nextEntryId}', track: track),
        )
        .toList(growable: false);
    _snapshot = PlaybackQueueSnapshot(
      entries: [..._snapshot.entries, ...additions],
      currentIndex: _snapshot.currentIndex,
      mode: _snapshot.mode,
      context: _snapshot.context,
    );
    _snapshots.add(_snapshot);
  }

  void advanceTo(int index) {
    _snapshot = PlaybackQueueSnapshot(
      entries: _snapshot.entries,
      currentIndex: index,
      mode: _snapshot.mode,
      context: _snapshot.context,
    );
    _snapshots.add(_snapshot);
  }

  @override
  Future<void> disposeHandler() async {
    await _snapshots.close();
    await super.disposeHandler();
  }
}

class _RecordingScanService extends LibraryScanService {
  _RecordingScanService(LibraryDatabase database)
    : super(
        repository: ScanRepository(database),
        migrationRepository: MigrationRepository(database),
        identityRepository: FileIdentityRepository(database),
      );

  int scanAllCalls = 0;
  Completer<void>? scanRelease;

  @override
  Future<List<ScanRoot>> scanRoots() async => [
    ScanRoot(
      rootId: 'root',
      treeUri: 'content://tree/music',
      displayName: '音乐文件',
      accessType: 'saf',
      isPrimary: true,
      permissionPersisted: true,
      enabled: true,
      createdAt: DateTime(2026, 8, 20),
    ),
  ];

  @override
  Future<void> scanAll() async {
    scanAllCalls++;
    await scanRelease?.future;
  }
}

LibraryTrack _homeTrack(
  String id, {
  required bool playable,
  String? fileId,
  bool recommendationExcluded = false,
}) {
  final now = DateTime(2026, 8, 21);
  return LibraryTrack(
    track: Track(
      trackId: id,
      title: id,
      artistDisplay: '周杰伦',
      albumArtistDisplay: '周杰伦',
      albumDisplay: '专辑',
      durationMs: 180000,
      metadataState: 'complete',
      addedAt: now,
      updatedAt: now,
    ),
    preferredFile: playable
        ? MediaFile(
            fileId: fileId ?? '$id-file',
            trackId: id,
            documentUri: 'content://music/$id',
            filename: '$id.flac',
            normalizedFilename: '$id.flac',
            extension: 'flac',
            mimeType: 'audio/flac',
            sizeBytes: 100,
            durationMs: 180000,
            hashState: 'pending',
            status: 'active',
            createdAt: now,
            updatedAt: now,
          )
        : null,
    preference: TrackPreference(
      trackId: id,
      liked: false,
      recommendationExcluded: recommendationExcluded,
      updatedAt: now,
    ),
    stats: TrackStats.empty(id, now),
  );
}

class _FailIfLegacyScanned extends MusicPlatform {
  @override
  Future<List<Song>> scanMusic() =>
      throw StateError('V4 Track 存在时不应再调用 Legacy MediaStore 列表');
}
