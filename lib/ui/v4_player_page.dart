import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../models/v4/lyrics.dart';
import '../models/v4/listening_preference.dart';
import '../models/v4/playback.dart';
import 'components/v4_mini_player.dart';
import 'song_artwork.dart';
import 'v4_artwork.dart';
import 'v4_design_system.dart';
import 'v4_library_detail_pages.dart' show showV4PlaylistPicker;

const double _lyricsLineExtent = 64;
const double _crystalTurntableGap = 37;
const double _crystalTurntableWidthIncrease = 44;
const double _crystalTrackInfoGap = 19;
const double _crystalTrackInfoDownShift = 31.5;
const double _crystalArtworkSlotHeight = 324;
const double _immersiveTransportLift = 18;
const TextStyle _crystalClockTextStyle = TextStyle(
  fontSize: 42,
  height: 1.1,
  fontWeight: FontWeight.w600,
  letterSpacing: 1,
  color: Colors.white,
  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
);
const LinearGradient _crystalArtworkBackground = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  stops: <double>[0, .30, .56, .76, 1],
  colors: <Color>[
    Color(0xFF6490B6),
    Color(0xFF8AAAC8),
    Color(0xFFBCD0DE),
    Color(0xFFEEF2F7),
    Color(0xFFE7ECF1),
  ],
);
const LinearGradient _crystalLyricsBackground = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  stops: <double>[0, .42, .74, 1],
  colors: <Color>[
    Color(0xFF182631),
    Color(0xFF213744),
    Color(0xFF294957),
    Color(0xFF203842),
  ],
);

class V4PlayerPage extends StatefulWidget {
  const V4PlayerPage({required this.controller, super.key});

  final AppController controller;

  @override
  State<V4PlayerPage> createState() => _V4PlayerPageState();
}

class _V4PlayerPageState extends State<V4PlayerPage> {
  @override
  Widget build(BuildContext context) =>
      widget.controller.playerPageKind == PlayerPageKind.crystal
      ? _CrystalPlayerPage(controller: widget.controller)
      : _ImmersivePlayerPage(controller: widget.controller);
}

class _CrystalPlayerPage extends StatefulWidget {
  const _CrystalPlayerPage({required this.controller});

  final AppController controller;

  @override
  State<_CrystalPlayerPage> createState() => _CrystalPlayerPageState();
}

