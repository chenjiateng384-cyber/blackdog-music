import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/app_controller.dart';
import '../models/v4/library_browsing.dart';
import '../models/v4/library_track.dart';
import 'components/v4_foundation.dart';
import 'components/v4_mini_player.dart';
import 'v4_artwork.dart';
import 'v4_artwork_palette.dart';
import 'v4_design_system.dart';
import 'v4_player_page.dart';

class V4ArtistDetailPage extends StatefulWidget {
  const V4ArtistDetailPage({
    required this.controller,
    required this.summary,
    super.key,
  });

  final AppController controller;
  final ArtistLibrarySummary summary;

  @override
  State<V4ArtistDetailPage> createState() => _V4ArtistDetailPageState();
}

class _V4ArtistDetailPageState extends State<V4ArtistDetailPage> {
  late Future<_ArtistDetailData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_ArtistDetailData> _load() async {
    final values = await Future.wait<Object>([
      widget.controller.tracksForArtistSummary(widget.summary),
      widget.controller.albumsForArtistSummary(widget.summary),
    ]);
    final tracks = values[0] as List<LibraryTrack>;
    final albums = sortLibraryAlbums(
      browsableAlbums(values[1] as List<AlbumLibrarySummary>),
    );
    return _ArtistDetailData(
      tracks: tracks,
      albums: albums,
      standalone: standaloneTracks(tracks, albums),
    );
  }

