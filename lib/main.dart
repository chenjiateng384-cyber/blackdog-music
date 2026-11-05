import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'controllers/app_controller.dart';
import 'services/music_audio_handler.dart';
import 'ui/app_theme.dart';
import 'ui/components/v4_mini_player.dart';
import 'ui/v4_design_system.dart';
import 'ui/v4_pages.dart';
import 'ui/v4_player_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final audioHandler = await AudioService.init<MusicAudioHandler>(
    builder: MusicAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.chenjiateng.my_music_library.playback',
      androidNotificationChannelName: '音乐播放',
      androidNotificationChannelDescription: '锁屏、通知栏和耳机控制的音乐播放状态',
      androidNotificationIcon: 'drawable/ic_stat_music_note',
      androidNotificationOngoing: true,
      artDownscaleWidth: 1440,
      artDownscaleHeight: 1440,
    ),
  );
  runApp(MyMusicLibraryApp(audioHandler: audioHandler));
}

class MyMusicLibraryApp extends StatelessWidget {
  const MyMusicLibraryApp({
    this.audioHandler,
    this.initializeController = true,
    super.key,
  });

  final MusicAudioHandler? audioHandler;
  final bool initializeController;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '黑狗音乐',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: AppShell(
        audioHandler: audioHandler,
        initializeController: initializeController,
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({
    this.audioHandler,
    this.initializeController = true,
    super.key,
  });

  final MusicAudioHandler? audioHandler;
  final bool initializeController;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final AppController controller;
  int currentIndex = 0;
  bool searchOpen = false;
  StreamSubscription<String>? _uiMessageSubscription;
  Timer? _toastTimer;
  String? _toastMessage;
  bool _playerRouteOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = AppController(audioHandler: widget.audioHandler);
    _uiMessageSubscription = controller.uiMessages.listen((message) {
      if (!mounted) return;
      _toastTimer?.cancel();
      setState(() => _toastMessage = message);
      _toastTimer = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _toastMessage = null);
      });
    });
    if (widget.initializeController) controller.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(controller.savePlaybackState());
    }
    if (state == AppLifecycleState.resumed &&
        widget.initializeController &&
        !controller.loading) {
      unawaited(controller.syncTimeBasedState());
      // Resume only refreshes playback-derived summaries. Artist, album,
      // folder and playlist structure has not changed while the app was in
      // the background and re-querying it made every return feel sluggish.
      unawaited(controller.refreshPlaybackExperience());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uiMessageSubscription?.cancel();
    _toastTimer?.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final pages = [
          V4HomePage(
            controller: controller,
            onOpenLibrary: () => setState(() => currentIndex = 1),
            onOpenPlaylists: () => setState(() => currentIndex = 2),
            onOpenSearch: () => setState(() => searchOpen = true),
            onOpenPlayer: _openPlayer,
          ),
          V4LibraryPage(
            controller: controller,
            onOpenSearch: () => setState(() => searchOpen = true),
            onOpenPlayer: _openPlayer,
          ),
          V4PlaylistsPage(controller: controller, onOpenPlayer: _openPlayer),
          V4ProfilePage(controller: controller),
        ];
        return PopScope(
          canPop: !searchOpen && currentIndex == 0,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (searchOpen) {
              setState(() => searchOpen = false);
            } else if (currentIndex != 0) {
              setState(() => currentIndex = 0);
            }
          },
          child: Scaffold(
            body: Stack(
              children: [
                const Positioned.fill(child: _AppBackground()),
                SafeArea(
                  bottom: false,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      TickerMode(
                        enabled: !searchOpen,
                        child: Offstage(
                          offstage: searchOpen,
                          child: IndexedStack(
                            index: currentIndex,
                            children: pages,
                          ),
                        ),
                      ),
                      if (searchOpen)
                        V4SearchPage(
                          controller: controller,
                          active: true,
                          onClose: () => setState(() => searchOpen = false),
                          onOpenPlayer: _openPlayer,
                        ),
                    ],
                  ),
                ),
                Positioned(
                  top: MediaQuery.paddingOf(context).top + V4Space.sm,
                  left: V4Space.section,
                  right: V4Space.section,
                  child: IgnorePointer(
                    child: AnimatedSwitcher(
                      duration: V4Motion.quick,
                      child: _toastMessage == null
                          ? const SizedBox.shrink()
                          : _HarmonyToast(
                              key: ValueKey(_toastMessage),
                              message: _toastMessage!,
                            ),
                    ),
                  ),
                ),
              ],
            ),
            bottomNavigationBar: searchOpen
                ? (controller.currentSong == null
                      ? null
                      : SafeArea(
                          top: false,
                          child: V4MiniPlayer(
                            controller: controller,
                            onTap: _openPlayer,
                          ),
                        ))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (controller.currentSong != null)
                        V4MiniPlayer(
                          controller: controller,
                          onTap: _openPlayer,
                        ),
                      NavigationBar(
                        selectedIndex: currentIndex,
                        onDestinationSelected: (index) =>
                            setState(() => currentIndex = index),
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.home_outlined),
                            selectedIcon: Icon(Icons.home_rounded),
                            label: '首页',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.library_music_outlined),
                            selectedIcon: Icon(Icons.library_music_rounded),
                            label: '音乐库',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.queue_music_outlined),
                            selectedIcon: Icon(Icons.queue_music_rounded),
                            label: '歌单',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.person_outline_rounded),
                            selectedIcon: Icon(Icons.person_rounded),
                            label: '我的',
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  void _openPlayer() {
    if (!mounted || _playerRouteOpen || controller.currentSong == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _playerRouteOpen = true;
    Navigator.of(context)
        .push<void>(
          PageRouteBuilder<void>(
            transitionDuration: const Duration(milliseconds: 280),
            reverseTransitionDuration: const Duration(milliseconds: 240),
            pageBuilder: (_, _, _) => V4PlayerPage(controller: controller),
            transitionsBuilder: (_, animation, _, child) {
              final position =
                  Tween<Offset>(
                    begin: const Offset(0, 1),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                      reverseCurve: Curves.easeInCubic,
                    ),
                  );
              return SlideTransition(position: position, child: child);
            },
          ),
        )
        .whenComplete(() => _playerRouteOpen = false);
  }
}

class _AppBackground extends StatelessWidget {
  const _AppBackground();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(color: Theme.of(context).scaffoldBackgroundColor);
  }
}

class _HarmonyToast extends StatelessWidget {
  const _HarmonyToast({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Material(
        color: colors.inverseSurface.withValues(alpha: 0.94),
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(V4Radius.sheet),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: V4Space.md,
            vertical: V4Space.sm,
          ),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.onInverseSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
