import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:my_music_library/controllers/app_controller.dart';
import 'package:my_music_library/models/song.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/listening_data.dart';
import 'package:my_music_library/models/v4/lyrics.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/playback.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/ui/app_theme.dart';
import 'package:my_music_library/ui/components/v4_mini_player.dart';
import 'package:my_music_library/ui/v4_player_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('完整播放页在一加13比例展示成熟播放控制且不溢出', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController();
    controller.currentSong = _song;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: V4PlayerPage(controller: controller),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('immersive-player-grip')), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('immersive-artwork-layer'))).height,
      closeTo(math.min(915 * .62, 412 / .92), .1),
    );
    expect(find.text('七里香'), findsOneWidget);
    expect(find.text('周杰伦'), findsOneWidget);
    expect(find.text('歌词'), findsOneWidget);
    expect(find.text('睡眠定时'), findsOneWidget);
    expect(find.text('队列'), findsOneWidget);
    expect(find.byKey(const Key('immersive-progress-slider')), findsOneWidget);
    expect(find.byKey(const Key('immersive-volume-slider')), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
    final transportLift = tester.widget<Transform>(
      find.byKey(const Key('immersive-transport-lift')),
    );
    expect(transportLift.transform.entry(1, 3), -18);
    await tester.tap(find.text('歌词'));
    await tester.pumpAndSettle();
    expect(find.text('这首歌还没有可用歌词'), findsOneWidget);
    await tester.tap(find.text('封面'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('immersive-artwork')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('第二播放页下滑时跟手移动并在越过阈值后退出', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController()..currentSong = _song;
    final navigatorObserver = _PopObserver();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        navigatorObservers: [navigatorObserver],
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute<void>(
                builder: (_) => V4PlayerPage(controller: controller),
              ),
            ),
            child: const Text('打开播放页'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开播放页'));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(const Offset(206, 260));
    await gesture.moveBy(const Offset(0, 110));
    await tester.pump();
    final surface = tester.widget<AnimatedContainer>(
      find.byKey(const Key('immersive-dismiss-surface')),
    );
    expect(surface.transform!.entry(1, 3), greaterThan(80));

    await gesture.up();
    await tester.pump();
    expect(navigatorObserver.popCount, 1);
    await tester.pumpAndSettle();
    expect(find.text('打开播放页'), findsOneWidget);
    expect(find.byKey(const Key('immersive-dismiss-surface')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('第二播放页歌词模式启用整面低调对比保护层', (tester) async {
    final controller = AppController()..currentSong = _song;
    controller.setImmersivePlayerView(ImmersivePlayerView.lyrics);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: V4PlayerPage(controller: controller),
      ),
    );
    await tester.pump();

    final layer = tester.widget<AnimatedOpacity>(
      find.byKey(const Key('immersive-lyrics-contrast-layer')),
    );
    expect(layer.opacity, 1);
    expect(find.byKey(const Key('immersive-lyrics')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页快捷播放来源进入水晶厅播放页', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final current = _libraryTrack('track-current', '七里香');
    final controller = AppController();
    controller.currentSong = _song;
    controller.currentLibraryTrack = current;
    controller.playbackQueue = PlaybackQueueSnapshot(
      entries: [QueueEntry(entryId: 'queue-1', track: current)],
      currentIndex: 0,
      mode: PlaybackMode.sequential,
      context: const PlaybackContext(type: 'home_quick_start'),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: V4PlayerPage(controller: controller),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('crystal-view-indicator')), findsOneWidget);
    expect(find.byKey(const Key('crystal-artwork')), findsOneWidget);
    expect(find.byTooltip('听歌偏好'), findsOneWidget);
    expect(find.byTooltip('循环方式'), findsOneWidget);
    expect(find.byKey(const Key('crystal-manual-only-action')), findsOneWidget);
    expect(find.byTooltip('设为仅手动播放'), findsOneWidget);
    final disc = tester.getRect(find.byKey(const Key('crystal-disc')));
    final cover = tester.getRect(find.byKey(const Key('crystal-cover-frame')));
    final timePanel = tester.getRect(
      find.byKey(const Key('crystal-time-panel')),
    );
    final turntable = tester.getRect(
      find.byKey(const Key('crystal-turntable-group')),
    );
    final trackInfo = tester.getRect(
      find.byKey(const Key('crystal-track-info')),
    );
    expect(turntable.width, closeTo(timePanel.width + 44, .1));
    expect(turntable.left, closeTo(timePanel.left, .1));
    expect(
      tester.getSize(find.byKey(const Key('crystal-artwork-slot'))).height,
      324,
    );
    expect(disc.width, closeTo(cover.height * .94, .1));
    expect(disc.right, closeTo(turntable.right, .1));
    expect((disc.center.dx - cover.right).abs(), lessThan(10));
    expect(disc.center.dy, closeTo(cover.center.dy, .1));
    expect(
      turntable.top,
      closeTo(
        tester.getRect(find.byKey(const Key('crystal-artwork-slot'))).top + 37,
        .1,
      ),
    );
    expect(
      turntable.bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('crystal-artwork-slot'))).bottom,
      ),
    );
    expect(trackInfo.top - turntable.bottom, closeTo(50.5, 1));
    expect(
      tester.getSize(find.byKey(const Key('crystal-progress-track'))).height,
      26,
    );
    await tester.drag(
      find.byKey(const Key('crystal-turntable-group')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('crystal-lyrics')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('听歌偏好只展示真实生效的熟悉度和自动学习说明', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final current = _libraryTrack('track-preference', '七里香');
    final controller = AppController()
      ..currentSong = _song
      ..currentLibraryTrack = current
      ..playbackQueue = PlaybackQueueSnapshot(
        entries: [QueueEntry(entryId: 'queue-preference', track: current)],
        currentIndex: 0,
        mode: PlaybackMode.sequential,
        context: const PlaybackContext(type: 'home_quick_start'),
      );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: V4PlayerPage(controller: controller),
      ),
    );
    await tester.tap(find.byTooltip('听歌偏好'));
    await tester.pumpAndSettle();

    expect(find.text('自动听歌偏好'), findsOneWidget);
    expect(find.text('歌曲熟悉度'), findsOneWidget);
    expect(find.text('音乐情绪'), findsNothing);
    expect(find.text('生活场景'), findsNothing);
    expect(find.textContaining('主动点歌、完整收听和跳过'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('暂停恢复和暂停跳转后进度环同步且静止时不重复刷新', (tester) async {
    final player = _MiniPositionPlayer();
    final controller = _MiniPositionController(player)..currentSong = _song;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: V4MiniPlayer(
            controller: controller,
            onTap: () {},
          ),
        ),
      ),
    );
    CircularProgressIndicator ring() =>
        tester.widget(find.byKey(const Key('v4-mini-player-progress-ring')));
    expect(ring().value, 0);

    player.restoredPosition = const Duration(seconds: 81);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(ring().value, closeTo(81 / _song.duration.inSeconds, .001));
    expect(controller.isPlaying, isFalse);

    player.restoredPosition = const Duration(seconds: 25);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(ring().value, closeTo(25 / _song.duration.inSeconds, .001));
    player.restoredDuration = const Duration(seconds: 200);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(ring().value, closeTo(25 / 200, .001));
    final unchangedRing = ring();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(identical(ring(), unchangedRing), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mini Player只保留必要信息和控制', (tester) async {
    final controller = AppController();
    controller.currentSong = _song;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: const SizedBox(),
          bottomNavigationBar: V4MiniPlayer(
            controller: controller,
            onTap: () {},
          ),
        ),
      ),
    );

    expect(find.text('七里香'), findsOneWidget);
    expect(find.text('周杰伦'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);
    expect(find.byIcon(Icons.queue_music_rounded), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byKey(const Key('v4-mini-player-toggle')), findsOneWidget);
    expect(find.byKey(const Key('v4-mini-player-progress')), findsOneWidget);
    expect(
      find.byKey(const Key('v4-mini-player-artwork-group')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('v4-mini-player-disc')), findsOneWidget);
    final artworkGroup = tester.getRect(
      find.byKey(const Key('v4-mini-player-artwork-group')),
    );
    final artwork = tester.getRect(
      find.byKey(const Key('v4-mini-player-artwork')),
    );
    final disc = tester.getRect(find.byKey(const Key('v4-mini-player-disc')));
    expect(artworkGroup.width, 73);
    expect(disc.center.dx, closeTo(artwork.right - 1, .1));
    expect(disc.center.dy, closeTo(artwork.center.dy, .1));
    expect(
      find.byKey(const Key('v4-mini-player-progress-ring')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('v4-mini-player-next')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('v4-mini-player'))).height,
      greaterThanOrEqualTo(68),
    );
  });

  for (final textScale in [1.0, 1.5]) {
    testWidgets('播放与暂停反复切换时独立底栏不撑满文件夹页面，字号$textScale', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _MiniPlaybackController()
        ..currentSong = _song
        ..currentLibraryTrack = _libraryTrack('mini', '七里香');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(412, 915),
              textScaler: TextScaler.linear(textScale),
            ),
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) => Scaffold(
                appBar: AppBar(title: const Text('文件夹')),
                body: ListView(
                  key: const Key('folder-body'),
                  children: const [ListTile(title: Text('文件夹歌曲'))],
                ),
                bottomNavigationBar: SafeArea(
                  top: false,
                  child: V4MiniPlayer(controller: controller, onTap: () {}),
                ),
              ),
            ),
          ),
        ),
      );
      for (final playing in [true, false, true, false, true]) {
        controller.playing = playing;
        controller.notifyListeners();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester.getSize(find.byKey(const Key('v4-mini-player'))).height,
          inInclusiveRange(68, 100),
        );
        expect(
          tester.getSize(find.byKey(const Key('folder-body'))).height,
          greaterThan(600),
        );
        expect(find.text('文件夹歌曲').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('队列面板区分当前歌曲与待播歌曲', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final current = _libraryTrack('track-current', '七里香');
    final next = _libraryTrack('track-next', '借口');
    final controller = AppController();
    controller.currentSong = _song;
    controller.currentLibraryTrack = current;
    controller.playbackQueue = PlaybackQueueSnapshot(
      entries: [
        QueueEntry(entryId: 'queue-1', track: current),
        QueueEntry(entryId: 'queue-2', track: next),
      ],
      currentIndex: 0,
      mode: PlaybackMode.sequential,
      context: const PlaybackContext(type: 'album', id: 'album-1'),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: V4PlayerPage(controller: controller),
      ),
    );
    await tester.tap(find.text('队列'));
    await tester.pumpAndSettle();

    expect(find.text('队列 · 2 首歌曲'), findsOneWidget);
    expect(find.textContaining('正在播放 ·'), findsOneWidget);
    expect(find.text('接下来播放'), findsOneWidget);
    expect(find.text('已播放'), findsOneWidget);
    expect(find.byTooltip('清空待播'), findsOneWidget);
    expect(find.text('随机'), findsOneWidget);
    expect(find.text('顺序'), findsOneWidget);
    expect(find.text('单曲'), findsOneWidget);
    expect(find.text('循环'), findsOneWidget);
    expect(find.text('借口'), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _MiniPositionController extends AppController {
  _MiniPositionController(this.positionPlayer);

  final AudioPlayer positionPlayer;

  @override
  AudioPlayer get player => positionPlayer;
}

class _MiniPositionPlayer implements AudioPlayer {
  Duration restoredPosition = Duration.zero;
  Duration restoredDuration = _song.duration;

  @override
  Duration get position => restoredPosition;

  @override
  Duration? get duration => restoredDuration;

  @override
  bool get playing => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MiniPlaybackController extends AppController {
  bool playing = false;

  @override
  bool get isPlaying => playing;

  @override
  Future<TrackLyrics?> lyricsForTrack(String trackId) async => null;
}

class _PopObserver extends NavigatorObserver {
  int popCount = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount += 1;
    super.didPop(route, previousRoute);
  }
}

final _song = Song(
  id: 1,
  uri: 'content://music/1',
  title: '七里香',
  artist: '周杰伦',
  album: '七里香',
  duration: Duration(minutes: 4, seconds: 59),
  dateAdded: DateTime(2026),
  displayName: '03_七里香.flac',
  mimeType: 'audio/flac',
  sizeBytes: 32000000,
  bitrate: 0,
  sampleRate: 44100,
  bitsPerSample: 16,
);

LibraryTrack _libraryTrack(String id, String title) {
  final now = DateTime(2026, 8, 22);
  return LibraryTrack(
    track: Track(
      trackId: id,
      title: title,
      artistDisplay: '周杰伦',
      albumArtistDisplay: '周杰伦',
      albumDisplay: '七里香',
      durationMs: 240000,
      metadataState: 'complete',
      addedAt: now,
      updatedAt: now,
    ),
    preferredFile: MediaFile(
      fileId: 'file-$id',
      trackId: id,
      contentUri: 'content://music/$id',
      filename: '$title.flac',
      normalizedFilename: '$title.flac',
      extension: 'flac',
      mimeType: 'audio/flac',
      sizeBytes: 1000,
      durationMs: 240000,
      hashState: 'ready',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    ),
    preference: TrackPreference.empty(id, now),
    stats: TrackStats.empty(id, now),
  );
}
