import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/main.dart';
import 'package:my_music_library/controllers/app_controller.dart';
import 'package:my_music_library/ui/v4_pages.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('首页下拉接入手动换歌，不只是普通数据刷新', (tester) async {
    final controller = _HomeRefreshController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V4HomePage(
            controller: controller,
            onOpenLibrary: () {},
            onOpenPlaylists: () {},
            onOpenSearch: () {},
            onOpenPlayer: () {},
          ),
        ),
      ),
    );
    await tester.drag(
      find.byKey(const Key('v4-home-page')),
      const Offset(0, 450),
    );
    await tester.pumpAndSettle();
    expect(controller.manualRefreshes, 1);
    expect(controller.dataRefreshes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页搜索配合四栏导航并能切换每个产品页面', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MyMusicLibraryApp(initializeController: false),
    );
    await tester.pump();

    expect(find.text('首页'), findsOneWidget);
    expect(find.text('音乐库'), findsWidgets);
    expect(find.text('歌单'), findsWidgets);
    expect(find.byKey(const Key('home-search-shortcut')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('home-search-shortcut'))).height,
      48,
    );
    expect(
      tester.getSize(find.byKey(const Key('home-search-shortcut'))).width,
      greaterThan(300),
    );
    expect(find.text('我的'), findsWidgets);
    expect(find.byKey(const Key('v4-home-page')), findsOneWidget);

    final navigation = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navigation.destinations, hasLength(4));
    expect(navigation.selectedIndex, 0);

    await tester.tap(find.text('音乐库').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
    expect(find.byKey(const Key('v4-library-page')), findsOneWidget);
    expect(find.byKey(const Key('v4-song-sort')), findsOneWidget);
    expect(find.byKey(const Key('library-search-shortcut')), findsOneWidget);
    expect(find.text('全部歌曲 · 0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('v4-song-sort')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('按年份'), findsOneWidget);
    expect(find.text('发行年份从旧到新'), findsOneWidget);
    await tester.tapAt(const Offset(12, 100));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('歌单').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );
    expect(find.byKey(const Key('v4-playlists-page')), findsOneWidget);
    expect(find.text('我喜欢'), findsOneWidget);
    expect(find.byKey(const Key('playlist-empty-prompt')), findsOneWidget);
    expect(find.byKey(const Key('playlist-empty-create')), findsOneWidget);

    await tester.tap(find.text('首页').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
    final homeSearch = find
        .byKey(const Key('home-search-shortcut'))
        .hitTestable();
    expect(homeSearch, findsOneWidget);
    await tester.tap(homeSearch);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('v4-search-page')), findsOneWidget);
    expect(find.byKey(const Key('v4-search-field')), findsOneWidget);
    expect(find.byKey(const Key('search-back')), findsOneWidget);
    expect(find.byKey(const Key('search-scope-overview')), findsOneWidget);
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('v4-home-page')), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('home-search-shortcut')).hitTestable(),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('search-back')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('v4-home-page')), findsOneWidget);

    await tester.tap(find.text('我的').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
    expect(find.byKey(const Key('v4-profile-page')), findsOneWidget);
    expect(find.text('我的音乐档案'), findsOneWidget);
    final scanRootTile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '主音乐目录'),
    );
    expect(scanRootTile.onTap, isNotNull);
  });

  testWidgets('Android 返回键从非首页主标签先回到首页', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MyMusicLibraryApp(initializeController: false),
    );
    await tester.pump();
    await tester.tap(find.text('音乐库').last);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
    expect(find.byKey(const Key('v4-home-page')), findsOneWidget);
  });

  testWidgets('首页使用产品化内容层级，但不展示旧版技术统计或伪推荐', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MyMusicLibraryApp(initializeController: false),
    );
    await tester.pump();

    expect(find.text('随心听'), findsOneWidget);
    expect(find.text('开始播放'), findsOneWidget);
    expect(find.text('先到“我的”选择主音乐目录'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '开始播放'))
          .onPressed,
      isNull,
    );
    expect(find.byKey(const Key('home-random-play')), findsNothing);
    expect(find.text('智能播放'), findsOneWidget);
    expect(find.byKey(const Key('home-search-shortcut')), findsOneWidget);
    expect(find.text('我的歌单'), findsOneWidget);
    expect(find.text('今日推荐'), findsNothing);
    expect(find.textContaining('待检查'), findsNothing);
    expect(find.textContaining('低于 256 kbps'), findsNothing);

    final homeScroll = find
        .descendant(
          of: find.byKey(const Key('v4-home-page')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('更多'),
      500,
      scrollable: homeScroll,
    );
    expect(find.text('更多'), findsOneWidget);
    expect(find.text('最近播放 · 最近添加'), findsOneWidget);
    expect(find.text('今日音乐'), findsNothing);
    expect(find.text('常听歌手'), findsNothing);
  });

  testWidgets('新建歌单弹窗取消和系统返回不会破坏页面', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MyMusicLibraryApp(initializeController: false),
    );
    await tester.pump();

    await tester.tap(find.text('歌单').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('playlist-empty-create')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('新建歌单'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('新建歌单'), findsNothing);
    expect(find.byKey(const Key('v4-playlists-page')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('playlist-empty-create')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('新建歌单'), findsNothing);
    expect(find.byKey(const Key('v4-playlists-page')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _HomeRefreshController extends AppController {
  int manualRefreshes = 0;
  int dataRefreshes = 0;

  @override
  Future<void> refreshHomeRecommendations() async {
    manualRefreshes++;
  }

  @override
  Future<void> refreshExperience() async {
    dataRefreshes++;
  }
}