  @override
  Widget build(BuildContext context) {
    return V4AppScaffold(
      key: const Key('v4-artist-detail-page'),
      bottomNavigationBar: _DetailMiniPlayer(controller: widget.controller),
      body: FutureBuilder<_ArtistDetailData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _LoadingDetail(title: widget.summary.artist.displayName);
          }
          if (snapshot.hasError) {
            return _DetailError(
              title: widget.summary.artist.displayName,
              error: snapshot.error,
              onRetry: () => setState(() => _future = _load()),
            );
          }
          final data = snapshot.data!;
          final tracks = sortLibraryTracks(
            data.tracks,
            LibraryBrowseSort.playCount,
          );
          return DefaultTabController(
            length: 2,
            initialIndex: 0,
            child: NestedScrollView(
              headerSliverBuilder: (context, innerScrolled) => [
                SliverAppBar(
                  pinned: true,
                  expandedHeight: 520,
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  foregroundColor: innerScrolled
                      ? Theme.of(context).colorScheme.onSurface
                      : Colors.white,
                  systemOverlayStyle: innerScrolled
                      ? (Theme.of(context).brightness == Brightness.dark
                            ? SystemUiOverlayStyle.light
                            : SystemUiOverlayStyle.dark)
                      : SystemUiOverlayStyle.light,
                  flexibleSpace: FlexibleSpaceBar(
                    collapseMode: CollapseMode.pin,
                    background: _ArtistHero(
                      summary: widget.summary,
                      onPlay: tracks.any((track) => track.isPlayable)
                          ? () => _playAndOpen(
                              context,
                              widget.controller,
                              tracks,
                              contextType: 'artist',
                              contextId: widget.summary.artist.artistId,
                            )
                          : null,
                      onShuffle: tracks.any((track) => track.isPlayable)
                          ? () => _shuffleAndOpen(
                              context,
                              widget.controller,
                              tracks,
                              contextType: 'artist',
                              contextId: widget.summary.artist.artistId,
                            )
                          : null,
                    ),
                  ),
                ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _DetailTabBarDelegate(
                    TabBar(
                      tabs: [
                        Tab(text: '歌曲 · ${tracks.length}'),
                        Tab(text: '专辑 · ${data.albums.length}'),
                      ],
                    ),
                  ),
                ),
              ],
              body: TabBarView(
                children: [
                  tracks.isEmpty
                      ? const _DetailEmpty(message: '这个歌手还没有可播放的歌曲')
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(
                            V4Space.page,
                            V4Space.sm,
                            V4Space.page,
                            V4Space.section,
                          ),
                          itemCount: tracks.length,
                          itemBuilder: (context, index) => V4LibraryTrackTile(
                            controller: widget.controller,
                            track: tracks[index],
                            playbackTracks: tracks,
                            contextType: 'artist',
                            contextId: widget.summary.artist.artistId,
                            onPlayed: () =>
                                _openPlayer(context, widget.controller),
                          ),
                        ),
                  data.albums.isEmpty
                      ? const _DetailEmpty(message: '这个歌手还没有专辑收藏')
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(
                            V4Space.page,
                            V4Space.sm,
                            V4Space.page,
                            V4Space.section,
                          ),
                          itemCount: data.albums.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: V4Space.xs),
                          itemBuilder: (context, index) => _ArtistAlbumRow(
                            controller: widget.controller,
                            album: data.albums[index],
                          ),
                        ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class V4AlbumDetailPage extends StatefulWidget {
  const V4AlbumDetailPage({
    required this.controller,
    required this.summary,
    super.key,
  });

  final AppController controller;
  final AlbumLibrarySummary summary;

  @override
  State<V4AlbumDetailPage> createState() => _V4AlbumDetailPageState();
}

class _V4AlbumDetailPageState extends State<V4AlbumDetailPage> {
  late Future<List<LibraryTrack>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.controller.tracksForAlbum(widget.summary.album.albumId);
  }

  @override
  Widget build(BuildContext context) {
    return V4AppScaffold(
      key: const Key('v4-album-detail-page'),
      bottomNavigationBar: _DetailMiniPlayer(controller: widget.controller),
      body: FutureBuilder<List<LibraryTrack>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _LoadingDetail(title: widget.summary.album.title);
          }
          if (snapshot.hasError) {
            return _DetailError(
              title: widget.summary.album.title,
              error: snapshot.error,
              onRetry: () => setState(
                () => _future = widget.controller.tracksForAlbum(
                  widget.summary.album.albumId,
                ),
              ),
            );
          }
          final tracks = sortAlbumTracks(snapshot.data ?? const []);
          final artist = tracks.isEmpty ? '未知歌手' : _albumArtist(tracks.first);
          final discs = _discGroups(tracks);
          final displayNumberByTrackId = <String, int>{
            for (var index = 0; index < tracks.length; index++)
              tracks[index].track.trackId: index + 1,
          };
          return CustomScrollView(
            slivers: [
              SliverAppBar(title: const Text('专辑')),
              SliverToBoxAdapter(
                child: _AlbumHero(
                  summary: widget.summary,
                  artist: artist,
                  tracks: tracks,
                  onPlay: tracks.any((track) => track.isPlayable)
                      ? () => _playAndOpen(
                          context,
                          widget.controller,
                          tracks,
                          contextType: 'album',
                          contextId: widget.summary.album.albumId,
                        )
                      : null,
                  onShuffle: tracks.any((track) => track.isPlayable)
                      ? () => _shuffleAndOpen(
                          context,
                          widget.controller,
                          tracks,
                          contextType: 'album',
                          contextId: widget.summary.album.albumId,
                        )
                      : null,
                ),
              ),
              if (tracks.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: _DetailEmpty(message: '这张专辑还没有可播放的歌曲'),
                )
              else
                for (final entry in discs.entries) ...[
                  if (discs.length > 1)
                    SliverToBoxAdapter(
                      child: _DiscHeader(discNumber: entry.key),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: V4Space.page,
                    ),
                    sliver: SliverList.builder(
                      itemCount: entry.value.length,
                      itemBuilder: (context, index) => _AlbumTrackTile(
                        controller: widget.controller,
                        track: entry.value[index],
                        displayNumber:
                            displayNumberByTrackId[entry
                                .value[index]
                                .track
                                .trackId]!,
                        playbackTracks: tracks,
                        albumId: widget.summary.album.albumId,
                      ),
                    ),
                  ),
                ],
              const SliverToBoxAdapter(
                child: SizedBox(height: V4Space.section),
              ),
            ],
          );
        },
      ),
    );
  }
}

class V4AlbumCard extends StatelessWidget {
  const V4AlbumCard({required this.controller, required this.album, super.key});