class _CrystalPlayerPageState extends State<_CrystalPlayerPage> {
  final ScrollController _lyricsScrollController = ScrollController();
  late final PageController _pageController;
  TrackLyrics? _lyrics;
  String? _loadedTrackId;
  Timer? _clockTimer;
  DateTime _clock = DateTime.now();
  double _dismissDragY = 0;
  bool _dismissDragActive = false;
  int _lastLyricsIndex = -1;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage: widget.controller.crystalPlayerView.index,
    );
    widget.controller.addListener(_controllerChanged);
    _loadLyrics();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted &&
          widget.controller.crystalPlayerView == CrystalPlayerView.artwork) {
        setState(() => _clock = DateTime.now());
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _clockTimer?.cancel();
    _pageController.dispose();
    _lyricsScrollController.dispose();
    super.dispose();
  }

  void _controllerChanged() {
    _loadLyrics();
    _syncPageWithController();
    if (mounted) setState(() {});
  }

  void _syncPageWithController() {
    if (!_pageController.hasClients) return;
    final target = widget.controller.crystalPlayerView.index;
    final current = _pageController.page?.round();
    if (current == target ||
        _pageController.position.isScrollingNotifier.value) {
      return;
    }
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _loadLyrics() async {
    final trackId = widget.controller.currentLibraryTrack?.track.trackId;
    if (trackId == null || trackId == _loadedTrackId) return;
    _loadedTrackId = trackId;
    _lyrics = null;
    _lastLyricsIndex = -1;
    final lyrics = await widget.controller.lyricsForTrack(trackId);
    if (!mounted || trackId != _loadedTrackId) return;
    setState(() => _lyrics = lyrics);
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (widget.controller.crystalPlayerView != CrystalPlayerView.artwork) {
      return;
    }
    final height = MediaQuery.sizeOf(context).height;
    _dismissDragActive =
        details.localPosition.dy >= 64 &&
        details.localPosition.dy <= height - 190;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_dismissDragActive || details.delta.dy <= 0) return;
    setState(() {
      _dismissDragY = (_dismissDragY + details.delta.dy).clamp(0.0, 180.0);
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (!_dismissDragActive) return;
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (_dismissDragY > 72 || velocity > 850) {
      Navigator.maybePop(context);
    } else if (mounted) {
      setState(() => _dismissDragY = 0);
    }
    _dismissDragActive = false;
  }

  void _onVerticalDragCancel() {
    _dismissDragActive = false;
    if (_dismissDragY != 0 && mounted) {
      setState(() => _dismissDragY = 0);
    }
  }

  void _showCrystalPage(CrystalPlayerView view) {
    final page = view.index;
    if (!_pageController.hasClients) {
      widget.controller.setCrystalPlayerView(view);
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageController.jumpToPage(page);
    } else {
      _pageController.animateToPage(
        page,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final song = controller.currentSong;
    if (song == null) return const SizedBox.shrink();
    final view = controller.crystalPlayerView;
    final liked = controller.favoriteIds.contains(song.id);
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFFE7ECF1),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: _onVerticalDragStart,
        onVerticalDragUpdate: _onVerticalDragUpdate,
        onVerticalDragEnd: _onVerticalDragEnd,
        onVerticalDragCancel: _onVerticalDragCancel,
        child: AnimatedContainer(
          duration: !_dismissDragActive
              ? const Duration(milliseconds: 220)
              : Duration.zero,
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(0, _dismissDragY, 0),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              gradient: view == CrystalPlayerView.lyrics
                  ? _crystalLyricsBackground
                  : _crystalArtworkBackground,
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: Column(
                  children: [
                    SizedBox(
                      height: 48,
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: '收起',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: Colors.white,
                            ),
                          ),
                          Expanded(
                            child: InkWell(
                              key: const Key('crystal-view-indicator'),
                              onTap: () => _showCrystalPage(
                                view == CrystalPlayerView.artwork
                                    ? CrystalPlayerView.lyrics
                                    : CrystalPlayerView.artwork,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _ViewDot(
                                    active: view == CrystalPlayerView.artwork,
                                  ),
                                  const SizedBox(width: 7),
                                  _ViewDot(
                                    active: view == CrystalPlayerView.lyrics,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '听歌偏好',
                            onPressed: () => _showListeningPreference(context),
                            icon: const Icon(
                              Icons.tune_rounded,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: PageView(
                        key: const Key('crystal-player-pages'),
                        controller: _pageController,
                        clipBehavior: Clip.none,
                        physics: const PageScrollPhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                        onPageChanged: (index) =>
                            controller.setCrystalPlayerView(
                              CrystalPlayerView.values[index],
                            ),
                        children: [
                          _buildCrystalArtworkPage(
                            context,
                            controller,
                            song,
                            liked,
                            colors,
                          ),
                          _buildCrystalLyricsPage(
                            context,
                            controller,
                            song,
                            liked,
                            colors,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCrystalArtworkPage(
    BuildContext context,
    AppController controller,
    Song song,
    bool liked,
    ColorScheme colors,
  ) {
    final libraryTrack = controller.currentLibraryTrack;
    final manualOnly = libraryTrack?.preference.recommendationExcluded ?? false;
    final featureWidth = _crystalTimePanelWidth(context, _formatClock(_clock));
    final availableArtworkWidth = MediaQuery.sizeOf(context).width - 46;
    final turntableWidth = math.min(
      featureWidth + _crystalTurntableWidthIncrease,
      availableArtworkWidth + _crystalTurntableWidthIncrease,
    );
    final trackInfoOffset =
        _crystalTrackInfoGap -
        (_crystalArtworkSlotHeight -
            _crystalTurntableGap -
            (turntableWidth / 1.44));
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 6, top: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.location_on_outlined,
                      size: 18,
                      color: Color(0xC7FFFFFF),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatCrystalDate(_clock),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: const Color(0xD1FFFFFF),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                DecoratedBox(
                  key: const Key('crystal-time-panel'),
                  decoration: BoxDecoration(
                    color: const Color(0x2BFFFFFF),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0x57FFFFFF)),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x24285082),
                        blurRadius: 24,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
                    child: Text(
                      _formatClock(_clock),
                      style: _crystalClockTextStyle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          key: const Key('crystal-artwork-slot'),
          height: _crystalArtworkSlotHeight,
          child: Padding(
            padding: const EdgeInsets.only(left: 6, top: _crystalTurntableGap),
            child: TickerMode(
              enabled:
                  widget.controller.crystalPlayerView ==
                  CrystalPlayerView.artwork,
              child: _TurntableArtwork(
                key: const Key('crystal-artwork'),
                controller: controller,
                song: song,
                featureWidth: featureWidth,
              ),
            ),
          ),
        ),
        Transform.translate(
          offset: Offset(0, trackInfoOffset + _crystalTrackInfoDownShift),
          child: Column(
            children: [
              Row(
                key: const Key('crystal-track-info'),
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                color: const Color(0xFF1F242B),
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(color: const Color(0xFF4D7182)),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '加入歌单',
                    onPressed: libraryTrack == null
                        ? null
                        : () => showV4PlaylistPicker(context, controller),
                    icon: const Icon(
                      Icons.playlist_add_rounded,
                      color: Color(0xFF183848),
                    ),
                  ),
                  IconButton(
                    key: const Key('crystal-manual-only-action'),
                    tooltip: manualOnly ? '恢复自动推荐' : '设为仅手动播放',
                    onPressed: libraryTrack == null
                        ? null
                        : () => controller.setTrackManualOnly(
                            libraryTrack,
                            !manualOnly,
                          ),
                    icon: Icon(
                      manualOnly
                          ? Icons.touch_app_rounded
                          : Icons.touch_app_outlined,
                      color: manualOnly
                          ? colors.primary
                          : const Color(0xFF183848),
                    ),
                  ),
                  IconButton(
                    tooltip: liked ? '取消喜欢' : '我喜欢',
                    onPressed: () => controller.toggleFavorite(song),
                    icon: Icon(
                      liked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: liked ? colors.primary : const Color(0xFF183848),
                    ),
                  ),
                ],
              ),
              _CurrentLyricLine(
                lyrics: _lyrics,
                positionStream: controller.player.positionStream,
                onTap: () => _showCrystalPage(CrystalPlayerView.lyrics),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
        _PlayerProgress(controller: controller, song: song),
        _CrystalControls(
          controller: controller,
          onQueue: () => _showQueue(context),
        ),
      ],
    );
  }

  Widget _buildCrystalLyricsPage(
    BuildContext context,
    AppController controller,
    Song song,
    bool liked,
    ColorScheme colors,
  ) {
    final libraryTrack = controller.currentLibraryTrack;
    final manualOnly = libraryTrack?.preference.recommendationExcluded ?? false;
    return Column(
      key: const Key('crystal-lyrics'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(color: Colors.white),
              ),
            ),
            IconButton(
              tooltip: '加入歌单',
              onPressed: libraryTrack == null
                  ? null
                  : () => showV4PlaylistPicker(context, controller),
              icon: const Icon(Icons.playlist_add_rounded, color: Colors.white),
            ),
            IconButton(
              key: const Key('crystal-lyrics-manual-only-action'),
              tooltip: manualOnly ? '恢复自动推荐' : '设为仅手动播放',
              onPressed: libraryTrack == null
                  ? null
                  : () => controller.setTrackManualOnly(
                      libraryTrack,
                      !manualOnly,
                    ),
              icon: Icon(
                manualOnly ? Icons.touch_app_rounded : Icons.touch_app_outlined,
                color: manualOnly ? colors.primary : Colors.white,
              ),
            ),
            IconButton(
              tooltip: liked ? '取消喜欢' : '我喜欢',
              onPressed: () => controller.toggleFavorite(song),
              icon: Icon(
                liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                color: liked ? colors.primary : Colors.white,
              ),
            ),
          ],
        ),
        Text(
          song.artist,
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: Colors.white70),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ClipRect(
            child: _CrystalLyrics(
              lyrics: _lyrics,
              controller: controller,
              scrollController: _lyricsScrollController,
              onIndexChanged: _scrollCrystalLyrics,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          child: _CrystalGlassPlayButton(
            controller: controller,
            dimension: 54,
            iconSize: 31,
          ),
        ),
      ],
    );
  }

  void _scrollCrystalLyrics(int index) {
    if (index < 0 || index == _lastLyricsIndex) return;
    _lastLyricsIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_lyricsScrollController.hasClients) return;
      final target = (index * _lyricsLineExtent).clamp(
        0.0,
        _lyricsScrollController.position.maxScrollExtent,
      );
      if (MediaQuery.disableAnimationsOf(context)) {
        _lyricsScrollController.jumpTo(target);
      } else {
        _lyricsScrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _showQueue(BuildContext context) {
    showV4QueueSheet(context, widget.controller);
  }

  void _showListeningPreference(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ListeningPreferenceSheet(controller: widget.controller),
    );
  }
}

class _ViewDot extends StatelessWidget {
  const _ViewDot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    width: active ? 18 : 6,
    height: 6,
    decoration: BoxDecoration(
      color: active ? Colors.white : const Color(0x73FFFFFF),
      borderRadius: BorderRadius.circular(10),
    ),
  );
}

String _formatClock(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}:'
    '${value.second.toString().padLeft(2, '0')}';

double _crystalTimePanelWidth(BuildContext context, String value) {
  final painter = TextPainter(
    text: TextSpan(text: value, style: _crystalClockTextStyle),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  return painter.width + 36;
}

String _formatCrystalDate(DateTime value) {
  const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  return '${value.month}月${value.day}日  周${weekdays[value.weekday - 1]}';
}

class _ImmersivePlayerPage extends StatefulWidget {
  const _ImmersivePlayerPage({required this.controller});

  final AppController controller;

  @override
  State<_ImmersivePlayerPage> createState() => _ImmersivePlayerPageState();
}

class _ImmersivePlayerPageState extends State<_ImmersivePlayerPage> {
  final ScrollController _lyricsScrollController = ScrollController();
  TrackLyrics? _lyrics;
  String? _loadedTrackId;
  int _lastLyricsIndex = -1;
  double _dismissDragY = 0;
  bool _dismissDragActive = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
    _loadLyricsIfNeeded();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _lyricsScrollController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    _loadLyricsIfNeeded();
    if (mounted) setState(() {});
  }

  Future<void> _loadLyricsIfNeeded() async {
    final trackId = widget.controller.currentLibraryTrack?.track.trackId;
    if (trackId == null || trackId == _loadedTrackId) return;
    _loadedTrackId = trackId;
    _lyrics = null;
    _lastLyricsIndex = -1;
    final lyrics = await widget.controller.lyricsForTrack(trackId);
    if (!mounted || _loadedTrackId != trackId) return;
    setState(() => _lyrics = lyrics);
  }

  void _onVerticalDragStart(DragStartDetails details) {
    final height = MediaQuery.sizeOf(context).height;
    final showLyrics =
        widget.controller.immersivePlayerView == ImmersivePlayerView.lyrics;
    _dismissDragActive = showLyrics
        ? details.localPosition.dy <= 150
        : details.localPosition.dy >= 64 &&
              details.localPosition.dy <= height - 190;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_dismissDragActive) return;
    setState(() {
      _dismissDragY = (_dismissDragY + details.delta.dy).clamp(0.0, 180.0);
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (!_dismissDragActive) return;
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (_dismissDragY > 72 || velocity > 850) {
      Navigator.maybePop(context);
    } else if (mounted) {
      setState(() => _dismissDragY = 0);
    }
    _dismissDragActive = false;
  }

  void _onVerticalDragCancel() {
    _dismissDragActive = false;
    if (_dismissDragY != 0 && mounted) {
      setState(() => _dismissDragY = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final song = controller.currentSong;
    if (song == null) return const SizedBox.shrink();
    final liked = controller.favoriteIds.contains(song.id);
    final libraryTrack = controller.currentLibraryTrack;
    final manualOnly = libraryTrack?.preference.recommendationExcluded ?? false;
    final showLyrics =
        controller.immersivePlayerView == ImmersivePlayerView.lyrics;
    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: _onVerticalDragStart,
        onVerticalDragUpdate: _onVerticalDragUpdate,
        onVerticalDragEnd: _onVerticalDragEnd,
        onVerticalDragCancel: _onVerticalDragCancel,
        child: AnimatedContainer(
          key: const Key('immersive-dismiss-surface'),
          duration: _dismissDragActive
              ? Duration.zero
              : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(0, _dismissDragY, 0),
          child: Stack(
            fit: StackFit.expand,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  // Keep the artwork alive underneath the whole fade. The fade
                  // reaches an opaque player surface before this layer ends, so
                  // there is no visible horizontal image boundary.
                  final artworkHeight = math.min(
                    constraints.maxHeight * .62,
                    constraints.maxWidth / .92,
                  );
                  final fadeEnd = artworkHeight / constraints.maxHeight;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(color: Color(0xFF101317)),
                      Positioned(
                        key: const Key('immersive-artwork-layer'),
                        top: 0,
                        left: 0,
                        right: 0,
                        height: artworkHeight,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 260),
                          child: V4Artwork(
                            key: ValueKey('immersive-artwork-${song.id}'),
                            artwork: controller.currentLibraryTrack?.artwork,
                            borderRadius: 0,
                            fit: BoxFit.cover,
                            alignment: Alignment.topCenter,
                            semanticLabel: '${song.title}的背景封面',
                          ),
                        ),
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: <double>[
                              0,
                              fadeEnd * .42,
                              fadeEnd * .62,
                              fadeEnd * .78,
                              fadeEnd * .90,
                              fadeEnd,
                              1,
                            ],
                            colors: const <Color>[
                              Color(0x000A0B0E),
                              Color(0x080A0B0E),
                              Color(0x38101317),
                              Color(0xA8101317),
                              Color(0xEC101317),
                              Color(0xFF101317),
                              Color(0xFF101317),
                            ],
                          ),
                        ),
                      ),
                      IgnorePointer(
                        child: AnimatedOpacity(
                          key: const Key('immersive-lyrics-contrast-layer'),
                          opacity: showLyrics ? 1 : 0,
                          duration: const Duration(milliseconds: 220),
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: <Color>[
                                  Color(0x66101317),
                                  Color(0x8A101317),
                                  Color(0xA8101317),
                                  Color(0xC4101317),
                                ],
                                stops: <double>[0, .38, .72, 1],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 14),
                  child: Column(
                    children: [
                      const SizedBox(height: 42),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 240),
                          child: showLyrics
                              ? _ImmersiveLyrics(
                                  key: const Key('immersive-lyrics'),
                                  lyrics: _lyrics,
                                  controller: controller,
                                  scrollController: _lyricsScrollController,
                                  onIndexChanged: _scrollToLyricsIndex,
                                )
                              : const SizedBox.expand(
                                  key: Key('immersive-artwork'),
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium
                                      ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  song.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(color: Colors.white70),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '加入歌单',
                            onPressed: libraryTrack == null
                                ? null
                                : () =>
                                      showV4PlaylistPicker(context, controller),
                            icon: const Icon(
                              Icons.playlist_add_rounded,
                              color: Colors.white,
                            ),
                          ),
                          IconButton(
                            key: const Key('immersive-manual-only-action'),
                            tooltip: manualOnly ? '恢复自动推荐' : '设为仅手动播放',
                            onPressed: libraryTrack == null
                                ? null
                                : () => controller.setTrackManualOnly(
                                    libraryTrack,
                                    !manualOnly,
                                  ),
                            icon: Icon(
                              manualOnly
                                  ? Icons.touch_app_rounded
                                  : Icons.touch_app_outlined,
                              color: manualOnly
                                  ? const Color(0xFFFF8A9D)
                                  : Colors.white,
                            ),
                          ),
                          IconButton(
                            tooltip: liked ? '取消喜欢' : '我喜欢',
                            onPressed: () => controller.toggleFavorite(song),
                            icon: Icon(
                              liked
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              color: liked
                                  ? const Color(0xFFFF8A9D)
                                  : Colors.white,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _ImmersiveProgress(controller: controller, song: song),
                      const SizedBox(height: 38),
                      Transform.translate(
                        key: const Key('immersive-transport-lift'),
                        offset: const Offset(0, -_immersiveTransportLift),
                        child: _ImmersiveTransport(controller: controller),
                      ),
                      _VolumeControl(controller: controller),
                      if (controller.immersiveSleepPanelOpen)
                        _SleepTimerPanel(controller: controller),
                      _ImmersiveDestinations(
                        showLyrics: showLyrics,
                        onLyrics: () => controller.setImmersivePlayerView(
                          showLyrics
                              ? ImmersivePlayerView.artwork
                              : ImmersivePlayerView.lyrics,
                        ),
                        onSleep: () => controller.setImmersiveSleepPanelOpen(
                          !controller.immersiveSleepPanelOpen,
                        ),
                        onQueue: () => _showQueue(context),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _scrollToLyricsIndex(int index) {
    if (index < 0 || index == _lastLyricsIndex) return;
    _lastLyricsIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_lyricsScrollController.hasClients) return;
      final target = (index * _lyricsLineExtent).clamp(
        0.0,
        _lyricsScrollController.position.maxScrollExtent,
      );
      if (MediaQuery.disableAnimationsOf(context)) {
        _lyricsScrollController.jumpTo(target);
      } else {
        _lyricsScrollController.animateTo(
          target,
          duration: V4Motion.standard,
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _showQueue(BuildContext context) {
    showV4QueueSheet(context, widget.controller);
  }
}

class _TurntableArtwork extends StatefulWidget {
  const _TurntableArtwork({
    required this.controller,
    required this.song,
    required this.featureWidth,
    super.key,
  });

  final AppController controller;
  final Song song;
  final double featureWidth;

  @override
  State<_TurntableArtwork> createState() => _TurntableArtworkState();
}

class _TurntableArtworkState extends State<_TurntableArtwork>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncSpin);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _syncSpin();
  }

  @override
  void didUpdateWidget(covariant _TurntableArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncSpin);
      widget.controller.addListener(_syncSpin);
    }
    _syncSpin();
  }

  void _syncSpin() {
    if (_reduceMotion || !widget.controller.isPlaying) {
      _spin.stop();
    } else if (!_spin.isAnimating) {
      _spin.repeat();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncSpin);
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final song = widget.song;
    return LayoutBuilder(
      builder: (context, constraints) {
        final groupWidth = math.min(
          widget.featureWidth + _crystalTurntableWidthIncrease,
          constraints.maxWidth + _crystalTurntableWidthIncrease,
        );
        final coverSize = groupWidth / 1.44;
        final discSize = coverSize * .94;
        return OverflowBox(
          minWidth: groupWidth,
          maxWidth: groupWidth,
          minHeight: coverSize,
          maxHeight: coverSize,
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: const Key('crystal-turntable-group'),
            width: groupWidth,
            height: coverSize,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  key: const Key('crystal-disc'),
                  left: groupWidth - discSize,
                  top: (coverSize - discSize) / 2,
                  width: discSize,
                  height: discSize,
                  child: RotationTransition(
                    turns: _spin,
                    child: ClipOval(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          V4Artwork(
                            artwork: controller.currentLibraryTrack?.artwork,
                            borderRadius: discSize,
                            semanticLabel: '${song.title}的光碟封面',
                          ),
                          const ColoredBox(color: Color(0x520B1522)),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white54,
                                width: 1,
                              ),
                              gradient: const SweepGradient(
                                colors: <Color>[
                                  Color(0x00FFFFFF),
                                  Color(0x70FFFFFF),
                                  Color(0x10FFFFFF),
                                  Color(0x55ACCDEC),
                                  Color(0x00FFFFFF),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  key: const Key('crystal-cover-frame'),
                  left: 0,
                  top: 0,
                  width: coverSize,
                  height: coverSize,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: controller.currentLibraryTrack != null
                          ? V4Artwork(
                              artwork: controller.currentLibraryTrack!.artwork,
                              borderRadius: 14,
                              semanticLabel: '${song.title}的封面',
                            )
                          : SongArtwork(
                              song: song,
                              size: coverSize,
                              borderRadius: 14,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CurrentLyricLine extends StatelessWidget {
  const _CurrentLyricLine({
    required this.lyrics,
    required this.positionStream,
    required this.onTap,
  });

  final TrackLyrics? lyrics;
  final Stream<Duration> positionStream;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
    stream: positionStream,
    builder: (context, snapshot) {
      final text = lyrics?.lineAt(snapshot.data ?? Duration.zero)?.text;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: EdgeInsets.zero,
          child: Row(
            children: [
              const Icon(Icons.lyrics_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text?.isNotEmpty == true ? text! : '点击查看同步歌词',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 18),
            ],
          ),
        ),
      );
    },
  );
}

class _CrystalLyrics extends StatefulWidget {
  const _CrystalLyrics({
    required this.lyrics,
    required this.controller,
    required this.scrollController,
    required this.onIndexChanged,
  });

  final TrackLyrics? lyrics;
  final AppController controller;
  final ScrollController scrollController;
  final ValueChanged<int> onIndexChanged;

  @override
  State<_CrystalLyrics> createState() => _CrystalLyricsState();
}

class _CrystalLyricsState extends State<_CrystalLyrics> {
  Timer? _resumeTimer;
  bool _manualScrolling = false;
  late final Stream<Duration> _positionStream;

  @override
  void initState() {
    super.initState();
    _positionStream = widget.controller.player.createPositionStream(
      minPeriod: const Duration(milliseconds: 16),
      maxPeriod: const Duration(milliseconds: 32),
    );
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    super.dispose();
  }

  void _pauseFollowing() {
    _resumeTimer?.cancel();
    if (!_manualScrolling) setState(() => _manualScrolling = true);
    _resumeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _manualScrolling = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lyrics?.lines ?? const <LrcLine>[];
    if (lines.isEmpty) {
      return const _LyricsEmptyState(lightText: true);
    }
    return LayoutBuilder(
      builder: (context, constraints) => StreamBuilder<Duration>(
        stream: _positionStream,
        initialData: widget.controller.player.position,
        builder: (context, snapshot) {
          final position = snapshot.data ?? Duration.zero;
          final activeIndex = _activeLyricsIndex(lines, position);
          if (!_manualScrolling) widget.onIndexChanged(activeIndex);
          final viewportPadding = _lyricsViewportPadding(
            constraints.maxHeight,
            focusOffset: -_lyricsLineExtent,
          );
          return NotificationListener<ScrollStartNotification>(
            onNotification: (notification) {
              if (notification.dragDetails != null) _pauseFollowing();
              return false;
            },
            child: _LyricsEdgeFade(
              key: const Key('crystal-lyrics-edge-fade'),
              child: ListView.builder(
                controller: widget.scrollController,
                padding: viewportPadding,
                itemExtent: _lyricsLineExtent,
                itemCount: lines.length,
                itemBuilder: (context, index) {
                  final line = lines[index];
                  return _SyncedLyricLine(
                    line: line,
                    nextTimestamp: index + 1 < lines.length
                        ? lines[index + 1].timestamp
                        : null,
                    position: position,
                    active: index == activeIndex,
                    onTap: () => widget.controller.player.seek(line.timestamp),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SyncedLyricLine extends StatelessWidget {
  const _SyncedLyricLine({
    required this.line,
    required this.nextTimestamp,
    required this.position,
    required this.active,
    required this.onTap,
  });

  final LrcLine line;
  final Duration? nextTimestamp;
  final Duration position;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final value = line.text.isEmpty ? '…' : line.text;
    final style = (Theme.of(context).textTheme.titleMedium ?? const TextStyle())
        .copyWith(
          color: active
              ? Colors.white.withValues(alpha: .96)
              : Colors.white.withValues(alpha: .74),
          fontSize: active ? 20 : 16,
          height: 1.24,
          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          letterSpacing: .1,
          shadows: null,
        );
    return Semantics(
      selected: active,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: active && line.timingMode == LyricsTimingMode.wordTimed
              ? _ProgressiveLyricText(
                  line: line,
                  nextTimestamp: nextTimestamp,
                  position: position,
                  style: style,
                )
              : Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: active
                      ? style.copyWith(color: const Color(0xFF72E3AC))
                      : style,
                ),
        ),
      ),
    );
  }
}

class _LyricsEdgeFade extends StatelessWidget {
  const _LyricsEdgeFade({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final height = math.max(1.0, constraints.maxHeight);
      final edge = (_lyricsLineExtent / height).clamp(.08, .22);
      return ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const <Color>[
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: <double>[0, edge, 1 - edge, 1],
        ).createShader(bounds),
        child: child,
      );
    },
  );
}

class _ProgressiveLyricText extends StatelessWidget {
  const _ProgressiveLyricText({
    required this.line,
    required this.nextTimestamp,
    required this.position,
    required this.style,
  });

  final LrcLine line;
  final Duration? nextTimestamp;
  final Duration position;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final value = line.text.isEmpty ? '…' : line.text;
    final progress = _lyricProgress(line, nextTimestamp, position);
    return RepaintBoundary(
      child: SizedBox(
        width: double.infinity,
        height: _lyricsLineExtent - 6,
        child: CustomPaint(
          key: const Key('progressive-lyric-paint'),
          painter: _ProgressiveLyricPainter(
            text: value,
            style: style,
            progress: progress,
            textDirection: Directionality.of(context),
          ),
        ),
      ),
    );
  }
}

class _ProgressiveLyricPainter extends CustomPainter {
  const _ProgressiveLyricPainter({
    required this.text,
    required this.style,
    required this.progress,
    required this.textDirection,
  });

  final String text;
  final TextStyle style;
  final double progress;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final basePainter = _textPainter(style);
    basePainter.layout(maxWidth: size.width);
    final offset = Offset(0, (size.height - basePainter.height) / 2);
    basePainter.paint(canvas, offset);
    if (progress <= 0 || text.isEmpty) return;

    final runes = text.runes.toList(growable: false);
    final scaled = (progress.clamp(0.0, 1.0) * runes.length);
    final completeRunes = scaled.floor().clamp(0, runes.length);
    final partial = scaled - completeRunes;
    var completeOffset = 0;
    for (var index = 0; index < completeRunes; index++) {
      completeOffset += String.fromCharCode(runes[index]).length;
    }

    final clipPath = Path();
    if (completeOffset > 0) {
      for (final box in basePainter.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: completeOffset),
      )) {
        clipPath.addRect(box.toRect().shift(offset));
      }
    }
    if (partial > 0 && completeRunes < runes.length) {
      final nextOffset =
          completeOffset + String.fromCharCode(runes[completeRunes]).length;
      final boxes = basePainter.getBoxesForSelection(
        TextSelection(baseOffset: completeOffset, extentOffset: nextOffset),
      );
      for (final box in boxes) {
        final rect = box.toRect().shift(offset);
        clipPath.addRect(
          box.direction == TextDirection.rtl
              ? Rect.fromLTRB(
                  rect.right - rect.width * partial,
                  rect.top,
                  rect.right,
                  rect.bottom,
                )
              : Rect.fromLTRB(
                  rect.left,
                  rect.top,
                  rect.left + rect.width * partial,
                  rect.bottom,
                ),
        );
      }
    }
    if (clipPath.getBounds().isEmpty) return;

    canvas.save();
    canvas.clipPath(clipPath);
    _textPainter(style.copyWith(color: const Color(0xFF72E3AC)))
      ..layout(maxWidth: size.width)
      ..paint(canvas, offset);
    canvas.restore();
  }

  TextPainter _textPainter(TextStyle paintStyle) => TextPainter(
    text: TextSpan(text: text, style: paintStyle),
    textAlign: TextAlign.center,
    textDirection: textDirection,
    maxLines: 2,
    ellipsis: '…',
  );

  @override
  bool shouldRepaint(covariant _ProgressiveLyricPainter oldDelegate) =>
      oldDelegate.text != text ||
      oldDelegate.style != style ||
      oldDelegate.progress != progress ||
      oldDelegate.textDirection != textDirection;
}

EdgeInsets _lyricsViewportPadding(double height, {double focusOffset = 0}) {
  final top = math.max(
    20.0,
    height * .42 - _lyricsLineExtent / 2 + focusOffset,
  );
  final bottom = math.max(20.0, height - _lyricsLineExtent - top);
  return EdgeInsets.only(top: top, bottom: bottom);
}

double _lyricProgress(
  LrcLine line,
  Duration? nextTimestamp,
  Duration position,
) {
  if (position <= line.timestamp) return 0;
  if (line.hasWordTiming) {
    final totalCharacters = line.words.fold<int>(
      0,
      (total, word) => total + word.text.runes.length,
    );
    if (totalCharacters == 0) return 0;
    var completedCharacters = 0.0;
    for (var index = 0; index < line.words.length; index++) {
      final word = line.words[index];
      final wordLength = word.text.runes.length;
      final end =
          word.endTimestamp ??
          (index + 1 < line.words.length
              ? line.words[index + 1].timestamp
              : nextTimestamp ??
                    word.timestamp +
                        Duration(
                          milliseconds: math.max(500, wordLength * 360),
                        ));
      if (position >= end) {
        completedCharacters += wordLength;
        continue;
      }
      if (position > word.timestamp) {
        final duration = math.max(
          1,
          end.inMilliseconds - word.timestamp.inMilliseconds,
        );
        completedCharacters +=
            wordLength *
            ((position.inMilliseconds - word.timestamp.inMilliseconds) /
                    duration)
                .clamp(0.0, 1.0);
      }
      break;
    }
    return (completedCharacters / totalCharacters).clamp(0.0, 1.0);
  }
  return 1;
}

int _activeLyricsIndex(List<LrcLine> lines, Duration position) {
  var low = 0;
  var high = lines.length - 1;
  var selected = -1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    if (lines[middle].timestamp <= position) {
      selected = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return selected;
}

class _CrystalControls extends StatelessWidget {
  const _CrystalControls({required this.controller, required this.onQueue});

  final AppController controller;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final mode = controller.playbackMode;
    return SizedBox(
      height: 68,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          PopupMenuButton<String>(
            tooltip: '循环方式',
            icon: Icon(
              mode == PlaybackMode.repeatOne || mode == PlaybackMode.repeatCount
                  ? Icons.repeat_one_rounded
                  : Icons.repeat_rounded,
            ),
            onSelected: (value) {
              if (value == 'sequential') {
                controller.setPlaybackMode(PlaybackMode.sequential);
              } else if (value == 'one') {
                controller.setPlaybackMode(PlaybackMode.repeatOne);
              } else {
                final next = mode == PlaybackMode.repeatCount
                    ? ((controller.repeatCount ?? 2) >= 5
                          ? 2
                          : (controller.repeatCount ?? 2) + 1)
                    : 2;
                controller.setRepeatCount(next);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'sequential', child: Text('顺序播放')),
              const PopupMenuItem(value: 'one', child: Text('单曲循环')),
              PopupMenuItem(
                value: 'count',
                child: Text('设置次数  ${controller.repeatCount ?? 2} 次'),
              ),
            ],
          ),
          IconButton(
            tooltip: '上一首',
            onPressed: controller.previous,
            iconSize: 34,
            icon: const Icon(Icons.skip_previous_rounded),
          ),
          _CrystalGlassPlayButton(
            controller: controller,
            dimension: 66,
            iconSize: 37,
          ),
          IconButton(
            tooltip: '下一首',
            onPressed: controller.next,
            iconSize: 34,
            icon: const Icon(Icons.skip_next_rounded),
          ),
          IconButton(
            tooltip: '播放队列',
            onPressed: onQueue,
            icon: const Icon(Icons.queue_music_rounded),
          ),
        ],
      ),
    );
  }
}

class _CrystalGlassPlayButton extends StatelessWidget {
  const _CrystalGlassPlayButton({
    required this.controller,
    required this.dimension,
    required this.iconSize,
  });

  final AppController controller;
  final double dimension;
  final double iconSize;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: dimension,
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0x66FFFFFF), Color(0x12FFFFFF)],
        ),
        border: Border.all(color: const Color(0xB8FFFFFF), width: 1.2),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x70FFFFFF),
            offset: Offset(-2, -2),
            blurRadius: 5,
          ),
          BoxShadow(
            color: Color(0x24183848),
            offset: Offset(3, 5),
            blurRadius: 10,
          ),
        ],
      ),
      child: IconButton(
        tooltip: controller.isPlaying ? '暂停' : '播放',
        onPressed: controller.togglePlay,
        iconSize: iconSize,
        color: const Color(0xFF183848),
        highlightColor: Colors.white24,
        icon: Icon(
          controller.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        ),
      ),
    ),
  );
}

class _ListeningPreferenceSheet extends StatelessWidget {
  const _ListeningPreferenceSheet({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.82,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final preference = controller.listeningPreference;
          final now = DateTime.now();
          final active = preference.isActiveAt(now);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '自动听歌偏好',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          active ? '熟悉度设置生效中，听歌习惯仍会自动学习' : '默认自动学习，无需每天设置',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: controller.resetListeningPreference,
                    child: const Text('重置'),
                  ),
                ],
              ),
              if (preference.savedAt != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '上次调节：${preference.savedAt!.year}-${preference.savedAt!.month}-${preference.savedAt!.day}（30 天有效） · ${active ? '生效中' : '已过期'}',
                  ),
                ),
              _PreferenceSection<FamiliarityPreference>(
                title: '歌曲熟悉度',
                value: preference.familiarity,
                values: FamiliarityPreference.values,
                label: (value) => switch (value) {
                  FamiliarityPreference.explore => '更探索',
                  FamiliarityPreference.balanced => '保持现状',
                  FamiliarityPreference.familiar => '更熟悉',
                },
                onChanged: controller.setFamiliarityPreference,
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  '系统会自动结合当前时间段、主动点歌、完整收听和跳过来调整下一批歌曲。'
                  '不想再被自动选中的歌曲，可设为“仅手动播放”。',
                  style: TextStyle(height: 1.55),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () async {
                  await controller.saveListeningPreference();
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('保存偏好'),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _PreferenceSection<T> extends StatelessWidget {
  const _PreferenceSection({
    required this.title,
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });

  final String title;
  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<T>(
          segments: [
            for (final item in values)
              ButtonSegment<T>(value: item, label: Text(label(item))),
          ],
          selected: {value},
          onSelectionChanged: (selection) => onChanged(selection.first),
          showSelectedIcon: false,
        ),
      ],
    ),
  );
}

class _LyricsEmptyState extends StatelessWidget {
  const _LyricsEmptyState({this.lightText = false});

  final bool lightText;

  @override
  Widget build(BuildContext context) {
    final color = lightText ? Colors.white70 : null;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lyrics_outlined, size: 46, color: color),
          const SizedBox(height: 12),
          Text(
            '这首歌还没有可用歌词',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(color: color),
          ),
          const SizedBox(height: 8),
          Text(
            '同名 LRC 会在重新扫描后自动关联',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _ImmersiveLyrics extends StatefulWidget {
  const _ImmersiveLyrics({
    required this.lyrics,
    required this.controller,
    required this.scrollController,
    required this.onIndexChanged,
    super.key,
  });

  final TrackLyrics? lyrics;
  final AppController controller;
  final ScrollController scrollController;
  final ValueChanged<int> onIndexChanged;

  @override
  State<_ImmersiveLyrics> createState() => _ImmersiveLyricsState();
}

class _ImmersiveLyricsState extends State<_ImmersiveLyrics> {
  Timer? _resumeTimer;
  bool _manualScrolling = false;
  late final Stream<Duration> _positionStream;

  @override
  void initState() {
    super.initState();
    _positionStream = widget.controller.player.createPositionStream(
      minPeriod: const Duration(milliseconds: 16),
      maxPeriod: const Duration(milliseconds: 32),
    );
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    super.dispose();
  }

  void _pauseFollowing() {
    _resumeTimer?.cancel();
    if (!_manualScrolling) setState(() => _manualScrolling = true);
    _resumeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _manualScrolling = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lyrics?.lines ?? const <LrcLine>[];
    return lines.isEmpty
        ? const _LyricsEmptyState(lightText: true)
        : StreamBuilder<Duration>(
            stream: _positionStream,
            initialData: widget.controller.player.position,
            builder: (context, snapshot) {
              final position = snapshot.data ?? Duration.zero;
              final activeIndex = _activeLyricsIndex(lines, position);
              if (!_manualScrolling) {
                widget.onIndexChanged(activeIndex);
              }
              return LayoutBuilder(
                builder: (context, constraints) {
                  final viewportPadding = _lyricsViewportPadding(
                    constraints.maxHeight,
                  );
                  return NotificationListener<ScrollStartNotification>(
                    onNotification: (notification) {
                      if (notification.dragDetails != null) {
                        _pauseFollowing();
                      }
                      return false;
                    },
                    child: _LyricsEdgeFade(
                      key: const Key('immersive-lyrics-edge-fade'),
                      child: ListView.builder(
                        controller: widget.scrollController,
                        padding: viewportPadding.copyWith(left: 8, right: 8),
                        itemExtent: _lyricsLineExtent,
                        itemCount: lines.length,
                        itemBuilder: (context, index) {
                          final line = lines[index];
                          return _SyncedLyricLine(
                            line: line,
                            nextTimestamp: index + 1 < lines.length
                                ? lines[index + 1].timestamp
                                : null,
                            position: position,
                            active: index == activeIndex,
                            onTap: () =>
                                widget.controller.player.seek(line.timestamp),
                          );
                        },
                      ),
                    ),
                  );
                },
              );
            },
          );
  }
}

class _ImmersiveProgress extends StatelessWidget {
  const _ImmersiveProgress({required this.controller, required this.song});

  final AppController controller;
  final Song song;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
    stream: controller.player.positionStream,
    initialData: controller.player.position,
    builder: (context, snapshot) {
      final position = snapshot.data ?? Duration.zero;
      final duration = controller.player.duration ?? song.duration;
      final max = math.max(1.0, duration.inMilliseconds.toDouble());
      final value = position.inMilliseconds.toDouble().clamp(0.0, max);
      final remaining = duration - position;
      return Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              overlayColor: Colors.white12,
            ),
            child: Slider(
              key: const Key('immersive-progress-slider'),
              value: value,
              max: max,
              onChanged: (next) =>
                  controller.player.seek(Duration(milliseconds: next.round())),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                formatDuration(position),
                style: const TextStyle(color: Colors.white70),
              ),
              Text(
                '−${formatDuration(remaining.isNegative ? Duration.zero : remaining)}',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class _ImmersiveTransport extends StatelessWidget {
  const _ImmersiveTransport({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 84,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '上一首',
          onPressed: controller.previous,
          iconSize: 46,
          color: Colors.white,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        const SizedBox(width: 24),
        IconButton.filled(
          tooltip: controller.isPlaying ? '暂停' : '播放',
          onPressed: controller.togglePlay,
          iconSize: 56,
          style: IconButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: .10),
            foregroundColor: const Color(0xFFFF8A9D),
            side: BorderSide(color: Colors.white.withValues(alpha: .14)),
            shape: const CircleBorder(),
            padding: const EdgeInsets.all(14),
          ),
          icon: Icon(
            controller.isPlaying
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
          ),
        ),
        const SizedBox(width: 24),
        IconButton(
          tooltip: '下一首',
          onPressed: controller.next,
          iconSize: 46,
          color: Colors.white,
          icon: const Icon(Icons.skip_next_rounded),
        ),
      ],
    ),
  );
}

class _VolumeControl extends StatelessWidget {
  const _VolumeControl({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(Icons.headphones_rounded, color: Colors.white70, size: 20),
      Expanded(
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Colors.white70,
            inactiveTrackColor: Colors.white24,
            thumbColor: Colors.white,
            overlayColor: Colors.white12,
          ),
          child: Slider(
            key: const Key('immersive-volume-slider'),
            value: controller.volumePercent,
            max: 100,
            onChanged: controller.setVolumePercent,
          ),
        ),
      ),
      SizedBox(
        width: 34,
        child: Text(
          controller.volumePercent.round().toString(),
          textAlign: TextAlign.right,
          style: const TextStyle(color: Colors.white70),
        ),
      ),
    ],
  );
}

class _SleepTimerPanel extends StatelessWidget {
  const _SleepTimerPanel({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final remaining = controller.sleepTimerRemaining;
    final minutes = remaining == null
        ? null
        : (remaining.inSeconds / 60).ceil();
    return Container(
      key: const Key('sleep-timer-panel'),
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  minutes == null ? '还没设置' : '已设 $minutes 分钟',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (remaining != null)
                TextButton(
                  onPressed: controller.cancelSleepTimer,
                  child: const Text('关闭定时'),
                ),
            ],
          ),
          Row(
            children: [
              _TimerChoice(minutes: 15, controller: controller),
              const SizedBox(width: 8),
              _TimerChoice(minutes: 30, controller: controller),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _showCustomTimer(context),
                  child: const Text('自定义'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showCustomTimer(BuildContext context) async {
    final textController = TextEditingController();
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('自定义停止时间'),
        content: TextField(
          controller: textController,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: '分钟',
            helperText: '1–600 分钟',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, int.tryParse(textController.text)),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    textController.dispose();
    if (value == null || !context.mounted) return;
    if (value < 1 || value > 600) {
      controller.showMessage(value > 600 ? '最多 600 分钟（10 小时）' : '至少 1 分钟');
      return;
    }
    controller.setSleepTimerMinutes(value);
  }
}

class _TimerChoice extends StatelessWidget {
  const _TimerChoice({required this.minutes, required this.controller});

  final int minutes;
  final AppController controller;

  @override
  Widget build(BuildContext context) => Expanded(
    child: OutlinedButton(
      onPressed: () => controller.setSleepTimerMinutes(minutes),
      child: Text('$minutes 分钟'),
    ),
  );
}

class _ImmersiveDestinations extends StatelessWidget {
  const _ImmersiveDestinations({
    required this.showLyrics,
    required this.onLyrics,
    required this.onSleep,
    required this.onQueue,
  });

  final bool showLyrics;
  final VoidCallback onLyrics;
  final VoidCallback onSleep;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: TextButton.icon(
          onPressed: onLyrics,
          style: TextButton.styleFrom(foregroundColor: Colors.white),
          icon: Icon(showLyrics ? Icons.album_rounded : Icons.lyrics_outlined),
          label: Text(showLyrics ? '封面' : '歌词'),
        ),
      ),
      Expanded(
        child: TextButton.icon(
          onPressed: onSleep,
          style: TextButton.styleFrom(foregroundColor: Colors.white),
          icon: const Icon(Icons.bedtime_outlined),
          label: const Text('睡眠定时'),
        ),
      ),
      Expanded(
        child: TextButton.icon(
          onPressed: onQueue,
          style: TextButton.styleFrom(foregroundColor: Colors.white),
          icon: const Icon(Icons.queue_music_rounded),
          label: const Text('队列'),
        ),
      ),
    ],
  );
}

class _PlayerProgress extends StatelessWidget {
  const _PlayerProgress({required this.controller, required this.song});

  final AppController controller;
  final Song song;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
    stream: controller.player.positionStream,
    builder: (context, snapshot) {
      final position = snapshot.data ?? Duration.zero;
      final duration = controller.player.duration ?? song.duration;
      final max = math.max(1.0, duration.inMilliseconds.toDouble());
      final value = position.inMilliseconds.toDouble().clamp(0.0, max);
      return Column(
        children: [
          SizedBox(
            key: const Key('crystal-progress-track'),
            height: 26,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: value,
                max: max,
                onChanged: (value) => controller.player.seek(
                  Duration(milliseconds: value.round()),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: V4Space.xs),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  formatDuration(position),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                Text(
                  formatDuration(duration),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
