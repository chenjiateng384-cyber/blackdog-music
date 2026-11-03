import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/controllers/app_controller.dart';
import 'package:my_music_library/models/v4/legacy_song_compatibility.dart';
import 'package:my_music_library/models/v4/library_entities.dart';
import 'package:my_music_library/models/v4/library_search.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/listening_data.dart';
import 'package:my_music_library/models/v4/lyrics.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/playback.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/ui/app_theme.dart';
import 'package:my_music_library/ui/v4_library_detail_pages.dart';
import 'package:my_music_library/ui/v4_pages.dart';
import 'package:my_music_library/ui/v4_player_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> mount(
    WidgetTester tester,
    _Controller controller,
    Widget Function(BuildContext, VoidCallback) page,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() {
      if (!controller.playback.isCompleted) controller.playback.complete();
      controller.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: page(context, () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const Scaffold(body: Center(child: Text('播放页已打开'))),
                ),
              );
            }),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('歌单播放按钮立即打开播放页，不等待音频播放结束', (tester) async {
    final controller = _Controller();
    await mount(
      tester,
      controller,
      (_, open) => V4PlaylistsPage(controller: controller, onOpenPlayer: open),
    );
    await tester.tap(find.byTooltip('播放歌单'));
    await tester.pumpAndSettle();
    expect(find.text('播放页已打开'), findsOneWidget);
    expect(controller.playback.isCompleted, isFalse);
    expect(controller.source, 'playlist');
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单内点歌先关闭面板，再打开播放页，返回没有残留面板', (tester) async {
    final controller = _Controller();
    await mount(
      tester,
      controller,
      (_, open) => V4PlaylistsPage(controller: controller, onOpenPlayer: open),
    );
    await tester.tap(find.text('骑行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('七里香'));
    await tester.pumpAndSettle();
    expect(find.text('播放页已打开'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('骑行'), findsOneWidget);
    expect(controller.playback.isCompleted, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索点歌关闭键盘且立即进入播放页，返回保留结果', (tester) async {
    final controller = _Controller();
    final result = RankedLibrarySearchResult(
      type: LibrarySearchResultType.track,
      score: 100,
      label: '七里香',
      stableKey: 'track',
      track: controller.libraryTracks.single,
    );
    controller.searchResults = LibrarySearchResults(
      query: '七里香',
      tracks: controller.libraryTracks,
      artists: const [],
      albums: const [],
      folders: const [],
      ordered: [result],
    );
    await mount(
      tester,
      controller,
      (_, open) => V4SearchPage(
        controller: controller,
        active: true,
        onOpenPlayer: open,
      ),
    );
    await tester.tap(find.widgetWithText(ListTile, '七里香'));
    await tester.pumpAndSettle();
    expect(find.text('播放页已打开'), findsOneWidget);
    expect(controller.source, 'search');
    expect(controller.playback.isCompleted, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('v4-search-field')))
          .controller!
          .text,
      '七里香',
    );
    expect(find.widgetWithText(ListTile, '七里香'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final nested in [false, true]) {
    testWidgets('播放中连续三次进出文件夹${nested ? '子目录' : '根目录'}点歌，列表与小播放器保持可用', (
      tester,
    ) async {
      final controller = _Controller();
      await mount(
        tester,
        controller,
        (_, open) => V4LibraryPage(
          controller: controller,
          onOpenSearch: () {},
          onOpenPlayer: open,
        ),
      );
      await tester.tap(find.text('文件夹'));
      await tester.pumpAndSettle();
      Future<void> advanceRoute() async {
        // Advance real transition frames without waiting for the spinning
        // disc's repeating animation to settle.
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      for (var attempt = 0; attempt < 3; attempt++) {
        await tester.tap(find.text('本地音乐'));
        await advanceRoute();
        if (nested) {
          await tester.tap(find.text('周杰伦目录'));
          await advanceRoute();
        }
        expect(
          find.widgetWithText(ListTile, '七里香').hitTestable(),
          findsOneWidget,
        );
        final songRow = tester.widget<ListTile>(
          find.widgetWithText(ListTile, '七里香'),
        );
        controller.playing = true;
        // Deliver two taps before the route's first frame to catch stacked
        // player routes as well as the playing-state layout regression.
        songRow.onTap!();
        songRow.onTap!();
        await advanceRoute();
        expect(find.byType(V4PlayerPage), findsOneWidget);
        expect(controller.playback.isCompleted, isFalse);
        expect(controller.source, 'folder');
        expect(controller.sourceId, nested ? 'root:周杰伦' : 'root:');
        expect(controller.queuedTrackIds, ['track']);
        await tester.binding.handlePopRoute();
        await advanceRoute();
        expect(find.byType(V4PlayerPage), findsNothing);
        expect(
          find.widgetWithText(AppBar, nested ? '周杰伦目录' : '本地音乐'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(ListTile, '七里香').hitTestable(),
          findsOneWidget,
        );
        expect(
          tester.getSize(find.byKey(const Key('v4-mini-player'))).height,
          inInclusiveRange(68, 100),
        );
        await tester.tap(find.byKey(const Key('v4-mini-player-artwork')));
        await advanceRoute();
        expect(find.byType(V4PlayerPage), findsOneWidget);
        await tester.binding.handlePopRoute();
        await advanceRoute();
        expect(find.byType(V4PlayerPage), findsNothing);
        for (var depth = 0; depth < (nested ? 2 : 1); depth++) {
          await tester.binding.handlePopRoute();
          await advanceRoute();
        }
        expect(find.text('本地音乐').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final kind in PlayerPageKind.values) {
    testWidgets('${kind.name}播放页可直接加入现有歌单，不影响喜欢或播放状态', (tester) async {
      final controller = _Controller(kind: kind);
      controller.currentLibraryTrack = controller.libraryTracks.single;
      controller.currentSong = LegacySongCompatibility.libraryTrackToLegacySong(
        controller.currentLibraryTrack!,
      );
      await mount(
        tester,
        controller,
        (_, _) => V4PlayerPage(controller: controller),
      );
      await tester.tap(find.byTooltip('加入歌单').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('下一首播放'), findsNothing);
      await tester.tap(find.text('骑行'));
      await tester.pumpAndSettle();
      expect(controller.memberships, {'playlist'});
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(controller.currentLibraryTrack!.track.title, '七里香');
      expect(controller.favoriteIds, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('新建歌单提供可选封面，不选封面也可创建', (tester) async {
    final controller = _Controller();
    await mount(
      tester,
      controller,
      (context, _) => TextButton(
        onPressed: () => showV4CreatePlaylist(context, controller),
        child: const Text('新建'),
      ),
    );
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    expect(find.text('选择封面（可选）'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '夜晚');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(controller.createdName, '夜晚');
    expect(controller.createdCover, isNull);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _Controller extends AppController {
  _Controller({this.kind = PlayerPageKind.immersive}) {
    loading = false;
    final now = DateTime(2026, 10, 12);
    const id = 'track';
    libraryTracks = [
      LibraryTrack(
        track: Track(
          trackId: id,
          title: '七里香',
          artistDisplay: '周杰伦',
          albumArtistDisplay: '周杰伦',
          albumDisplay: '七里香',
          durationMs: 240000,
          metadataState: 'complete',
          addedAt: now,
          updatedAt: now,
        ),
        preferredFile: MediaFile(
          fileId: 'file',
          trackId: id,
          contentUri: 'content://music/1',
          filename: '七里香.flac',
          normalizedFilename: '七里香.flac',
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
      ),
    ];
    playlistSummaries = [
      PlaylistLibrarySummary(
        playlist: Playlist(
          playlistId: 'playlist',
          name: '骑行',
          type: 'user',
          createdAt: now,
          updatedAt: now,
        ),
        trackCount: 1,
      ),
    ];
    libraryFolders = const [
      LibraryFolder(
        scanRootId: 'root',
        relativePath: '',
        name: '本地音乐',
        parentPath: null,
        depth: 0,
        directTrackCount: 1,
        descendantTrackCount: 2,
      ),
    ];
  }
  final playback = Completer<void>();
  final PlayerPageKind kind;
  bool playing = false;
  @override
  bool get isPlaying => playing;
  @override
  PlayerPageKind get playerPageKind => kind;
  final memberships = <String>{};
  String? source;
  String? sourceId;
  List<String> queuedTrackIds = const [];
  String? createdName;
  String? createdCover;
  @override
  Future<List<LibraryTrack>> tracksForPlaylist(String playlistId) async =>
      libraryTracks;
  @override
  Future<TrackLyrics?> lyricsForTrack(String trackId) async => null;
  @override
  Future<List<LibraryFolder>> childFolders(LibraryFolder folder) async =>
      folder.relativePath.isEmpty
      ? const [
          LibraryFolder(
            scanRootId: 'root',
            relativePath: '周杰伦',
            name: '周杰伦目录',
            parentPath: '',
            depth: 1,
            directTrackCount: 1,
            descendantTrackCount: 1,
          ),
        ]
      : const [];
  @override
  Future<List<LibraryTrack>> directTracksForFolder(
    LibraryFolder folder,
  ) async => libraryTracks;
  @override
  Future<void> playTrackCollection(
    List<LibraryTrack> tracks, {
    required String contextType,
    String? contextId,
    LibraryTrack? startTrack,
    bool manuallySelected = true,
  }) {
    source = contextType;
    sourceId = contextId;
    queuedTrackIds = tracks.map((track) => track.track.trackId).toList();
    currentLibraryTrack = startTrack ?? tracks.first;
    currentSong = LegacySongCompatibility.libraryTrackToLegacySong(
      currentLibraryTrack!,
    );
    notifyListeners();
    return playback.future;
  }

  @override
  Future<Set<String>> playlistIdsForTrack(String trackId) async =>
      Set.of(memberships);
  @override
  Future<void> setTrackPlaylistMembership(
    String playlistId,
    LibraryTrack track,
    bool included,
  ) async {
    included ? memberships.add(playlistId) : memberships.remove(playlistId);
  }

  @override
  Future<void> createPlaylist(String name, {String? coverPath}) async {
    createdName = name;
    createdCover = coverPath;
  }
}