  final AppController controller;
  final AlbumLibrarySummary album;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(V4Radius.artwork),
      onTap: () => openV4Album(context, controller, album),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SizedBox.expand(
              child: V4Artwork(
                artwork: album.artwork,
                borderRadius: V4Radius.artwork,
                semanticLabel: '${album.album.title}的封面',
              ),
            ),
          ),
          const SizedBox(height: V4Space.xs),
          Text(
            album.album.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            _albumCardSubtitle(controller, album),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class V4LibraryTrackTile extends StatelessWidget {
  const V4LibraryTrackTile({
    required this.controller,
    required this.track,
    this.showAlbum = false,
    this.playbackTracks,
    this.contextType = 'library',
    this.contextId,
    this.onPlayed,
    super.key,
  });

  final AppController controller;
  final LibraryTrack track;
  final bool showAlbum;
  final List<LibraryTrack>? playbackTracks;
  final String contextType;
  final String? contextId;
  final VoidCallback? onPlayed;

  @override
  Widget build(BuildContext context) {
    final selected =
        controller.currentLibraryTrack?.track.trackId == track.track.trackId;
    final subtitle = showAlbum && track.track.albumDisplay.isNotEmpty
        ? '${track.track.artistDisplay} · ${track.track.albumDisplay}'
        : track.track.artistDisplay;
    return SizedBox(
      key: ValueKey('track-${track.track.trackId}'),
      height: 72,
      child: ListTile(
        selected: selected,
        selectedTileColor: Theme.of(context).colorScheme.primaryContainer
            .withValues(alpha: 0.35),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V4Radius.control),
        ),
        contentPadding: EdgeInsets.zero,
        minVerticalPadding: 0,
        leading: SizedBox(
          width: 64,
          child: Row(
            children: [
              SizedBox(
                width: 8,
                child: selected
                    ? Icon(
                        Icons.graphic_eq_rounded,
                        size: 12,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
              ),
              const SizedBox(width: 4),
              V4Artwork(
                artwork: track.artwork,
                size: V4Size.listArtwork,
                semanticLabel: '${track.track.title}的封面',
              ),
            ],
          ),
        ),
        title: Text(
          track.track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: IconButton(
          tooltip: track.preference.liked ? '取消喜欢' : '我喜欢',
          onPressed: () => controller.toggleTrackLiked(track),
          icon: Icon(
            track.preference.liked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            color: track.preference.liked
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
        ),
        enabled: track.isPlayable,
        onTap: track.isPlayable
            ? () async {
                final playback = controller.playTrackCollection(
                  playbackTracks ?? controller.libraryTracks,
                  contextType: contextType,
                  contextId: contextId,
                  startTrack: track,
                );
                onPlayed?.call();
                try {
                  await playback;
                } catch (_) {
                  controller.showMessage('无法播放这首歌，请检查音乐文件是否可用');
                }
              }
            : null,
        onLongPress: () {
          HapticFeedback.mediumImpact();
          _showTrackActions(context, controller, track);
        },
      ),
    );
  }
}

Future<void> openV4Artist(
  BuildContext context,
  AppController controller,
  ArtistLibrarySummary artist,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => V4ArtistDetailPage(controller: controller, summary: artist),
  ),
);

Future<void> openV4Album(
  BuildContext context,
  AppController controller,
  AlbumLibrarySummary album,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => V4AlbumDetailPage(controller: controller, summary: album),
  ),
);

class _ArtistHero extends StatelessWidget {
  const _ArtistHero({
    required this.summary,
    required this.onPlay,
    required this.onShuffle,
  });

