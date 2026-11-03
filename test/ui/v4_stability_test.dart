import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/controllers/app_controller.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/listening_data.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/ui/app_theme.dart';
import 'package:my_music_library/ui/v4_artwork.dart';
import 'package:my_music_library/ui/v4_library_detail_pages.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('歌曲行固定为72dp且长标题和专辑信息不会溢出', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController();
    addTearDown(controller.dispose);
    final track = _track();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: V4LibraryTrackTile(
            controller: controller,
            track: track,
            showAlbum: true,
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const Key('track-long-title'))).height,
      72,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认封面使用稳定的低饱和带色占位且不随机变化', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: Row(
            children: [
              SizedBox.square(
                dimension: 120,
                child: V4Artwork(artwork: null, fallbackSeed: 'same-album'),
              ),
              SizedBox.square(
                dimension: 120,
                child: V4Artwork(artwork: null, fallbackSeed: 'same-album'),
              ),
            ],
          ),
        ),
      ),
    );

    final placeholders = tester
        .widgetList<DecoratedBox>(
          find.byKey(const Key('v4-artwork-placeholder')),
        )
        .toList();
    expect(placeholders, hasLength(2));
    final first = placeholders.first.decoration as BoxDecoration;
    final second = placeholders.last.decoration as BoxDecoration;
    expect(first.gradient, isA<LinearGradient>());
    expect(
      (first.gradient as LinearGradient).colors,
      (second.gradient as LinearGradient).colors,
    );
  });
}

LibraryTrack _track() {
  final now = DateTime(2026, 8, 22);
  const trackId = 'long-title';
  return LibraryTrack(
    track: Track(
      trackId: trackId,
      title: '这是一首用于验证超长歌曲名称显示时不会挤压操作按钮的歌曲',
      artistDisplay: '一位名字非常长的歌手',
      albumArtistDisplay: '一位名字非常长的歌手',
      albumDisplay: '一张名称同样非常长并且需要正确截断的专辑',
      durationMs: 240000,
      metadataState: 'complete',
      addedAt: now,
      updatedAt: now,
    ),
    preference: TrackPreference.empty(trackId, now),
    stats: TrackStats.empty(trackId, now),
  );
}
