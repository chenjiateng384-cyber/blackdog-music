import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/v4/artwork.dart';
import '../models/v4/library_browsing.dart';
import '../models/v4/library_search.dart';
import '../models/v4/library_track.dart';
import '../models/v4/music_archive.dart';
import 'components/v4_foundation.dart';
import 'components/v4_mini_player.dart';
import 'v4_artwork.dart';
import 'v4_design_system.dart';
import 'v4_library_detail_pages.dart';
import 'v4_player_page.dart';

class V4HomePage extends StatelessWidget {
  const V4HomePage({
    required this.controller,
    required this.onOpenLibrary,
    required this.onOpenPlaylists,
    required this.onOpenSearch,
    required this.onOpenPlayer,
    super.key,
  });

  final AppController controller;
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenPlaylists;
  final VoidCallback onOpenSearch;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final greeting = _greeting(DateTime.now().hour);
    final experience = controller.homeExperience;
    return RefreshIndicator(
      onRefresh: controller.refreshHomeRecommendations,
      child: CustomScrollView(
        key: const Key('v4-home-page'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _HomeHeader(greeting: greeting, onSearch: onOpenSearch),
          ),
          if (controller.experienceLoading)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              V4Space.page,
              V4Space.xs,
              V4Space.page,
              116,
            ),
            sliver: SliverList.list(
              children: [
                _QuickStartCard(
                  tracks: experience.quickStartTracks,
                  subtitle: controller.libraryTracks.isEmpty
                      ? '先到“我的”选择主音乐目录'
                      : experience.quickStartTracks.isEmpty
                      ? '暂无可自动播放的歌曲，可到音乐库点播'
                      : '从喜欢、常听和最近播放中开始',
                  onPlay: experience.quickStartTracks.isEmpty
                      ? null
                      : () {
                          final playback = controller.playHomeCollection(
                            experience.quickStartTracks,
                            contextType: 'home_quick_start',
                          );
                          // Opening the player must not wait for SAF/codec I/O.
                          // The controller publishes the selected track
                          // synchronously before the audio source is loaded.
                          onOpenPlayer();
                          unawaited(
                            playback.catchError((Object error) {
                              controller.showMessage('播放失败：$error');
                            }),
                          );
                        },
                ),
                const SizedBox(height: V4Space.section),
                _SmartPlayPager(
                  controller: controller,
                  tracks: controller.homePlayCountTracks,
                  onOpenPlayer: onOpenPlayer,
                ),
                const SizedBox(height: V4Space.section),
                V4SectionHeader(
                  title: '我的歌单',
                  actionLabel: '全部',
                  onAction: onOpenPlaylists,
                ),
                const SizedBox(height: V4Space.sm),
                _HomePlaylistSection(
                  controller: controller,
                  onOpenPlaylists: onOpenPlaylists,
                  onOpenPlayer: onOpenPlayer,
                ),
                const SizedBox(height: V4Space.section),
                _HomeMoreEntry(
                  onTap: () =>
                      _showHomeMoreSheet(context, controller, onOpenPlayer),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class V4LibraryPage extends StatefulWidget {
  const V4LibraryPage({
    required this.controller,
    required this.onOpenSearch,
    required this.onOpenPlayer,
    super.key,
  });

  final AppController controller;
  final VoidCallback onOpenSearch;
  final VoidCallback onOpenPlayer;

  @override
  State<V4LibraryPage> createState() => _V4LibraryPageState();
}

class _V4LibraryPageState extends State<V4LibraryPage> {
  List<ArtistLibrarySummary>? _artistSource;
  List<AlbumLibrarySummary>? _albumSource;
  List<LibraryTrack>? _albumTrackSource;
  List<ArtistLibrarySummary> _sortedArtists = const [];
  List<AlbumLibrarySummary> _sortedAlbums = const [];

  void _refreshDerivedLists() {
    final artists = widget.controller.artistSummaries;
    if (!identical(_artistSource, artists)) {
      _artistSource = artists;
      _sortedArtists = sortLibraryArtists(artists);
    }
    final albums = widget.controller.albumSummaries;
    final tracks = widget.controller.libraryTracks;
    if (!identical(_albumSource, albums) ||
        !identical(_albumTrackSource, tracks)) {
      _albumSource = albums;
      _albumTrackSource = tracks;
      _sortedAlbums = sortLibraryAlbumsByListening(
        browsableAlbums(albums),
        tracks,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    _refreshDerivedLists();
    return DefaultTabController(
      length: 4,
      child: Column(
        key: const Key('v4-library-page'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          V4PageHeader(
            title: '音乐库',
            subtitle: '按你原来的目录和专辑结构浏览',
            compact: true,
            action: IconButton(
              key: const Key('library-search-shortcut'),
              tooltip: '搜索音乐库',
              onPressed: widget.onOpenSearch,
              icon: const Icon(Icons.search_rounded),
            ),
          ),
          TabBar(
            indicator: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            indicatorPadding: const EdgeInsets.symmetric(
              horizontal: 6,
              vertical: 5,
            ),
            dividerColor: Colors.transparent,
            tabs: [
              Tab(text: '歌曲'),
              Tab(text: '歌手'),
              Tab(text: '专辑'),
              Tab(text: '文件夹'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _SongLibraryView(
                  controller: widget.controller,
                  tracks: widget.controller.libraryTracks,
                  onOpenPlayer: widget.onOpenPlayer,
                ),
                _ArtistList(
                  controller: widget.controller,
                  artists: _sortedArtists,
                ),
                _AlbumGrid(
                  controller: widget.controller,
                  albums: _sortedAlbums,
                ),
                _FolderList(
                  controller: widget.controller,
                  folders: widget.controller.libraryFolders,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class V4PlaylistsPage extends StatelessWidget {
  const V4PlaylistsPage({
    required this.controller,
    required this.onOpenPlayer,
    super.key,
  });

  final AppController controller;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final playlists = controller.playlistSummaries;
    final manualOnly = playlists
        .where(
          (summary) =>
              summary.playlist.playlistId == controller.manualOnlyPlaylistId,
        )
        .firstOrNull;
    final userPlaylists = playlists
        .where(
          (summary) =>
              summary.playlist.playlistId != controller.manualOnlyPlaylistId,
        )
        .toList(growable: false);
    return Column(
      key: const Key('v4-playlists-page'),
      children: [
        V4PageHeader(
          title: '歌单',
          subtitle: '把同一首歌放进不同场景',
          action: IconButton.filledTonal(
            tooltip: '新建歌单',
            onPressed: () => _createPlaylist(context, controller),
            icon: const Icon(Icons.add_rounded),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              V4Space.page,
              V4Space.xs,
              V4Space.page,
              V4Space.section,
            ),
            children: [
              _LikedPlaylistCard(
                tracks: controller.likedTracks,
                trackCount: controller.libraryCounts.likedCount,
                onTap: () => _openCollection(
                  context,
                  controller,
                  '我喜欢',
                  controller.allLikedTracks(),
                  contextType: 'playlist',
                  contextId: 'liked',
                  onOpenPlayer: onOpenPlayer,
                ),
                onPlay: () async {
                  final tracks = await controller.allLikedTracks();
                  if (!context.mounted || tracks.isEmpty) return;
                  final playback = controller.playTrackCollection(
                    tracks,
                    contextType: 'playlist',
                    contextId: 'liked',
                  );
                  onOpenPlayer();
                  try {
                    await playback;
                  } catch (_) {
                    controller.showMessage('无法播放这首歌，请检查音乐文件是否可用');
                  }
                },
              ),
              if (manualOnly != null) ...[
                const SizedBox(height: V4Space.md),
                _ManualOnlyPlaylistCard(
                  trackCount: manualOnly.trackCount,
                  onTap: () => _openCollection(
                    context,
                    controller,
                    manualOnly.playlist.name,
                    controller.tracksForPlaylist(
                      manualOnly.playlist.playlistId,
                    ),
                    contextType: 'playlist',
                    contextId: manualOnly.playlist.playlistId,
                    onOpenPlayer: onOpenPlayer,
                  ),
                ),
              ],
              const SizedBox(height: V4Space.section),
              V4SectionHeader(
                title: '我的歌单',
                subtitle: '${userPlaylists.length} 个',
                actionLabel: '新建',
                onAction: () => _createPlaylist(context, controller),
              ),
              const SizedBox(height: V4Space.md),
              if (userPlaylists.isNotEmpty)
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: userPlaylists.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: V4Space.page,
                    crossAxisSpacing: V4Space.md,
                    childAspectRatio: 0.78,
                  ),
                  itemBuilder: (context, index) {
                    final summary = userPlaylists[index];
                    return _PlaylistCard(
                      summary: summary,
                      cover: controller
                          .playlistCovers[summary.playlist.playlistId],
                      tracks: controller.tracksForPlaylist(
                        summary.playlist.playlistId,
                      ),
                      onTap: () => _openCollection(
                        context,
                        controller,
                        summary.playlist.name,
                        controller.tracksForPlaylist(
                          summary.playlist.playlistId,
                        ),
                        contextType: 'playlist',
                        contextId: summary.playlist.playlistId,
                        onOpenPlayer: onOpenPlayer,
                      ),
                      onPlay: () async {
                        final tracks = await controller.tracksForPlaylist(
                          summary.playlist.playlistId,
                        );
                        if (!context.mounted || tracks.isEmpty) return;
                        final playback = controller.playTrackCollection(
                          tracks,
                          contextType: 'playlist',
                          contextId: summary.playlist.playlistId,
                        );
                        onOpenPlayer();
                        try {
                          await playback;
                        } catch (_) {
                          controller.showMessage('无法播放这首歌，请检查音乐文件是否可用');
                        }
                      },
                      onDelete: summary.playlist.type == 'system'
                          ? null
                          : () => _deletePlaylist(context, controller, summary),
                    );
                  },
                ),
              if (userPlaylists.isEmpty) ...[
                _PlaylistEmptyPrompt(
                  onCreate: () => _createPlaylist(context, controller),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ManualOnlyPlaylistCard extends StatelessWidget {
  const _ManualOnlyPlaylistCard({
    required this.trackCount,
    required this.onTap,
  });

  final int trackCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const Key('manual-only-playlist-card'),
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(V4Radius.card),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minTileHeight: 72,
        onTap: onTap,
        leading: Icon(Icons.touch_app_rounded, color: colors.primary),
        title: const Text(
          '仅手动播放',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text('$trackCount 首 · 不参与随心听与智能播放'),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}

class _LikedPlaylistCard extends StatelessWidget {
  const _LikedPlaylistCard({
    required this.tracks,
    required this.trackCount,
    required this.onTap,
    required this.onPlay,
  });

  final List<LibraryTrack> tracks;
  final int trackCount;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const Key('liked-playlist-card'),
      color: colors.primaryContainer.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(V4Radius.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(V4Space.md),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 88,
                child: _ArtworkMosaic(tracks: tracks),
              ),
              const SizedBox(width: V4Space.md),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.favorite_rounded, color: colors.primary),
                    const SizedBox(height: V4Space.xs),
                    Text(
                      '我喜欢',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: V4Space.xxs),
                    Text(
                      '$trackCount 首歌曲',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton.filled(
                key: const Key('liked-playlist-play'),
                tooltip: '播放我喜欢',
                onPressed: onPlay,
                icon: const Icon(Icons.play_arrow_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({
    required this.summary,
    this.cover,
    required this.tracks,
    required this.onTap,
    required this.onPlay,
    required this.onDelete,
  });

  final PlaylistLibrarySummary summary;
  final ArtworkReference? cover;
  final Future<List<LibraryTrack>> tracks;
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(V4Radius.artwork),
    onTap: onTap,
    onLongPress: onDelete,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (cover != null)
                V4Artwork(
                  artwork: cover,
                  semanticLabel: '${summary.playlist.name}的封面',
                )
              else
                FutureBuilder<List<LibraryTrack>>(
                  future: tracks,
                  builder: (context, snapshot) =>
                      _ArtworkMosaic(tracks: snapshot.data ?? const []),
                ),
              Positioned(
                bottom: V4Space.xs,
                right: V4Space.xs,
                child: IconButton.filled(
                  tooltip: '播放歌单',
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: V4Space.xs),
        Text(
          summary.playlist.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(
          summary.playlist.type == 'system'
              ? '${summary.trackCount} 首 · 不参与随心听与智能播放'
              : '${summary.trackCount} 首歌曲',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    ),
  );
}

class _PlaylistEmptyPrompt extends StatelessWidget {
  const _PlaylistEmptyPrompt({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const Key('playlist-empty-prompt'),
      width: double.infinity,
      padding: const EdgeInsets.all(V4Space.page),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(V4Radius.card),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.library_add_rounded, color: colors.primary, size: 30),
          const SizedBox(height: V4Space.sm),
          Text('建立自己的歌单', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: V4Space.xs),
          Text(
            '把健身、骑行或夜晚想听的歌曲整理在一起。',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: V4Space.md),
          FilledButton.icon(
            key: const Key('playlist-empty-create'),
            onPressed: onCreate,
            icon: const Icon(Icons.add_rounded),
            label: const Text('创建歌单'),
          ),
        ],
      ),
    );
  }
}

class V4SearchPage extends StatefulWidget {
  const V4SearchPage({
    required this.controller,
    this.active = false,
    this.onClose,
    required this.onOpenPlayer,
    super.key,
  });

  final AppController controller;
  final bool active;
  final VoidCallback? onClose;
  final VoidCallback onOpenPlayer;

  @override
  State<V4SearchPage> createState() => _V4SearchPageState();
}

class _V4SearchPageState extends State<V4SearchPage> {
  late final TextEditingController _textController;
  late final FocusNode _focusNode;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(
      text: widget.controller.searchResults.query,
    );
    _focusNode = FocusNode();
    if (widget.active) _requestSearchFocus();
  }

  @override
  void didUpdateWidget(covariant V4SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _requestSearchFocus();
    } else if (!widget.active && oldWidget.active) {
      _focusNode.unfocus();
    }
  }

  void _requestSearchFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _focusNode.requestFocus();
    });
  }

  void _queryChanged(String value) {
    setState(() {});
    _searchDebounce?.cancel();
    if (value.trim().isEmpty) {
      widget.controller.searchLibrary('');
      return;
    }
    _searchDebounce = Timer(
      const Duration(milliseconds: 240),
      () => widget.controller.searchLibrary(value),
    );
  }

  void _submitQuery(String value) {
    _searchDebounce?.cancel();
    widget.controller.searchLibrary(value);
  }

  void _clearQuery() {
    _searchDebounce?.cancel();
    _textController.clear();
    widget.controller.searchLibrary('');
    setState(() {});
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _focusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = widget.controller.searchResults;
    final typedQuery = _textController.text.trim();
    final waitingForQuery =
        typedQuery.isNotEmpty && results.query != typedQuery;
    return Column(
      key: const Key('v4-search-page'),
      children: [
        V4PageHeader(
          title: '搜索',
          subtitle: '只查找你的本地音乐收藏',
          compact: true,
          leading: widget.onClose == null
              ? null
              : IconButton(
                  key: const Key('search-back'),
                  tooltip: '返回首页',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            V4Space.page,
            0,
            V4Space.page,
            V4Space.sm,
          ),
          child: TextField(
            key: const Key('v4-search-field'),
            controller: _textController,
            focusNode: _focusNode,
            textInputAction: TextInputAction.search,
            onChanged: _queryChanged,
            onSubmitted: _submitQuery,
            onTapOutside: (_) => _focusNode.unfocus(),
            decoration: InputDecoration(
              hintText: '搜索歌曲、歌手、专辑或文件夹',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _textController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      onPressed: _clearQuery,
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
        ),
        if (widget.controller.searchLoading)
          const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: typedQuery.isEmpty
              ? _SearchLanding(controller: widget.controller)
              : waitingForQuery
              ? const Center(child: CircularProgressIndicator())
              : widget.controller.searchError != null
              ? V4EmptyState(
                  icon: Icons.sync_problem_rounded,
                  title: '暂时无法搜索',
                  message: widget.controller.searchError!,
                  action: FilledButton.tonalIcon(
                    onPressed: () => _submitQuery(typedQuery),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试'),
                  ),
                )
              : results.ordered.isEmpty
              ? V4EmptyState(
                  icon: Icons.search_off_rounded,
                  title: '没有找到“$typedQuery”',
                  message: '请检查名称，或只输入歌名、主要歌手、专辑或文件夹关键词。黑狗音乐只搜索本地音乐。',
                )
              : _GroupedSearchResults(
                  controller: widget.controller,
                  results: results,
                  onOpenPlayer: widget.onOpenPlayer,
                ),
        ),
      ],
    );
  }
}

class _SearchLanding extends StatelessWidget {
  const _SearchLanding({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final albums = browsableAlbums(controller.albumSummaries).length;
    return ListView(
      key: const Key('search-scope-overview'),
      padding: const EdgeInsets.fromLTRB(
        V4Space.page,
        V4Space.md,
        V4Space.page,
        V4Space.section,
      ),
      children: [
        Text('搜索你的音乐库', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: V4Space.xs),
        Text(
          '输入名称即可同时查找歌曲、歌手、专辑和真实文件夹。',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: V4Space.lg),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          mainAxisSpacing: V4Space.sm,
          crossAxisSpacing: V4Space.sm,
          childAspectRatio: 2.25,
          children: [
            _SearchScopeTile(
              icon: Icons.music_note_rounded,
              label: '歌曲',
              count: controller.libraryCounts.trackCount,
            ),
            _SearchScopeTile(
              icon: Icons.person_rounded,
              label: '歌手',
              count: controller.artistSummaries.length,
            ),
            _SearchScopeTile(
              icon: Icons.album_rounded,
              label: '专辑',
              count: albums,
            ),
            _SearchScopeTile(
              icon: Icons.folder_rounded,
              label: '文件夹',
              count: controller.libraryFolders.length,
            ),
          ],
        ),
      ],
    );
  }
}

class _SearchScopeTile extends StatelessWidget {
  const _SearchScopeTile({
    required this.icon,
    required this.label,
    required this.count,
  });

  final IconData icon;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(V4Radius.card),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.32),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: V4Space.md),
        child: Row(
          children: [
            Icon(icon, color: colors.primary),
            const SizedBox(width: V4Space.sm),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '$count 项',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupedSearchResults extends StatelessWidget {
  const _GroupedSearchResults({
    required this.controller,
    required this.results,
    required this.onOpenPlayer,
  });

  final AppController controller;
  final LibrarySearchResults results;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final groups = <(String, LibrarySearchResultType)>[
      ('歌曲', LibrarySearchResultType.track),
      ('歌手', LibrarySearchResultType.artist),
      ('专辑', LibrarySearchResultType.album),
      ('文件夹', LibrarySearchResultType.folder),
    ];
    return ListView(
      key: const Key('grouped-search-results'),
      padding: const EdgeInsets.fromLTRB(
        V4Space.page,
        V4Space.sm,
        V4Space.page,
        V4Space.section,
      ),
      children: [
        for (final group in groups) ...[
          if (results.ordered.any((result) => result.type == group.$2)) ...[
            V4SectionHeader(
              title: group.$1,
              subtitle:
                  '${results.ordered.where((result) => result.type == group.$2).length} 项',
            ),
            const SizedBox(height: V4Space.xs),
            for (final result in results.ordered.where(
              (result) => result.type == group.$2,
            ))
              _SearchResultTile(
                controller: controller,
                result: result,
                onOpenPlayer: onOpenPlayer,
              ),
            const SizedBox(height: V4Space.lg),
          ],
        ],
      ],
    );
  }
}

class V4ProfilePage extends StatelessWidget {
  const V4ProfilePage({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      key: const Key('v4-profile-page'),
      slivers: [
        const SliverAppBar(title: Text('我的')),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            V4Space.page,
            0,
            V4Space.page,
            V4Space.section,
          ),
          sliver: SliverList.list(
            children: [
              Text(
                '我的音乐档案',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: V4Space.sm),
              _MusicArchiveContent(archive: controller.musicArchive),
              if (controller.backupReminderDue) ...[
                const SizedBox(height: V4Space.section),
                _BackupReminder(controller: controller),
              ],
              const SizedBox(height: V4Space.section),
              const V4SectionHeader(title: '音乐管理'),
              const SizedBox(height: 10),
              _SettingsPanel(
                children: [
                  _SettingsRow(
                    icon: Icons.folder_rounded,
                    title: '主音乐目录',
                    subtitle: controller.primaryScanRootName,
                    onTap: controller.scanningLibrary || controller.backupBusy
                        ? null
                        : () => _chooseV4MusicFolder(context, controller),
                  ),
                  _SettingsRow(
                    icon: Icons.sync_rounded,
                    title: '重新扫描音乐',
                    subtitle:
                        controller.scanProgress?.displayText ?? '检查新增和变化的文件',
                    onTap: controller.scanningLibrary || controller.backupBusy
                        ? null
                        : controller.scanConfiguredRoots,
                  ),
                ],
              ),
              const SizedBox(height: V4Space.section),
              const V4SectionHeader(title: '设置'),
              const SizedBox(height: 10),
              _SettingsPanel(
                children: [
                  _SettingsRow(
                    icon: Icons.shield_outlined,
                    title: '数据与备份',
                    subtitle: controller.lastSuccessfulBackupAt == null
                        ? '尚未创建可卸载恢复的备份'
                        : '上次备份 ${_shortDate(controller.lastSuccessfulBackupAt!)}',
                    onTap: () => _showDataBackupSheet(context, controller),
                  ),
                ],
              ),
              const SizedBox(height: V4Space.lg),
              Text(
                '黑狗音乐只整理手机里的本地音乐。收藏、歌单和播放记录保存在本机。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BackupReminder extends StatelessWidget {
  const _BackupReminder({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '保护你的音乐收藏',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '导出后，即使卸载 App，也能恢复喜欢、歌单和播放记录。',
              style: TextStyle(color: colors.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: controller.backupBusy || controller.scanningLibrary
                      ? null
                      : controller.exportBackup,
                  child: const Text('立即备份'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: controller.backupBusy || controller.scanningLibrary
                      ? null
                      : controller.snoozeBackupReminder,
                  child: const Text('7天后提醒'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showDataBackupSheet(
  BuildContext context,
  AppController controller,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (sheetContext) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final report = controller.dataHealthReport;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '数据与备份',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                controller.lastSuccessfulBackupAt == null
                    ? '备份文件可保存到电脑、移动硬盘或网盘。原始音乐不会被打包。'
                    : '上次成功备份：${_shortDate(controller.lastSuccessfulBackupAt!)}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              if (report != null) ...[
                const SizedBox(height: 14),
                Text(
                  report.healthy
                      ? '数据检查通过'
                      : '发现 ${report.issues.length} 类需要关注的问题',
                  style: TextStyle(
                    color: report.healthy
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                for (final issue in report.issues)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('• ${issue.message}'),
                  ),
              ],
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: controller.backupBusy || controller.scanningLibrary
                    ? null
                    : controller.exportBackup,
                icon: const Icon(Icons.save_alt_rounded),
                label: const Text('导出备份'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: controller.backupBusy || controller.scanningLibrary
                    ? null
                    : () async {
                        final confirmed = await _confirmRestore(sheetContext);
                        if (!confirmed || !sheetContext.mounted) return;
                        final restored = await controller.restoreBackup();
                        if (restored && sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                icon: const Icon(Icons.restore_rounded),
                label: const Text('从备份恢复'),
              ),
              TextButton.icon(
                onPressed: controller.backupBusy || controller.scanningLibrary
                    ? null
                    : controller.runDataHealthCheck,
                icon: const Icon(Icons.health_and_safety_outlined),
                label: const Text('检查当前数据'),
              ),
              if (controller.backupBusy)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      );
    },
  ),
);

Future<bool> _confirmRestore(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复备份？'),
        content: const Text(
          '黑狗音乐会先保护当前数据，再用备份中的收藏、歌单、播放记录和设置替换当前内容。原始音乐文件不会被修改。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('选择备份'),
          ),
        ],
      ),
    ) ??
    false;

String _shortDate(DateTime value) =>
    '${value.year}.${value.month.toString().padLeft(2, '0')}.'
    '${value.day.toString().padLeft(2, '0')}';

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.greeting, required this.onSearch});

  final String greeting;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(V4Space.page, 14, V4Space.page, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            greeting,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: V4Space.xxs),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(
                      '黑狗音乐',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(width: 7),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: colors.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: V4Space.md),
          Material(
            key: const Key('home-search-shortcut'),
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(V4Radius.control),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onSearch,
              child: SizedBox(
                height: 48,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: V4Space.md),
                  child: Row(
                    children: [
                      Icon(
                        Icons.search_rounded,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: V4Space.sm),
                      Expanded(
                        child: Text(
                          '搜索歌曲、歌手、专辑',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickStartCard extends StatelessWidget {
  const _QuickStartCard({
    required this.tracks,
    required this.subtitle,
    required this.onPlay,
  });

  final List<LibraryTrack> tracks;
  final String subtitle;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const Key('home-quick-start'),
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(V4Radius.hero),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPlay,
        child: Container(
          padding: const EdgeInsets.all(V4Space.sm),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(V4Radius.hero),
            border: Border.all(
              color: colors.outlineVariant.withValues(alpha: 0.38),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 104,
                width: double.infinity,
                child: _QuickStartMosaic(tracks: tracks),
              ),
              const SizedBox(height: V4Space.sm),
              Text(
                '随心听',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontSize: 18, height: 1.22),
              ),
              const SizedBox(height: V4Space.xxs),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: V4Space.sm),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: FilledButton.icon(
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('开始播放'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeMoreEntry extends StatelessWidget {
  const _HomeMoreEntry({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(V4Radius.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: V4Space.md,
            vertical: V4Space.sm,
          ),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 44,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(V4Radius.control),
                  ),
                  child: Icon(Icons.more_horiz_rounded, color: colors.primary),
                ),
              ),
              const SizedBox(width: V4Space.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('更多', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      '最近播放 · 最近添加',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickStartMosaic extends StatelessWidget {
  const _QuickStartMosaic({required this.tracks});

  final List<LibraryTrack> tracks;

  @override
  Widget build(BuildContext context) {
    final selected = tracks.take(5).toList(growable: false);
    if (selected.length < 5) return _ArtworkMosaic(tracks: selected);
    return ClipRRect(
      borderRadius: BorderRadius.circular(V4Radius.artwork),
      child: Row(
        children: [
          Expanded(flex: 2, child: _MosaicCell(track: selected[0])),
          const SizedBox(width: 2),
          Expanded(
            flex: 3,
            child: Column(
              children: [
                Expanded(child: _MosaicRow(tracks: selected.sublist(1, 3))),
                const SizedBox(height: 2),
                Expanded(child: _MosaicRow(tracks: selected.sublist(3, 5))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SmartPlayPager extends StatefulWidget {
  const _SmartPlayPager({
    required this.controller,
    required this.tracks,
    required this.onOpenPlayer,
  });

  final AppController controller;
  final List<LibraryTrack> tracks;
  final VoidCallback onOpenPlayer;

  @override
  State<_SmartPlayPager> createState() => _SmartPlayPagerState();
}

class _SmartPlayPagerState extends State<_SmartPlayPager> {
  final GlobalKey _pagerKey = GlobalKey();
  ScrollPosition? _verticalPosition;
  int _activePage = 0;
  bool _markScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    if (position != _verticalPosition) {
      _verticalPosition?.removeListener(_scheduleVisibleTracks);
      _verticalPosition = position;
      _verticalPosition?.addListener(_scheduleVisibleTracks);
    }
    _scheduleVisibleTracks();
  }

  @override
  void didUpdateWidget(covariant _SmartPlayPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleVisibleTracks();
  }

  @override
  void dispose() {
    _verticalPosition?.removeListener(_scheduleVisibleTracks);
    super.dispose();
  }

  void _scheduleVisibleTracks() {
    if (_markScheduled) return;
    _markScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markScheduled = false;
      if (!mounted ||
          ModalRoute.of(context)?.isCurrent != true ||
          (context.findAncestorWidgetOfExactType<IndexedStack>()?.index ?? 0) !=
              0) {
        return;
      }
      final box = _pagerKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      var visible = Offset.zero & MediaQuery.sizeOf(context);
      final viewport = Scrollable.maybeOf(
        context,
        axis: Axis.vertical,
      )?.context.findRenderObject();
      if (viewport is RenderBox && viewport.hasSize) {
        visible = visible.intersect(
          viewport.localToGlobal(Offset.zero) & viewport.size,
        );
      }
      final origin = box.localToGlobal(Offset.zero);
      final tracks = widget.tracks.where((track) => track.isPlayable).toList();
      final ids = <String>[];
      for (var row = 0; row < 3; row++) {
        final index = _activePage * 3 + row;
        if (index >= tracks.length) break;
        final bounds = Rect.fromLTWH(
          origin.dx,
          origin.dy + row * 72,
          box.size.width,
          72,
        );
        if (bounds.overlaps(visible) &&
            bounds.intersect(visible).height >= 36) {
          ids.add(tracks[index].track.trackId);
        }
      }
      widget.controller.markSmartPlayVisibleTracks(ids);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.tracks.where((track) => track.isPlayable).toList();
    final pageCount = (tracks.length / 3).ceil();
    if (tracks.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const V4SectionHeader(title: '智能播放'),
          const SizedBox(height: V4Space.sm),
          V4InlineEmptyState(
            message: widget.controller.libraryTracks.isEmpty
                ? '先选择本地音乐目录，再来探索收藏'
                : '暂无可推荐的歌曲，可从音乐库手动播放',
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        V4SectionHeader(title: '智能播放', subtitle: '探索你的本地收藏'),
        const SizedBox(height: V4Space.sm),
        SizedBox(
          key: _pagerKey,
          height: 216,
          child: PageView.builder(
            key: const Key('home-smart-play-pager'),
            pageSnapping: true,
            itemCount: pageCount,
            onPageChanged: (index) {
              _activePage = index;
              _scheduleVisibleTracks();
            },
            itemBuilder: (context, pageIndex) {
              final start = pageIndex * 3;
              final end = (start + 3).clamp(0, tracks.length);
              final pageTracks = tracks.sublist(start, end);
              return Column(
                children: [
                  for (final track in pageTracks)
                    V4LibraryTrackTile(
                      controller: widget.controller,
                      track: track,
                      playbackTracks: tracks,
                      contextType: 'home_smart_play',
                      onPlayed: widget.onOpenPlayer,
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HomePlaylistSection extends StatelessWidget {
  const _HomePlaylistSection({
    required this.controller,
    required this.onOpenPlaylists,
    required this.onOpenPlayer,
  });

  final AppController controller;
  final VoidCallback onOpenPlaylists;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final playlists = controller.playlistSummaries
        .where((summary) => summary.playlist.type == 'user')
        .take(3)
        .toList();
    final count = 1 + playlists.length;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: count,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: V4Space.md,
        crossAxisSpacing: V4Space.md,
        childAspectRatio: 0.93,
      ),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _HomePlaylistCard(
            title: '我喜欢',
            subtitle: '${controller.libraryCounts.likedCount} 首歌曲',
            tracks: Future.value(controller.likedTracks),
            icon: Icons.favorite_rounded,
            onTap: () => _openCollection(
              context,
              controller,
              '我喜欢',
              controller.allLikedTracks(),
              contextType: 'playlist',
              contextId: 'liked',
              onOpenPlayer: onOpenPlayer,
            ),
          );
        }
        final summary = playlists[index - 1];
        return _HomePlaylistCard(
          title: summary.playlist.name,
          subtitle: '${summary.trackCount} 首歌曲',
          tracks: controller.tracksForPlaylist(summary.playlist.playlistId),
          onTap: () => _openCollection(
            context,
            controller,
            summary.playlist.name,
            controller.tracksForPlaylist(summary.playlist.playlistId),
            contextType: 'playlist',
            contextId: summary.playlist.playlistId,
            onOpenPlayer: onOpenPlayer,
          ),
        );
      },
    );
  }
}

class _HomePlaylistCard extends StatelessWidget {
  const _HomePlaylistCard({
    required this.title,
    required this.subtitle,
    required this.tracks,
    required this.onTap,
    this.icon,
  });

  final String title;
  final String subtitle;
  final Future<List<LibraryTrack>> tracks;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(V4Radius.artwork),
    onTap: onTap,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<List<LibraryTrack>>(
                future: tracks,
                builder: (context, snapshot) =>
                    _ArtworkMosaic(tracks: snapshot.data ?? const []),
              ),
              if (icon != null)
                Positioned(
                  left: V4Space.xs,
                  bottom: V4Space.xs,
                  child: Icon(
                    icon,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: V4Space.xs),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

class _ArtworkMosaic extends StatelessWidget {
  const _ArtworkMosaic({required this.tracks});

  final List<LibraryTrack> tracks;

  @override
  Widget build(BuildContext context) {
    final selected = <LibraryTrack>[];
    final seen = <String>{};
    for (final track in tracks) {
      final artworkId = track.artwork?.artworkId;
      if (artworkId != null && seen.add(artworkId)) selected.add(track);
      if (selected.length == 4) break;
    }
    if (selected.length < 2) {
      return V4Artwork(
        artwork: selected.isEmpty ? null : selected.first.artwork,
        borderRadius: V4Radius.artwork,
        semanticLabel: selected.isEmpty
            ? '默认封面'
            : '${selected.first.track.title}的封面',
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(V4Radius.artwork),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.outlineVariant,
        child: switch (selected.length) {
          2 => _MosaicRow(tracks: selected),
          3 => Row(
            children: [
              Expanded(child: _MosaicCell(track: selected[0])),
              const SizedBox(width: 2),
              Expanded(
                child: Column(
                  children: [
                    Expanded(child: _MosaicCell(track: selected[1])),
                    const SizedBox(height: 2),
                    Expanded(child: _MosaicCell(track: selected[2])),
                  ],
                ),
              ),
            ],
          ),
          _ => Column(
            children: [
              Expanded(child: _MosaicRow(tracks: selected.take(2).toList())),
              const SizedBox(height: 2),
              Expanded(child: _MosaicRow(tracks: selected.skip(2).toList())),
            ],
          ),
        },
      ),
    );
  }
}

class _MosaicRow extends StatelessWidget {
  const _MosaicRow({required this.tracks});

  final List<LibraryTrack> tracks;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var index = 0; index < tracks.length; index++) ...[
        if (index > 0) const SizedBox(width: 2),
        Expanded(child: _MosaicCell(track: tracks[index])),
      ],
    ],
  );
}

class _MosaicCell extends StatelessWidget {
  const _MosaicCell({required this.track});

  final LibraryTrack track;

  @override
  Widget build(BuildContext context) => V4Artwork(
    artwork: track.artwork,
    borderRadius: 0,
    semanticLabel: '${track.track.title}的封面',
  );
}

class _SongLibraryView extends StatefulWidget {
  const _SongLibraryView({
    required this.controller,
    required this.tracks,
    required this.onOpenPlayer,
  });

  final AppController controller;
  final List<LibraryTrack> tracks;
  final VoidCallback onOpenPlayer;

  @override
  State<_SongLibraryView> createState() => _SongLibraryViewState();
}

class _SongLibraryViewState extends State<_SongLibraryView> {
  LibraryBrowseSort sort = LibraryBrowseSort.frequent;
  List<LibraryTrack> _sortedTracks = const [];

  @override
  void initState() {
    super.initState();
    _resort();
  }

  @override
  void didUpdateWidget(covariant _SongLibraryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tracks, widget.tracks)) _resort();
  }

  void _resort() {
    _sortedTracks = sortLibraryTracks(widget.tracks, sort);
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _sortedTracks;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            V4Space.page,
            V4Space.xs,
            V4Space.xs,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '全部歌曲 · ${tracks.length}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton.icon(
                key: const Key('v4-song-sort'),
                icon: const Icon(Icons.swap_vert_rounded, size: 20),
                iconAlignment: IconAlignment.start,
                label: Text(_sortLabel(sort)),
                onPressed: () async {
                  final value = await _showSongSortSheet(context, sort);
                  if (value != null && mounted) {
                    setState(() {
                      sort = value;
                      _resort();
                    });
                  }
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: _TrackList(
            controller: widget.controller,
            tracks: tracks,
            emptyText: '音乐库里还没有歌曲',
            showAlbum: true,
            onOpenPlayer: widget.onOpenPlayer,
          ),
        ),
      ],
    );
  }
}

class _TrackList extends StatelessWidget {
  const _TrackList({
    required this.controller,
    required this.tracks,
    required this.emptyText,
    this.showAlbum = false,
    this.contextType = 'library',
    this.contextId,
    this.onOpenPlayer,
  });

  final AppController controller;
  final List<LibraryTrack> tracks;
  final String emptyText;
  final bool showAlbum;
  final String contextType;
  final String? contextId;
  final VoidCallback? onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    if (controller.loading || controller.experienceLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tracks.isEmpty) {
      return V4EmptyState(
        icon: Icons.library_music_rounded,
        title: emptyText,
        message: '在“我的”中选择或重新扫描你的音乐目录。',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        V4Space.page,
        V4Space.xs,
        V4Space.page,
        V4Space.section,
      ),
      itemCount: tracks.length,
      itemBuilder: (context, index) => V4LibraryTrackTile(
        controller: controller,
        track: tracks[index],
        showAlbum: showAlbum,
        playbackTracks: tracks,
        contextType: contextType,
        contextId: contextId,
        onPlayed: onOpenPlayer,
      ),
    );
  }
}

class _ArtistList extends StatelessWidget {
  const _ArtistList({required this.controller, required this.artists});

  final AppController controller;
  final List<ArtistLibrarySummary> artists;

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) {
      return const V4EmptyState(
        icon: Icons.person_outline_rounded,
        title: '还没有可用歌手',
        message: '扫描完成后会按 Metadata 和目录结构整理歌手。',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        V4Space.page,
        V4Space.xs,
        V4Space.page,
        V4Space.section,
      ),
      itemCount: artists.length,
      itemBuilder: (context, index) {
        final item = artists[index];
        return ListTile(
          leading: V4Artwork(
            artwork: item.artwork,
            size: V4Size.listArtwork,
            borderRadius: V4Size.listArtwork / 2,
            semanticLabel: '${item.artist.displayName}的封面',
          ),
          title: Text(
            item.artist.displayName,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text('${item.trackCount} 首歌曲'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => openV4Artist(context, controller, item),
        );
      },
    );
  }
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({required this.controller, required this.albums});

  final AppController controller;
  final List<AlbumLibrarySummary> albums;

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) {
      return const V4EmptyState(
        icon: Icons.album_outlined,
        title: '还没有可用专辑',
        message: '专辑会按照真实 Metadata 和目录信息整理。',
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        V4Space.page,
        V4Space.md,
        V4Space.page,
        V4Space.section,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: V4Space.lg,
        crossAxisSpacing: V4Space.md,
        childAspectRatio: 0.78,
      ),
      itemCount: albums.length,
      itemBuilder: (context, index) =>
          V4AlbumCard(controller: controller, album: albums[index]),
    );
  }
}

class _FolderList extends StatelessWidget {
  const _FolderList({required this.controller, required this.folders});

  final AppController controller;
  final List<LibraryFolder> folders;

  @override
  Widget build(BuildContext context) {
    if (folders.isEmpty) {
      return const V4EmptyState(
        icon: Icons.folder_open_rounded,
        title: '还没有文件夹',
        message: '选择主音乐目录后，这里会保留你的真实目录结构。',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        V4Space.page,
        V4Space.xs,
        V4Space.page,
        V4Space.section,
      ),
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final item = folders[index];
        return ListTile(
          leading: const Icon(Icons.folder_rounded),
          title: Text(
            item.name,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text('${item.descendantTrackCount} 首歌曲'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _openFolder(context, controller, item),
        );
      },
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.controller,
    required this.result,
    required this.onOpenPlayer,
  });

  final AppController controller;
  final RankedLibrarySearchResult result;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final (icon, subtitle) = switch (result.type) {
      LibrarySearchResultType.track => (
        Icons.music_note_rounded,
        [
          result.track!.track.artistDisplay,
          result.track!.track.albumDisplay,
        ].where((value) => value.trim().isNotEmpty).join(' · '),
      ),
      LibrarySearchResultType.artist => (
        Icons.person_rounded,
        '${result.artist!.trackCount} 首歌曲 · ${result.artist!.albumCount} 张专辑',
      ),
      LibrarySearchResultType.album => (
        Icons.album_rounded,
        [
          if (result.album!.album.year != null) '${result.album!.album.year}',
          '${result.album!.trackCount} 首歌曲',
        ].join(' · '),
      ),
      LibrarySearchResultType.folder => (
        Icons.folder_rounded,
        '${result.folder!.descendantTrackCount} 首歌曲',
      ),
    };
    final artwork = switch (result.type) {
      LibrarySearchResultType.track => result.track?.artwork,
      LibrarySearchResultType.artist => result.artist?.artwork,
      LibrarySearchResultType.album => result.album?.artwork,
      LibrarySearchResultType.folder => null,
    };
    return ListTile(
      leading: artwork == null
          ? _CollectionArtwork(icon: icon)
          : V4Artwork(
              artwork: artwork,
              size: V4Size.listArtwork,
              semanticLabel: '${result.label}的封面',
            ),
      title: Text(
        result.label,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(subtitle),
      onTap: () async {
        switch (result.type) {
          case LibrarySearchResultType.track:
            FocusManager.instance.primaryFocus?.unfocus();
            final playback = controller.playTrackCollection(
              controller.libraryTracks,
              contextType: 'search',
              startTrack: result.track!,
            );
            onOpenPlayer();
            try {
              await playback;
            } catch (_) {
              controller.showMessage('无法播放这首歌，请检查音乐文件是否可用');
            }
          case LibrarySearchResultType.artist:
            openV4Artist(context, controller, result.artist!);
          case LibrarySearchResultType.album:
            openV4Album(context, controller, result.album!);
          case LibrarySearchResultType.folder:
            _openFolder(context, controller, result.folder!);
        }
      },
    );
  }
}

Future<void> _openFolder(
  BuildContext context,
  AppController controller,
  LibraryFolder folder,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => _FolderBrowserPage(controller: controller, folder: folder),
  ),
);

class _FolderBrowserPage extends StatefulWidget {
  const _FolderBrowserPage({required this.controller, required this.folder});

  final AppController controller;
  final LibraryFolder folder;

  @override
  State<_FolderBrowserPage> createState() => _FolderBrowserPageState();
}

class _FolderBrowserPageState extends State<_FolderBrowserPage> {
  late final Future<_FolderContents> _contents = _load();
  bool _playerRouteOpen = false;

  void _openPlayer() {
    if (!mounted || _playerRouteOpen || widget.controller.currentSong == null) {
      return;
    }
    _playerRouteOpen = true;
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute<void>(
            builder: (_) => V4PlayerPage(controller: widget.controller),
          ),
        )
        .whenComplete(() => _playerRouteOpen = false);
  }

  Future<_FolderContents> _load() async {
    final values = await Future.wait<Object>([
      widget.controller.childFolders(widget.folder),
      widget.controller.directTracksForFolder(widget.folder),
    ]);
    return _FolderContents(
      folders: values[0] as List<LibraryFolder>,
      tracks: values[1] as List<LibraryTrack>,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.folder.name)),
    bottomNavigationBar: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => widget.controller.currentSong == null
          ? const SizedBox.shrink()
          : SafeArea(
              top: false,
              child: V4MiniPlayer(
                controller: widget.controller,
                onTap: _openPlayer,
              ),
            ),
    ),
    body: FutureBuilder<_FolderContents>(
      future: _contents,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return V4EmptyState(
            icon: Icons.error_outline_rounded,
            title: '暂时无法打开文件夹',
            message: '${snapshot.error}',
          );
        }
        final contents = snapshot.data!;
        if (contents.folders.isEmpty && contents.tracks.isEmpty) {
          return const V4EmptyState(
            icon: Icons.folder_open_rounded,
            title: '这个文件夹里没有音乐',
            message: '重新扫描后，这里会按手机上的原始目录显示。',
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            V4Space.page,
            V4Space.xs,
            V4Space.page,
            V4Space.section,
          ),
          children: [
            for (final child in contents.folders)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_rounded),
                title: Text(
                  child.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text('${child.descendantTrackCount} 首歌曲'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _openFolder(context, widget.controller, child),
              ),
            if (contents.folders.isNotEmpty && contents.tracks.isNotEmpty)
              const Divider(height: V4Space.section),
            for (final track in contents.tracks)
              V4LibraryTrackTile(
                controller: widget.controller,
                track: track,
                showAlbum: true,
                playbackTracks: contents.tracks,
                contextType: 'folder',
                contextId:
                    '${widget.folder.scanRootId}:${widget.folder.relativePath}',
                onPlayed: _openPlayer,
              ),
          ],
        );
      },
    ),
  );
}

class _FolderContents {
  const _FolderContents({required this.folders, required this.tracks});

  final List<LibraryFolder> folders;
  final List<LibraryTrack> tracks;
}

class _CollectionArtwork extends StatelessWidget {
  const _CollectionArtwork({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: V4Size.listArtwork,
      height: V4Size.listArtwork,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(V4Radius.control),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Icon(icon, color: colors.onSurfaceVariant, size: 25),
    );
  }
}

class _MusicArchiveContent extends StatelessWidget {
  const _MusicArchiveContent({required this.archive});

  final MusicArchiveSnapshot archive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(V4Space.page),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(V4Radius.card),
          ),
          child: archive.hasListeningData
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${archive.year} 年', style: textTheme.labelLarge),
                    const SizedBox(height: V4Space.sm),
                    Row(
                      children: [
                        _ArchiveMetric(
                          value: '${archive.distinctTrackCount}',
                          label: '听过的歌曲',
                        ),
                        _ArchiveMetric(
                          value: _archiveDuration(archive.listenedDurationMs),
                          label: '累计听歌',
                        ),
                      ],
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${archive.year} 年', style: textTheme.labelLarge),
                    const SizedBox(height: V4Space.xs),
                    Text(
                      '开始播放音乐后，这里会慢慢形成属于你的听歌记录。',
                      style: textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
        ),
        if (archive.hasListeningData &&
            (archive.topTrack != null ||
                archive.topArtist != null ||
                archive.topAlbum != null)) ...[
          const SizedBox(height: V4Space.section),
          const V4SectionHeader(title: '最常听'),
          const SizedBox(height: V4Space.sm),
          if (archive.topTrack case final track?)
            Row(
              children: [
                V4Artwork(
                  artwork: track.artwork,
                  size: V4Size.listArtwork,
                  semanticLabel: track.track.title,
                  fallbackSeed: track.track.trackId,
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
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        track.track.artistDisplay,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          if (archive.topArtist != null || archive.topAlbum != null) ...[
            const SizedBox(height: V4Space.sm),
            Text(
              [
                if (archive.topArtist != null) '歌手 · ${archive.topArtist}',
                if (archive.topAlbum != null) '专辑 · ${archive.topAlbum}',
              ].join('\n'),
              style: textTheme.bodyMedium?.copyWith(
                height: 1.6,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
        if (archive.listeningPeriod != null) ...[
          const SizedBox(height: V4Space.section),
          const V4SectionHeader(title: '听歌习惯'),
          const SizedBox(height: V4Space.xs),
          Text(
            '你最常在${archive.listeningPeriod}听歌',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
        const SizedBox(height: V4Space.section),
        const V4SectionHeader(title: '收藏'),
        const SizedBox(height: V4Space.sm),
        Row(
          children: [
            _ArchiveMetric(value: '${archive.likedCount}', label: '喜欢的歌曲'),
            _ArchiveMetric(value: '${archive.playlistCount}', label: '自建歌单'),
          ],
        ),
        if (archive.recordStartedAt != null) ...[
          const SizedBox(height: V4Space.section),
          Text(
            '记录始于 ${archive.recordStartedAt!.year} 年',
            style: textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _ArchiveMetric extends StatelessWidget {
  const _ArchiveMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 3),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

String _archiveDuration(int milliseconds) {
  final duration = Duration(milliseconds: milliseconds);
  if (duration.inHours > 0) {
    final minutes = duration.inMinutes.remainder(60);
    return minutes == 0
        ? '${duration.inHours} 小时'
        : '${duration.inHours} 小时 $minutes 分';
  }
  return '${duration.inMinutes} 分钟';
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(V4Radius.card),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle),
    trailing: onTap == null ? null : const Icon(Icons.chevron_right_rounded),
    onTap: onTap,
  );
}

Future<void> _chooseV4MusicFolder(
  BuildContext context,
  AppController controller,
) async {
  try {
    final selected = await controller.chooseMusicFolderAndScan();
    if (!context.mounted) return;
    controller.showMessage(selected ? '音乐目录已保存并完成扫描' : '没有选择音乐目录');
  } catch (error) {
    if (!context.mounted) return;
    controller.showMessage('扫描失败：$error');
  }
}

Future<void> _showHomeMoreSheet(
  BuildContext context,
  AppController controller,
  VoidCallback onOpenPlayer,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (sheetContext) => DefaultTabController(
    length: 2,
    child: SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.76,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: V4Space.page),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '更多音乐',
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const TabBar(
              tabs: [
                Tab(text: '最近播放'),
                Tab(text: '最近添加'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _TrackList(
                    controller: controller,
                    tracks: controller.recentlyPlayedTracks.take(9).toList(),
                    emptyText: '还没有播放记录',
                    contextType: 'home_recent_played',
                    onOpenPlayer: () {
                      Navigator.pop(sheetContext);
                      onOpenPlayer();
                    },
                  ),
                  _TrackList(
                    controller: controller,
                    tracks: controller.recentlyAddedTracks.take(9).toList(),
                    emptyText: '还没有最近添加的歌曲',
                    contextType: 'home_recent_added',
                    onOpenPlayer: () {
                      Navigator.pop(sheetContext);
                      onOpenPlayer();
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

Future<void> _openCollection(
  BuildContext context,
  AppController controller,
  String title,
  Future<List<LibraryTrack>> future, {
  required String contextType,
  String? contextId,
  required VoidCallback onOpenPlayer,
}) async {
  var shouldOpenPlayer = false;
  ModalRoute<dynamic>? closingRoute;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                V4Space.page,
                0,
                V4Space.page,
                V4Space.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<LibraryTrack>>(
                future: future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return V4EmptyState(
                      icon: Icons.error_outline_rounded,
                      title: '暂时无法打开',
                      message: '${snapshot.error}',
                    );
                  }
                  return _TrackList(
                    controller: controller,
                    tracks: snapshot.data ?? const [],
                    emptyText: '这里还没有歌曲',
                    contextType: contextType,
                    contextId: contextId,
                    onOpenPlayer: () {
                      if (shouldOpenPlayer) return;
                      shouldOpenPlayer = true;
                      closingRoute = ModalRoute.of(sheetContext);
                      Navigator.pop(sheetContext);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (shouldOpenPlayer) {
    await closingRoute?.completed;
    if (context.mounted) onOpenPlayer();
  }
}

Future<void> _createPlaylist(
  BuildContext context,
  AppController controller,
) async {
  await showV4CreatePlaylist(context, controller);
}

Future<void> _deletePlaylist(
  BuildContext context,
  AppController controller,
  PlaylistLibrarySummary summary,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除歌单？'),
      content: Text('只删除“${summary.playlist.name}”歌单，不会删除音乐文件。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    try {
      await controller.deletePlaylist(summary.playlist.playlistId);
      if (!context.mounted) return;
      controller.showMessage('已删除歌单“${summary.playlist.name}”');
    } catch (error) {
      if (!context.mounted) return;
      controller.showMessage('删除歌单失败：$error');
    }
  }
}

String _greeting(int hour) {
  if (hour < 6) return '夜深了';
  if (hour < 12) return '早上好';
  if (hour < 18) return '下午好';
  return '晚上好';
}

String _sortLabel(LibraryBrowseSort sort) => switch (sort) {
  LibraryBrowseSort.frequent => '按常听程度',
  LibraryBrowseSort.title => '按歌名',
  LibraryBrowseSort.year => '按年份',
  LibraryBrowseSort.artist => '按歌手',
  LibraryBrowseSort.album => '按专辑与曲序',
  LibraryBrowseSort.recentlyAdded => '按最近添加',
  LibraryBrowseSort.playCount => '按播放次数',
};

String _sortDescription(LibraryBrowseSort sort) => switch (sort) {
  LibraryBrowseSort.frequent => '综合喜欢、主动选择、完整听完与最近播放',
  LibraryBrowseSort.title => '按拼音与字母 A–Z 排列',
  LibraryBrowseSort.year => '发行年份从旧到新',
  LibraryBrowseSort.playCount => '最常听的歌曲排在前面',
  LibraryBrowseSort.recentlyAdded => '最近加入音乐库的歌曲排在前面',
  _ => '',
};

Future<LibraryBrowseSort?> _showSongSortSheet(
  BuildContext context,
  LibraryBrowseSort selected,
) => showModalBottomSheet<LibraryBrowseSort>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.only(bottom: V4Space.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              V4Space.page,
              0,
              V4Space.page,
              V4Space.xs,
            ),
            child: Text('歌曲排序', style: Theme.of(context).textTheme.titleLarge),
          ),
          for (final value in const [
            LibraryBrowseSort.frequent,
            LibraryBrowseSort.title,
            LibraryBrowseSort.year,
            LibraryBrowseSort.playCount,
            LibraryBrowseSort.recentlyAdded,
          ])
            ListTile(
              minTileHeight: 64,
              title: Text(_sortLabel(value)),
              subtitle: Text(_sortDescription(value)),
              trailing: selected == value
                  ? Icon(
                      Icons.check_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => Navigator.pop(context, value),
            ),
        ],
      ),
    ),
  ),
);