  final ArtistLibrarySummary summary;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    return Stack(
      fit: StackFit.expand,
      children: [
        V4Artwork(
          artwork: summary.artwork,
          borderRadius: 0,
          alignment: Alignment.topCenter,
          semanticLabel: '${summary.artist.displayName}的歌手封面',
          fallbackSeed: summary.artist.artistId,
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0, 0.30, 0.68, 0.88, 1],
              colors: [
                Colors.black.withValues(alpha: 0.34),
                Colors.transparent,
                Colors.transparent,
                surface.withValues(alpha: 0.90),
                surface,
              ],
            ),
          ),
        ),
        Positioned(
          left: V4Space.page,
          right: V4Space.page,
          bottom: V4Space.section,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onPlay,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('播放全部'),
                    ),
                  ),
                  const SizedBox(width: V4Space.sm),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: onShuffle,
                      icon: const Icon(Icons.shuffle_rounded),
                      label: const Text('随机播放'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ArtistAlbumRow extends StatelessWidget {
  const _ArtistAlbumRow({required this.controller, required this.album});

  final AppController controller;
  final AlbumLibrarySummary album;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: V4Artwork(
      artwork: album.artwork,
      size: 64,
      semanticLabel: '${album.album.title}的封面',
    ),
    title: Text(
      album.album.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleSmall,
    ),
    subtitle: Text(
      [
        if (album.album.year != null) '${album.album.year}',
        '${album.trackCount} 首',
      ].join(' · '),
    ),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: () => openV4Album(context, controller, album),
  );
}

class _DetailTabBarDelegate extends SliverPersistentHeaderDelegate {
  const _DetailTabBarDelegate(this.tabBar);

  final TabBar tabBar;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Material(
    color: Theme.of(context).colorScheme.surface,
    elevation: overlapsContent ? 1 : 0,
    child: tabBar,
  );

  @override
  bool shouldRebuild(covariant _DetailTabBarDelegate oldDelegate) =>
      oldDelegate.tabBar != tabBar;
}

class _AlbumHero extends StatelessWidget {
  const _AlbumHero({
    required this.summary,
    required this.artist,
    required this.tracks,
    required this.onPlay,
    required this.onShuffle,
  });

  final AlbumLibrarySummary summary;
  final String artist;
  final List<LibraryTrack> tracks;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;

  @override
  Widget build(BuildContext context) {
    final year = summary.album.year;
    return V4ArtworkTintBuilder(
      artwork: summary.artwork,
      fallbackSeed: summary.album.albumId,
      builder: (context, primary) {
        final surface = Theme.of(context).colorScheme.surface;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.lerp(surface, primary, 0.42)!,
                Color.lerp(surface, primary, 0.14)!,
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              V4Space.page,
              V4Space.sm,
              V4Space.page,
              V4Space.section,
            ),
            child: Column(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 248),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: V4Artwork(
                      artwork: summary.artwork,
                      borderRadius: V4Radius.hero,
                      semanticLabel: '${summary.album.title}的封面',
                    ),
                  ),
                ),
                const SizedBox(height: V4Space.lg),
                Text(
                  summary.album.title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: V4Space.xs),
                Text(
                  artist,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.primary),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if (year != null) '$year',
                    _albumTypeLabel(summary.album.albumType),
                    '${tracks.length} 首',
                    _durationLabel(tracks),
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: V4Space.md),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onPlay,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('播放全部'),
                      ),
                    ),
                    const SizedBox(width: V4Space.sm),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: onShuffle,
                        icon: const Icon(Icons.shuffle_rounded),
                        label: const Text('随机播放'),
                      ),
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
}

class _AlbumTrackTile extends StatelessWidget {
  const _AlbumTrackTile({
    required this.controller,
    required this.track,
    required this.displayNumber,
    required this.playbackTracks,
    required this.albumId,
  });

  final AppController controller;
  final LibraryTrack track;
  final int displayNumber;
  final List<LibraryTrack> playbackTracks;
  final String albumId;

  @override
  Widget build(BuildContext context) {
    final selected =
        controller.currentLibraryTrack?.track.trackId == track.track.trackId;
    return ListTile(
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer
          .withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(V4Radius.control),
      ),
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 36,
        child: Center(
          child: selected && controller.isPlaying
              ? Icon(
                  Icons.graphic_eq_rounded,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                )
              : Text(
                  displayNumber.toString(),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
        ),
      ),
      title: Text(
        track.track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      subtitle: Text(
        track.track.artistDisplay,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: track.preference.liked ? '取消喜欢' : '我喜欢',
        onPressed: () => controller.toggleTrackLiked(track),
        icon: Icon(
          track.preference.liked
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          color: track.preference.liked
              ? Theme.of(context).colorScheme.primary
              : null,
        ),
      ),
      enabled: track.isPlayable,
      onTap: track.isPlayable
          ? () async {
              final playback = controller.playTrackCollection(
                playbackTracks,
                contextType: 'album',
                contextId: albumId,
                startTrack: track,
              );
              if (context.mounted) _openPlayer(context, controller);
              await playback;
            }
          : null,
      onLongPress: () {
        HapticFeedback.mediumImpact();
        _showTrackActions(context, controller, track);
      },
    );
  }
}

