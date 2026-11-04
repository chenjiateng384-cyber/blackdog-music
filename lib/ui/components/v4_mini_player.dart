import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/app_controller.dart';
import '../../models/v4/artwork.dart';
import '../../models/v4/library_track.dart';
import '../../models/v4/lyrics.dart';
import '../../models/v4/playback.dart';
import '../v4_artwork.dart';
import '../v4_artwork_palette.dart';
import '../v4_design_system.dart';

class V4MiniPlayer extends StatefulWidget {
  const V4MiniPlayer({
    required this.controller,
    required this.onTap,
    super.key,
  });

  final AppController controller;
  final VoidCallback onTap;

  @override
  State<V4MiniPlayer> createState() => _V4MiniPlayerState();
}

class _V4MiniPlayerState extends State<V4MiniPlayer> {
  TrackLyrics? _lyrics;
  String? _loadedTrackId;
  String? _prefetchedAroundTrackId;
  late final StreamController<Duration> _positionController;
  Timer? _positionTicker;
  Duration? _lastPosition;
  Duration? _lastDuration;
  double _dragX = 0;
  bool _dragging = false;
  bool _animating = false;
  DateTime _ignoreTapUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _positionController = StreamController<Duration>.broadcast();
    // The native player can emit position updates much faster than this
    // compact component can visually communicate. Four updates per second
    // keeps the progress ring and lyrics responsive without continuously
    // rebuilding two Mini Player subtrees.
    _positionTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_positionController.isClosed) return;
      final position = widget.controller.player.position;
      final duration =
          widget.controller.player.duration ??
          widget.controller.currentSong?.duration;
      if (position == _lastPosition && duration == _lastDuration) return;
      _lastPosition = position;
      _lastDuration = duration;
      _positionController.add(position);
    });
  }

  @override
  void dispose() {
    _positionTicker?.cancel();
    unawaited(_positionController.close());
    super.dispose();
  }

  void _ensureLyrics(String? trackId) {
    if (trackId == null || trackId == _loadedTrackId) return;
    _loadedTrackId = trackId;
    _lyrics = null;
    unawaited(_loadLyrics(trackId));
  }

  void _precacheAdjacentArtwork(String? trackId) {
    if (trackId == null || trackId == _prefetchedAroundTrackId) return;
    _prefetchedAroundTrackId = trackId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final snapshot = widget.controller.playbackQueue;
      final index = snapshot.currentIndex;
      if (index < 0) return;
      final extent = (52 * MediaQuery.devicePixelRatioOf(context)).ceil();
      for (final candidateIndex in <int>[index - 1, index + 1]) {
        if (candidateIndex < 0 || candidateIndex >= snapshot.entries.length) {
          continue;
        }
        final path = snapshot.entries[candidateIndex].track.artwork?.cachePath;
        if (path == null || path.isEmpty) continue;
        final provider = ResizeImage.resizeIfNeeded(
          extent,
          extent,
          FileImage(File(path)),
        );
        unawaited(precacheImage(provider, context).catchError((_) {}));
      }
    });
  }

  Future<void> _loadLyrics(String trackId) async {
    final result = await widget.controller.lyricsForTrack(trackId);
    if (!mounted || _loadedTrackId != trackId) return;
    setState(() => _lyrics = result);
  }

  void _onDragStart(DragStartDetails details) {
    setState(() {
      _dragging = true;
      _animating = false;
      _dragX = 0;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    setState(() => _dragX += details.delta.dx);
  }

  Future<void> _onDragEnd(DragEndDetails details) async {
    if (!_dragging) return;
    final width = MediaQuery.sizeOf(context).width - (V4Space.sm * 2);
    final velocity = details.velocity.pixelsPerSecond.dx;
    final threshold = math.min(58.0, width * .16);
    final crossed = _dragX.abs() >= threshold || velocity.abs() >= 650;
    _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 300));
    if (!crossed) {
      setState(() {
        _dragging = false;
        _animating = true;
        _dragX = 0;
      });
      return;
    }

    final direction = (_dragX == 0 ? velocity : _dragX).isNegative ? -1.0 : 1.0;
    setState(() {
      _dragging = false;
      _animating = true;
      _dragX = direction * math.min(72.0, width * .20);
    });
    if (direction < 0) {
      await widget.controller.next();
    } else {
      await widget.controller.previous();
    }
    if (!mounted) return;
    setState(() {
      _animating = false;
      _dragX = -direction * math.min(56.0, width * .16);
    });
    await Future<void>.delayed(const Duration(milliseconds: 16));
    if (!mounted) return;
    setState(() {
      _animating = true;
      _dragX = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.controller.currentSong!;
    final track = widget.controller.currentLibraryTrack;
    _ensureLyrics(track?.track.trackId);
    _precacheAdjacentArtwork(track?.track.trackId);
    final scale = 1.0 - math.min<double>(0.02, _dragX.abs() / 6000.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        V4Space.sm,
        V4Space.xxs,
        V4Space.sm,
        V4Space.xs,
      ),
      child: V4ArtworkTintBuilder(
        artwork: track?.artwork,
        fallbackSeed: track?.track.trackId ?? song.title,
        builder: (context, primary) {
          final surface = Theme.of(context).colorScheme.surface;
          return Material(
            key: const Key('v4-mini-player'),
            color: Colors.transparent,
            elevation: 2,
            shadowColor: Colors.black.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: Ink(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color.lerp(surface, primary, 0.55)!,
                    Color.lerp(surface, primary, 0.10)!,
                  ],
                ),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 68),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: _onDragStart,
                        onHorizontalDragUpdate: _onDragUpdate,
                        onHorizontalDragEnd: _onDragEnd,
                        child: AnimatedContainer(
                          duration: _animating
                              ? V4Motion.standard
                              : Duration.zero,
                          curve: Curves.easeOutCubic,
                          transformAlignment: Alignment.center,
                          transform: Matrix4.identity()
                            ..translateByDouble(_dragX, 0, 0, 1)
                            ..scaleByDouble(scale, scale, 1, 1),
                          child: InkWell(
                            onTap: () {
                              if (DateTime.now().isBefore(_ignoreTapUntil)) {
                                return;
                              }
                              widget.onTap();
                            },
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                              child: Row(
                                children: [
                                  AnimatedSwitcher(
                                    duration: V4Motion.standard,
                                    child: _MiniArtworkWithDisc(
                                      key: ValueKey('mini-artwork-${song.id}'),
                                      artwork: track?.artwork,
                                      fallbackSeed:
                                          track?.track.trackId ?? song.title,
                                      playing: widget.controller.isPlaying,
                                      semanticLabel: '${song.title}的封面',
                                    ),
                                  ),
                                  const SizedBox(width: V4Space.xs),
                                  Expanded(
                                    child: _MiniTrackText(
                                      controller: widget.controller,
                                      positionStream:
                                          _positionController.stream,
                                      lyrics: _lyrics,
                                      title: song.title,
                                      artist: song.artist,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    _ProgressPlayButton(
                      controller: widget.controller,
                      positionStream: _positionController.stream,
                    ),
                    IconButton(
                      key: const Key('v4-mini-player-next'),
                      tooltip: '下一首',
                      onPressed: widget.controller.next,
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                    const SizedBox(width: 2),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MiniArtworkWithDisc extends StatefulWidget {
  const _MiniArtworkWithDisc({
    required this.artwork,
    required this.fallbackSeed,
    required this.playing,
    required this.semanticLabel,
    super.key,
  });

  final ArtworkReference? artwork;
  final String fallbackSeed;
  final bool playing;
  final String semanticLabel;

  @override
  State<_MiniArtworkWithDisc> createState() => _MiniArtworkWithDiscState();
}

class _MiniArtworkWithDiscState extends State<_MiniArtworkWithDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _rotation.repeat();
  }

  @override
  void didUpdateWidget(covariant _MiniArtworkWithDisc oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing == oldWidget.playing) return;
    if (widget.playing) {
      _rotation.repeat();
    } else {
      _rotation.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const coverSize = 50.0;
    const discSize = 46.0;
    return SizedBox(
      key: const Key('v4-mini-player-artwork-group'),
      width: 73,
      height: 52,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 26,
            top: 3,
            width: discSize,
            height: discSize,
            child: RepaintBoundary(
              child: RotationTransition(
                key: const Key('v4-mini-player-disc'),
                turns: _rotation,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ExcludeSemantics(
                      child: V4Artwork(
                        artwork: widget.artwork,
                        fallbackSeed: widget.fallbackSeed,
                        size: discSize,
                        borderRadius: discSize / 2,
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            Colors.black.withValues(alpha: .08),
                            Colors.black.withValues(alpha: .36),
                            Colors.black.withValues(alpha: .62),
                          ],
                          stops: const [.10, .58, 1],
                        ),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: .24),
                          width: .8,
                        ),
                      ),
                    ),
                    CustomPaint(painter: _MiniVinylPainter()),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 1,
            child: V4Artwork(
              key: const Key('v4-mini-player-artwork'),
              artwork: widget.artwork,
              fallbackSeed: widget.fallbackSeed,
              size: coverSize,
              borderRadius: 15,
              semanticLabel: widget.semanticLabel,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniVinylPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .55
      ..color = Colors.white.withValues(alpha: .22);
    for (final radius in <double>[.28, .36, .44]) {
      canvas.drawCircle(center, size.shortestSide * radius, groove);
    }
    final highlight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: .40);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: size.shortestSide * .41),
      -.9,
      .42,
      false,
      highlight,
    );
    canvas.drawCircle(
      center,
      2.1,
      Paint()..color = Colors.white.withValues(alpha: .90),
    );
  }

  @override
  bool shouldRepaint(covariant _MiniVinylPainter oldDelegate) => false;
}

class _MiniTrackText extends StatelessWidget {
  const _MiniTrackText({
    required this.controller,
    required this.positionStream,
    required this.lyrics,
    required this.title,
    required this.artist,
  });

  final AppController controller;
  final Stream<Duration> positionStream;
  final TrackLyrics? lyrics;
  final String title;
  final String artist;

  @override
  Widget build(BuildContext context) {
    if (!controller.isPlaying) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MarqueeLine(
            text: title,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          _MarqueeLine(
            text: artist,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }
    return StreamBuilder<Duration>(
      stream: positionStream,
      initialData: controller.player.position,
      builder: (context, snapshot) {
        final lyric = lyrics
            ?.lineAt(snapshot.data ?? Duration.zero)
            ?.text
            .trim();
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, animation) {
            final outgoing = animation.status == AnimationStatus.reverse;
            final slide =
                Tween<Offset>(
                  begin: Offset(outgoing ? -.18 : .18, 0),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOut),
                );
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(position: slide, child: child),
            );
          },
          child: Align(
            key: ValueKey('mini-lyric-${lyric ?? title}'),
            alignment: Alignment.center,
            heightFactor: 1,
            child: _BalancedMiniLyric(
              lyric == null || lyric.isEmpty ? title : lyric,
              style: const TextStyle(
                fontSize: 14,
                height: 1.18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BalancedMiniLyric extends StatefulWidget {
  const _BalancedMiniLyric(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_BalancedMiniLyric> createState() => _BalancedMiniLyricState();
}

class _BalancedMiniLyricState extends State<_BalancedMiniLyric> {
  String? _cachedText;
  TextStyle? _cachedStyle;
  TextDirection? _cachedDirection;
  double? _cachedWidth;
  double? _cachedScaledFontSize;
  String _balanced = '';

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final direction = Directionality.of(context);
      final textScaler = MediaQuery.textScalerOf(context);
      final scaledFontSize = textScaler.scale(widget.style.fontSize ?? 14);
      if (_cachedText != widget.text ||
          _cachedStyle != widget.style ||
          _cachedDirection != direction ||
          _cachedWidth != constraints.maxWidth ||
          _cachedScaledFontSize != scaledFontSize) {
        _cachedText = widget.text;
        _cachedStyle = widget.style;
        _cachedDirection = direction;
        _cachedWidth = constraints.maxWidth;
        _cachedScaledFontSize = scaledFontSize;
        _balanced = _balanceAcrossTwoLines(
          widget.text,
          widget.style,
          constraints.maxWidth,
          direction,
          textScaler,
        );
      }
      return Text(
        _balanced,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: widget.style,
      );
    },
  );
}

String _balanceAcrossTwoLines(
  String source,
  TextStyle style,
  double maxWidth,
  TextDirection direction,
  TextScaler textScaler,
) {
  final text = source.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty || !maxWidth.isFinite || maxWidth <= 0) return text;

  double widthOf(String value) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      maxLines: 1,
      textDirection: direction,
      textScaler: textScaler,
    )..layout();
    return painter.width;
  }

  if (widthOf(text) <= maxWidth) return text;
  var best = text;
  var bestScore = double.infinity;
  for (var index = 1; index < text.length; index++) {
    final previous = text.codeUnitAt(index - 1);
    final next = text.codeUnitAt(index);
    if (_isHighSurrogate(previous) && _isLowSurrogate(next)) continue;
    final first = text.substring(0, index).trimRight();
    final second = text.substring(index).trimLeft();
    if (first.isEmpty || second.isEmpty) continue;
    final firstWidth = widthOf(first);
    final secondWidth = widthOf(second);
    final overflow =
        math.max(0.0, firstWidth - maxWidth) +
        math.max(0.0, secondWidth - maxWidth);
    final splitInsideWord = _isAsciiWord(previous) && _isAsciiWord(next);
    final shortLine = math.min(firstWidth, secondWidth) < maxWidth * .34;
    final score =
        overflow * 30 +
        (firstWidth - secondWidth).abs() +
        (splitInsideWord ? maxWidth : 0) +
        (shortLine ? maxWidth * .35 : 0);
    if (score < bestScore) {
      bestScore = score;
      best = '$first\n$second';
    }
  }
  return best;
}

bool _isHighSurrogate(int value) => value >= 0xD800 && value <= 0xDBFF;

bool _isLowSurrogate(int value) => value >= 0xDC00 && value <= 0xDFFF;

bool _isAsciiWord(int value) =>
    (value >= 0x30 && value <= 0x39) ||
    (value >= 0x41 && value <= 0x5A) ||
    (value >= 0x61 && value <= 0x7A);

class _MarqueeLine extends StatelessWidget {
  const _MarqueeLine({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) =>
      Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
}

class _ProgressPlayButton extends StatelessWidget {
  const _ProgressPlayButton({
    required this.controller,
    required this.positionStream,
  });

  final AppController controller;
  final Stream<Duration> positionStream;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
    stream: positionStream,
    initialData: controller.player.position,
    builder: (context, snapshot) {
      final duration =
          controller.player.duration ??
          controller.currentSong?.duration ??
          Duration.zero;
      final max = duration.inMilliseconds;
      final value = max <= 0
          ? 0.0
          : (snapshot.data?.inMilliseconds ?? 0).clamp(0, max) / max;
      final colors = Theme.of(context).colorScheme;
      return SizedBox.square(
        key: const Key('v4-mini-player-progress'),
        dimension: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.square(
              dimension: 36,
              child: CircularProgressIndicator(
                key: const Key('v4-mini-player-progress-ring'),
                value: value,
                strokeWidth: 2.2,
                strokeCap: StrokeCap.round,
                color: colors.primary,
                backgroundColor: colors.onSurface.withValues(alpha: .14),
              ),
            ),
            IconButton(
              key: const Key('v4-mini-player-toggle'),
              tooltip: controller.isPlaying ? '暂停' : '播放',
              onPressed: controller.togglePlay,
              style: IconButton.styleFrom(foregroundColor: colors.primary),
              icon: Icon(
                controller.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
            ),
          ],
        ),
      );
    },
  );
}

Future<void> showV4QueueSheet(
  BuildContext context,
  AppController controller,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (sheetContext) => DefaultTabController(
    length: 2,
    child: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.76,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: V4Space.page),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '队列 · ${controller.playbackQueue.entries.length} 首歌曲',
                        style: Theme.of(sheetContext).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: '清空待播',
                      onPressed: controller.upcomingQueueEntries.isEmpty
                          ? null
                          : controller.clearUpcoming,
                      icon: const Icon(Icons.playlist_remove_rounded),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  V4Space.sm,
                  V4Space.xs,
                  V4Space.sm,
                  V4Space.sm,
                ),
                child: Row(
                  children: [
                    _QueueModeButton(
                      icon: Icons.shuffle_rounded,
                      label: '随机',
                      selected: controller.playbackMode == PlaybackMode.shuffle,
                      onTap: () =>
                          controller.setPlaybackMode(PlaybackMode.shuffle),
                    ),
                    _QueueModeButton(
                      icon: Icons.format_list_numbered_rounded,
                      label: '顺序',
                      selected:
                          controller.playbackMode == PlaybackMode.sequential,
                      onTap: () =>
                          controller.setPlaybackMode(PlaybackMode.sequential),
                    ),
                    _QueueModeButton(
                      icon: Icons.repeat_one_rounded,
                      label: '单曲',
                      selected:
                          controller.playbackMode == PlaybackMode.repeatOne,
                      onTap: () =>
                          controller.setPlaybackMode(PlaybackMode.repeatOne),
                    ),
                    _QueueModeButton(
                      icon: Icons.repeat_rounded,
                      label: '循环',
                      selected:
                          controller.playbackMode == PlaybackMode.repeatAll,
                      onTap: () =>
                          controller.setPlaybackMode(PlaybackMode.repeatAll),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: '接下来播放'),
                  Tab(text: '已播放'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _UpcomingQueue(controller: controller),
                    _PlayedQueue(controller: controller),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

class _QueueModeButton extends StatelessWidget {
  const _QueueModeButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(V4Radius.control),
        onTap: onTap,
        child: AnimatedContainer(
          duration: V4Motion.quick,
          padding: const EdgeInsets.symmetric(vertical: V4Space.xs),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).colorScheme.primaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(V4Radius.control),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              Text(label, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    ),
  );
}

class _UpcomingQueue extends StatelessWidget {
  const _UpcomingQueue({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final current = controller.playbackQueue.current;
    final upcoming = controller.upcomingQueueEntries;
    if (current == null && upcoming.isEmpty) {
      return const Center(child: Text('播放队列是空的'));
    }
    final entries = [?current, ...upcoming];
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(
        V4Space.page,
        V4Space.xs,
        V4Space.page,
        V4Space.section,
      ),
      itemCount: entries.length,
      onReorderItem: (oldIndex, newIndex) {
        if (oldIndex == 0 || current == null) return;
        HapticFeedback.selectionClick();
        controller.moveUpcoming(oldIndex - 1, math.max(0, newIndex - 1));
      },
      itemBuilder: (context, index) {
        final entry = entries[index];
        final isCurrent = current?.entryId == entry.entryId;
        return Dismissible(
          key: ValueKey('queue-${entry.entryId}'),
          direction: isCurrent
              ? DismissDirection.none
              : DismissDirection.endToStart,
          onDismissed: (_) {
            HapticFeedback.selectionClick();
            controller.removeQueueEntry(entry.entryId);
          },
          background: ColoredBox(
            color: Theme.of(context).colorScheme.errorContainer,
            child: const Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: EdgeInsets.only(right: V4Space.page),
                child: Icon(Icons.delete_outline_rounded),
              ),
            ),
          ),
          child: _QueueTrackRow(
            track: entry.track,
            prefix: isCurrent ? '正在播放 · ' : '',
            onTap: isCurrent
                ? null
                : () => controller.playQueueEntry(entry.entryId),
            trailing: isCurrent
                ? Icon(
                    Icons.graphic_eq_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : const Icon(Icons.drag_handle_rounded),
          ),
        );
      },
    );
  }
}

class _PlayedQueue extends StatelessWidget {
  const _PlayedQueue({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tracks = controller.playbackHistory;
    if (tracks.isEmpty) return const Center(child: Text('还没有播放记录'));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        V4Space.page,
        V4Space.xs,
        V4Space.page,
        V4Space.section,
      ),
      itemCount: tracks.length,
      itemBuilder: (context, index) => _QueueTrackRow(track: tracks[index]),
    );
  }
}

class _QueueTrackRow extends StatelessWidget {
  const _QueueTrackRow({
    required this.track,
    this.prefix = '',
    this.onTap,
    this.trailing,
  });

  final LibraryTrack track;
  final String prefix;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: V4Artwork(
      artwork: track.artwork,
      size: 48,
      semanticLabel: '${track.track.title}的封面',
    ),
    title: Text(
      '$prefix${track.track.title}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      track.track.artistDisplay,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: trailing,
    onTap: onTap,
  );
}