class _DiscHeader extends StatelessWidget {
  const _DiscHeader({required this.discNumber});

  final int discNumber;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      V4Space.page,
      V4Space.sm,
      V4Space.page,
      V4Space.xs,
    ),
    child: Text(
      'DISC $discNumber',
      style: Theme.of(context).textTheme.labelMedium,
    ),
  );
}

class _LoadingDetail extends StatelessWidget {
  const _LoadingDetail({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      SliverAppBar(title: Text(title)),
      const SliverFillRemaining(child: V4LoadingState()),
    ],
  );
}

class _DetailError extends StatelessWidget {
  const _DetailError({
    required this.title,
    required this.error,
    required this.onRetry,
  });

  final String title;
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      SliverAppBar(title: Text(title)),
      SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(V4Space.page),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded, size: 42),
                const SizedBox(height: V4Space.sm),
                const Text('暂时无法打开'),
                const SizedBox(height: V4Space.xs),
                Text('$error', textAlign: TextAlign.center),
                const SizedBox(height: V4Space.md),
                OutlinedButton(onPressed: onRetry, child: const Text('重试')),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

class _DetailEmpty extends StatelessWidget {
  const _DetailEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(V4Space.page),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyLarge
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

class _ArtistDetailData {
  const _ArtistDetailData({
    required this.tracks,
    required this.albums,
    required this.standalone,
  });

  final List<LibraryTrack> tracks;
  final List<AlbumLibrarySummary> albums;
  final List<LibraryTrack> standalone;
}

Future<void> _playAndOpen(
  BuildContext context,
  AppController controller,
  List<LibraryTrack> tracks, {
  required String contextType,
  String? contextId,
}) async {
  final playback = controller.playTrackCollection(
    tracks,
    contextType: contextType,
    contextId: contextId,
  );
  if (context.mounted) _openPlayer(context, controller);
  await playback;
}

Future<void> _shuffleAndOpen(
  BuildContext context,
  AppController controller,
  List<LibraryTrack> tracks, {
  required String contextType,
  String? contextId,
}) async {
  final shuffled = tracks.where((track) => track.isPlayable).toList()
    ..shuffle();
  if (shuffled.isEmpty) return;
  final playback = controller.playTrackCollection(
    shuffled,
    contextType: contextType,
    contextId: contextId,
  );
  if (context.mounted) _openPlayer(context, controller);
  await playback;
}

class _DetailMiniPlayer extends StatelessWidget {
  const _DetailMiniPlayer({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => controller.currentSong == null
        ? const SizedBox.shrink()
        : SafeArea(
            top: false,
            child: V4MiniPlayer(
              controller: controller,
              onTap: () => _openPlayer(context, controller),
            ),
          ),
  );
}

void _openPlayer(BuildContext context, AppController controller) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => V4PlayerPage(controller: controller),
    ),
  );
}

String _durationLabel(List<LibraryTrack> tracks) {
  final totalMinutes =
      tracks.fold<int>(0, (sum, track) => sum + track.track.durationMs) ~/
      Duration.millisecondsPerMinute;
  return '$totalMinutes 分钟';
}

Map<int, List<LibraryTrack>> _discGroups(List<LibraryTrack> tracks) {
  final groups = <int, List<LibraryTrack>>{};
  for (final track in tracks) {
    groups.putIfAbsent(track.track.discNumber ?? 1, () => []).add(track);
  }
  return groups;
}

String _albumArtist(LibraryTrack track) {
  final value = track.track.albumArtistDisplay.trim();
  return value.isEmpty ? track.track.artistDisplay : value;
}

String _albumCardSubtitle(AppController controller, AlbumLibrarySummary album) {
  final matchingTracks = controller.libraryTracks.where(
    (track) => track.track.albumId == album.album.albumId,
  );
  var artist = '';
  for (final track in matchingTracks) {
    artist = _albumArtist(track).trim();
    if (artist.isNotEmpty && artist != '未知歌手') break;
  }
  final parts = <String>[
    if (artist.isNotEmpty) artist,
    if (album.album.year != null) '${album.album.year}',
  ];
  return parts.isEmpty ? '${album.trackCount} 首' : parts.join(' · ');
}

String _albumTypeLabel(String value) => switch (value) {
  'studio' => '专辑',
  'ep' => 'EP',
  'single' => '单曲',
  'live' => '现场',
  'compilation' => '合集',
  _ => '专辑收藏',
};

Future<void> _showTrackActions(
  BuildContext context,
  AppController controller,
  LibraryTrack track, {
  bool playlistOnly = false,
}) async {
  var playlistIds = await controller.playlistIdsForTrack(track.track.trackId);
  if (!context.mounted || ModalRoute.of(context)?.isCurrent != true) return;
  var liked = track.preference.liked;
  var manualOnly = track.preference.recommendationExcluded;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.82,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  V4Space.page,
                  0,
                  V4Space.sm,
                  V4Space.sm,
                ),
                child: Row(
                  children: [
                    V4Artwork(
                      artwork: track.artwork,
                      size: 58,
                      semanticLabel: '${track.track.title}的封面',
                    ),
                    const SizedBox(width: V4Space.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            [
                              track.track.artistDisplay,
                              if (track.track.albumDisplay.isNotEmpty)
                                track.track.albumDisplay,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: liked ? '取消喜欢' : '我喜欢',
                      onPressed: () async {
                        await controller.toggleTrackLiked(track);
                        if (!sheetContext.mounted) return;
                        liked = !liked;
                        setSheetState(() {});
                        controller.showMessage(
                          liked ? '已加入「我喜欢」' : '已从「我喜欢」移除',
                        );
                      },
                      icon: Icon(
                        liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        color: liked
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (!playlistOnly) ...[
                ListTile(
                  leading: const Icon(Icons.playlist_play_rounded),
                  title: const Text('下一首播放'),
                  enabled: track.isPlayable,
                  onTap: track.isPlayable
                      ? () async {
                          await controller.playNext(track);
                          if (!sheetContext.mounted) return;
                          Navigator.pop(sheetContext);
                          controller.showMessage('已设为下一首播放');
                        }
                      : null,
                ),
                ListTile(
                  leading: const Icon(Icons.queue_music_rounded),
                  title: const Text('添加到队列'),
                  enabled: track.isPlayable,
                  onTap: track.isPlayable
                      ? () async {
                          await controller.addToQueue(track);
                          if (!sheetContext.mounted) return;
                          Navigator.pop(sheetContext);
                          controller.showMessage('已添加到播放队列');
                        }
                      : null,
                ),
                ListTile(
                  leading: Icon(
                    manualOnly
                        ? Icons.auto_awesome_rounded
                        : Icons.touch_app_rounded,
                  ),
                  title: Text(manualOnly ? '恢复智能播放' : '设为仅手动播放'),
                  subtitle: const Text('歌曲仍保留，可随时手动播放'),
                  onTap: () async {
                    await controller.setTrackManualOnly(track, !manualOnly);
                    manualOnly = !manualOnly;
                    if (!sheetContext.mounted) return;
                    Navigator.pop(sheetContext);
                  },
                ),
                const Divider(height: 1),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  V4Space.page,
                  V4Space.md,
                  V4Space.page,
                  V4Space.xs,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '加入歌单',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.add_rounded),
                      title: const Text('新建歌单'),
                      onTap: () async {
                        final created = await showV4CreatePlaylist(
                          context,
                          controller,
                          track: track,
                        );
                        if (!created || !sheetContext.mounted) return;
                        playlistIds = await controller.playlistIdsForTrack(
                          track.track.trackId,
                        );
                        if (!sheetContext.mounted) return;
                        setSheetState(() {});
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.favorite_rounded),
                      title: const Text('我喜欢'),
                      trailing: Icon(
                        liked ? Icons.check_rounded : Icons.add_rounded,
                      ),
                      onTap: () async {
                        await controller.toggleTrackLiked(track);
                        if (!sheetContext.mounted) return;
                        liked = !liked;
                        setSheetState(() {});
                        controller.showMessage(
                          liked ? '已加入「我喜欢」' : '已从「我喜欢」移除',
                        );
                      },
                    ),
                    for (final summary in controller.playlistSummaries.where(
                      (summary) => summary.playlist.type == 'user',
                    ))
                      ListTile(
                        leading: const Icon(Icons.queue_music_rounded),
                        title: Text(summary.playlist.name),
                        subtitle: Text('${summary.trackCount} 首歌曲'),
                        trailing: Icon(
                          playlistIds.contains(summary.playlist.playlistId)
                              ? Icons.check_rounded
                              : Icons.add_rounded,
                        ),
                        onTap: () async {
                          final id = summary.playlist.playlistId;
                          final included = playlistIds.contains(id);
                          await controller.setTrackPlaylistMembership(
                            id,
                            track,
                            !included,
                          );
                          if (!sheetContext.mounted) return;
                          playlistIds = {...playlistIds};
                          if (included) {
                            playlistIds.remove(id);
                          } else {
                            playlistIds.add(id);
                          }
                          setSheetState(() {});
                          controller.showMessage(
                            included
                                ? '已移除「${summary.playlist.name}」'
                                : '已加入「${summary.playlist.name}」',
                          );
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> showV4PlaylistPicker(
  BuildContext context,
  AppController controller,
) async {
  final track = controller.currentLibraryTrack;
  if (track != null) {
    await _showTrackActions(context, controller, track, playlistOnly: true);
  }
}

Future<bool> showV4CreatePlaylist(
  BuildContext context,
  AppController controller, {
  LibraryTrack? track,
}) async {
  var name = '';
  String? coverPath;
  var picking = false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('新建歌单'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              autofocus: true,
              maxLength: 40,
              onChanged: (value) => name = value.trim(),
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(hintText: '歌单名称'),
              onSubmitted: (value) {
                name = value.trim();
                if (name.isNotEmpty && !picking) {
                  Navigator.pop(dialogContext, true);
                }
              },
            ),
            const SizedBox(height: V4Space.sm),
            if (coverPath != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(V4Radius.artwork),
                child: Image.file(
                  File(coverPath!),
                  width: 96,
                  height: 96,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.broken_image_outlined, size: 64),
                ),
              ),
            TextButton.icon(
              onPressed: picking
                  ? null
                  : () async {
                      setDialogState(() => picking = true);
                      try {
                        final result = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
                        );
                        if (!dialogContext.mounted) return;
                        final path = result?.files.single.path;
                        if (path != null) {
                          if (await File(path).length() > 20 * 1024 * 1024) {
                            controller.showMessage('封面图片不能超过20MB');
                          } else {
                            final codec = await ui.instantiateImageCodec(
                              await File(path).readAsBytes(),
                            );
                            codec.dispose();
                            if (dialogContext.mounted) {
                              setDialogState(() => coverPath = path);
                            }
                          }
                        }
                      } catch (_) {
                        controller.showMessage(
                          '无法读取这张图片，请选择有效的 JPG、PNG 或 WebP 图片',
                        );
                      } finally {
                        if (dialogContext.mounted) {
                          setDialogState(() => picking = false);
                        }
                      }
                    },
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: Text(coverPath == null ? '选择封面（可选）' : '更换封面'),
            ),
            if (coverPath != null)
              TextButton(
                onPressed: () => setDialogState(() => coverPath = null),
                child: const Text('使用默认封面'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: picking
                ? null
                : () {
                    if (name.isNotEmpty) Navigator.pop(dialogContext, true);
                  },
            child: const Text('创建'),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true) return false;
  try {
    if (track == null) {
      await controller.createPlaylist(name, coverPath: coverPath);
      controller.showMessage('已创建歌单「$name」');
    } else {
      await controller.createPlaylistWithTrack(
        name,
        track,
        coverPath: coverPath,
      );
    }
    return true;
  } catch (error) {
    controller.showMessage('创建歌单失败：$error');
    return false;
  }
}
