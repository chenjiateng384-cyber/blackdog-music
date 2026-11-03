import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' show AudioPlayer, PlayerState;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/file_identity_repository.dart';
import '../data/library_repository.dart';
import '../data/library_search_repository.dart';
import '../data/lyrics_repository.dart';
import '../data/migration_repository.dart';
import '../data/music_archive_repository.dart';
import '../data/playback_history_repository.dart';
import '../data/playlist_repository.dart';
import '../data/scan_repository.dart';
import '../models/song.dart';
import '../models/v4/artwork.dart';
import '../models/v4/legacy_song_compatibility.dart';
import '../models/v4/home_experience.dart';
import '../models/v4/library_entities.dart';
import '../models/v4/library_search.dart';
import '../models/v4/library_track.dart';
import '../models/v4/listening_preference.dart';
import '../models/v4/lyrics.dart';
import '../models/v4/music_archive.dart';
import '../models/v4/playback.dart';
import '../models/v4/recommendation_behavior.dart';
import '../models/v4/scan_models.dart';
import '../models/v4/data_safety.dart';
import '../services/harmony_backup_service.dart';
import '../services/library_scan_service.dart';
import '../services/library_database.dart';
import '../services/home_quick_start_radio.dart';
import '../services/home_smart_play_pool.dart';
import '../services/lyrics_service.dart';
import '../services/music_audio_handler.dart';
import '../services/music_platform.dart';
import '../services/metadata_service.dart';
import '../services/playback_history_service.dart';
import '../services/recommendation_eligibility.dart';

class AppController extends ChangeNotifier {
  AppController({
    MusicPlatform? platform,
    LibraryDatabase? database,
    MusicAudioHandler? audioHandler,
    MetadataService? metadataService,
    LibraryScanService? scanService,
    HarmonyBackupService? backupService,
    DateTime Function()? now,
    Random? homeRandom,
  }) : _platform = platform ?? MusicPlatform(),
       _database = database ?? LibraryDatabase(),
       _ownsAudioHandler = audioHandler == null,
       _ownsScanService = scanService == null,
       _now = now ?? DateTime.now,
       _homeRandom = homeRandom ?? Random(),
       audioHandler = audioHandler ?? MusicAudioHandler() {
    _metadataService = metadataService ?? MetadataService(_database);
    _libraryRepository = LibraryRepository(_database);
    _librarySearchRepository = LibrarySearchRepository(
      _database,
      _libraryRepository,
    );
    _playlistRepository = PlaylistRepository(_database);
    _lyricsService = LyricsService(repository: LyricsRepository(_database));
    _playbackHistoryRepository = PlaybackHistoryRepository(_database);
    _playbackHistory = PlaybackHistoryService(
      _playbackHistoryRepository,
      onHistoryChanged: _scheduleExperienceRefresh,
    );
    _musicArchiveRepository = MusicArchiveRepository(
      _database,
      _libraryRepository,
    );
    musicArchive = MusicArchiveSnapshot.empty(_now().year);
    this.audioHandler.attachPlaybackHistory(_playbackHistory);
    _homeQuickStartRadio = HomeQuickStartRadio(random: _homeRandom);
    _scanService =
        scanService ??
        LibraryScanService(
          repository: ScanRepository(_database),
          migrationRepository: MigrationRepository(_database),
          identityRepository: FileIdentityRepository(_database),
        );
    _backupService = backupService ?? HarmonyBackupService(database: _database);
  }

  final MusicPlatform _platform;
  final LibraryDatabase _database;
  final bool _ownsAudioHandler;
  final bool _ownsScanService;
  final DateTime Function() _now;
  final MusicAudioHandler audioHandler;
  late final MetadataService _metadataService;
  late final LibraryRepository _libraryRepository;
  late final LibrarySearchRepository _librarySearchRepository;
  late final PlaylistRepository _playlistRepository;
  late final LyricsService _lyricsService;
  late final PlaybackHistoryRepository _playbackHistoryRepository;
  late final PlaybackHistoryService _playbackHistory;
  late final MusicArchiveRepository _musicArchiveRepository;
  late final LibraryScanService _scanService;
  late final HarmonyBackupService _backupService;
  final Set<int> _enrichingIds = {};
  final Set<int> _enrichmentCompleted = {};
  Set<int> _manualOverrideIds = {};
  final Map<int, LibraryTrack> _legacyTrackById = {};

  AudioPlayer get player => audioHandler.player;

  List<Song> songs = const [];
  List<LibraryTrack> libraryTracks = const [];
  Set<int> favoriteIds = {};
  List<MusicCategory> categories = const [];
  Song? currentSong;
  LibraryTrack? currentLibraryTrack;
  String query = '';
  bool loading = true;
  String? error;
  List<ScanRoot> scanRoots = const [];
  LibraryScanProgress? scanProgress;
  LibraryCounts libraryCounts = const LibraryCounts(
    trackCount: 0,
    artistCount: 0,
    albumCount: 0,
    likedCount: 0,
  );
  List<LibraryTrack> recentlyAddedTracks = const [];
  List<LibraryTrack> recentlyPlayedTracks = const [];
  List<LibraryTrack> likedTracks = const [];
  List<LibraryTrack> mostPlayedTracks = const [];
  List<ArtistLibrarySummary> artistSummaries = const [];
  List<AlbumLibrarySummary> albumSummaries = const [];
  List<LibraryFolder> libraryFolders = const [];
  List<PlaylistLibrarySummary> playlistSummaries = const [];
  Map<String, ArtworkReference> playlistCovers = const {};
  LibrarySearchResults searchResults = LibrarySearchResults.empty('');
  PlaybackQueueSnapshot _playbackQueue = const PlaybackQueueSnapshot.empty();
  PlaybackContext _activePlaybackContext = PlaybackContext.library;
  bool experienceLoading = false;
  bool searchLoading = false;
  String? searchError;
  int _searchGeneration = 0;
  bool _experienceRefreshRunning = false;
  Completer<void>? _experienceRefreshDone;
  bool _experienceRefreshPending = false;
  Timer? _experienceRefreshTimer;
  Timer? _notifyTimer;
  Timer? _scanProgressNotifyTimer;
  bool _disposed = false;
  final Random _homeRandom;
  late final HomeQuickStartRadio _homeQuickStartRadio;
  final HomeSmartPlayPool _homeSmartPlayPool = HomeSmartPlayPool();
  bool _homeQuickStartRefillRunning = false;
  String? _lastHomeQuickStartFirstTrackId;
  int _homeQuickStartSessionSerial = 0;
  bool _restoredHomeQuickStartWithoutQueue = false;
  HomeExperience _homeExperience = const HomeExperience(
    quickStartTracks: [],
    todayTracks: [],
    frequentArtists: [],
  );
  List<LibraryTrack> _homeSmartPlayTracks = const [];
  Map<String, RecommendationBehaviorSignal> _recommendationBehaviorSignals =
      const {};
  String? _homeSmartPlayDayKey;
  int _homeSmartPlayGeneration = 0;
  int _homeSmartPlayRefreshSerial = 0;
  final Set<String> _homeSmartPlayViewedIds = {};
  final Set<String> _homeSmartPlaySelectedIds = {};
  Set<String> _homeSmartPlayVisibleIds = {};
  Future<void>? _homeRecommendationRefresh;
  Timer? _sleepTimerTicker;
  Timer? _playbackSessionTimer;
  bool _savingPlaybackSession = false;
  Completer<void>? _playbackSessionSaved;
  bool _restoringPlaybackSession = false;
  final StreamController<String> _uiMessageController =
      StreamController<String>.broadcast();

  CrystalPlayerView crystalPlayerView = CrystalPlayerView.artwork;
  ImmersivePlayerView immersivePlayerView = ImmersivePlayerView.artwork;
  bool immersiveSleepPanelOpen = false;
  List<LibraryTrack> playbackHistory = const [];
  double volumePercent = 100;
  DateTime? sleepTimerEndsAt;
  Duration? sleepTimerRemaining;
  ListeningPreference listeningPreference = const ListeningPreference();
  DataHealthReport? dataHealthReport;
  DateTime? lastSuccessfulBackupAt;
  bool backupReminderDue = false;
  bool backupBusy = false;
  bool _scanRequested = false;
  bool _restoringData = false;
  late MusicArchiveSnapshot musicArchive;

  StreamSubscription<PlayerState>? _playerSubscription;
  StreamSubscription<Song?>? _songSubscription;
  StreamSubscription<LibraryTrack?>? _trackSubscription;
  StreamSubscription<PlaybackQueueSnapshot>? _queueSubscription;
  StreamSubscription<LibraryScanProgress>? _scanProgressSubscription;

  List<Song> get visibleSongs {
    final term = query.trim().toLowerCase();
    if (term.isEmpty) return songs;
    return songs
        .where(
          (song) =>
              song.title.toLowerCase().contains(term) ||
              song.artist.toLowerCase().contains(term),
        )
        .toList(growable: false);
  }

  bool get isPlaying => player.playing;
  PlaybackMode get playbackMode => audioHandler.playbackMode;
  PlayerPageKind get playerPageKind => _activePlaybackContext.playerPageKind;
  bool get homeQuickStartActive =>
      _activePlaybackContext.type == 'home_quick_start' &&
      currentLibraryTrack != null &&
      !_restoredHomeQuickStartWithoutQueue;
  PlaybackQueueSnapshot get playbackQueue => _playbackQueue;
  set playbackQueue(PlaybackQueueSnapshot value) {
    _playbackQueue = value;
    _activePlaybackContext = value.context;
  }

  int? get repeatCount => playbackQueue.repeatCount;
  int? get repeatLeft => playbackQueue.repeatLeft;
  Stream<String> get uiMessages => _uiMessageController.stream;

  void showMessage(String message) => _emitUiMessage(message);
  List<LibraryTrack> get playbackQueueTracks {
    return playbackQueue.entries
        .map((entry) => entry.track)
        .toList(growable: false);
  }

  List<QueueEntry> get upcomingQueueEntries => playbackQueue.upcoming;

  HomeExperience get homeExperience => _homeExperience;
  List<LibraryTrack> get homePlayCountTracks => _homeSmartPlayTracks;
  String get manualOnlyPlaylistId => PlaylistRepository.manualOnlyPlaylistId;
  int get upgradeCount => songs.where((song) => song.needsUpgrade).length;
  int get suspiciousCount => songs.where((song) => song.isSuspicious).length;
  List<Song> get recentSongs => songs.take(8).toList(growable: false);
  bool get scanningLibrary => _scanRequested || _scanService.isScanning;
  String get primaryScanRootName => scanRoots.isEmpty
      ? '尚未选择音乐目录'
      : scanRoots
            .firstWhere((root) => root.isPrimary, orElse: () => scanRoots.first)
            .displayName;

  Future<void> initialize() async {
    await audioHandler.preparePlaybackHistory();
    await _scanService.recoverInterruptedScans();
    await _loadListeningPreference();
    volumePercent = audioHandler.volumePercent;
    _playerSubscription = player.playerStateStream.listen((state) {
      _scheduleNotifyListeners();
      if (!state.playing) unawaited(savePlaybackSession());
    });
    _songSubscription = audioHandler.currentSongStream.listen((song) {
      currentSong = song;
      _scheduleNotifyListeners();
    });
    _trackSubscription = audioHandler.currentTrackStream.listen((track) {
      _rememberPreviousTrack(track);
      currentLibraryTrack = track;
      _scheduleNotifyListeners();
    });
    playbackQueue = audioHandler.queueSnapshot;
    _activePlaybackContext = playbackQueue.context;
    final restoredTrack = playbackQueue.current?.track;
    if (restoredTrack != null) {
      currentLibraryTrack = restoredTrack;
      currentSong = LegacySongCompatibility.libraryTrackToLegacySong(
        restoredTrack,
      );
    }
    _queueSubscription = audioHandler.queueSnapshotStream.listen((snapshot) {
      playbackQueue = snapshot;
      _activePlaybackContext = snapshot.context;
      _scheduleNotifyListeners();
      if (snapshot.context.type == 'home_quick_start') {
        unawaited(_refillHomeQuickStartIfNeeded(snapshot));
      }
    });
    _scanProgressSubscription = _scanService.progress.listen((progress) {
      final previous = scanProgress;
      scanProgress = progress;
      final phaseChanged = previous?.phase != progress.phase;
      final completed =
          progress.finished ||
          (progress.total > 0 && progress.processed >= progress.total);
      if (phaseChanged || completed) {
        _scanProgressNotifyTimer?.cancel();
        _scanProgressNotifyTimer = null;
        _scheduleNotifyListeners();
      } else if (_scanProgressNotifyTimer?.isActive != true) {
        _scanProgressNotifyTimer = Timer(const Duration(milliseconds: 800), () {
          _scanProgressNotifyTimer = null;
          _scheduleNotifyListeners();
        });
      }
    });
    await refresh();
    await _restorePlaybackSession();
    _playbackSessionTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(savePlaybackSession()),
    );
    await _reloadScanRoots();
    await _refreshBackupState();
    // Startup must stay lightweight. A configured SAF root can contain
    // hundreds or thousands of files; recursively reopening every file and
    // reparsing tags on each launch caused sustained I/O and database
    // contention while the user was already trying to browse or play music.
    // The cached V4 library is authoritative until the user explicitly asks
    // for a rescan after copying new music to the phone.
  }

  void _rememberPreviousTrack(LibraryTrack? nextTrack) {
    final previous = currentLibraryTrack;
    if (previous == null ||
        previous.track.trackId == nextTrack?.track.trackId) {
      return;
    }
    final updated = <LibraryTrack>[previous, ...playbackHistory];
    final deduplicated = <LibraryTrack>[];
    final seen = <String>{};
    for (final item in updated) {
      if (seen.add(item.track.trackId)) deduplicated.add(item);
      if (deduplicated.length == 60) break;
    }
    playbackHistory = List.unmodifiable(deduplicated);
  }

  void setCrystalPlayerView(CrystalPlayerView view) {
    if (crystalPlayerView == view) return;
    crystalPlayerView = view;
    notifyListeners();
  }

  void setImmersivePlayerView(ImmersivePlayerView view) {
    if (immersivePlayerView == view) return;
    immersivePlayerView = view;
    notifyListeners();
  }

  void setImmersiveSleepPanelOpen(bool open) {
    if (immersiveSleepPanelOpen == open) return;
    immersiveSleepPanelOpen = open;
    notifyListeners();
  }

  Future<void> setVolumePercent(double value) async {
    volumePercent = value.clamp(0, 100).toDouble();
    await audioHandler.setVolumePercent(volumePercent);
    notifyListeners();
  }

  void setSleepTimerMinutes(int minutes) {
    if (minutes < 1 || minutes > 600) {
      throw RangeError.range(minutes, 1, 600, 'minutes');
    }
    sleepTimerEndsAt = _now().add(Duration(minutes: minutes));
    sleepTimerRemaining = Duration(minutes: minutes);
    _startSleepTimerTicker();
    _emitUiMessage('$minutes 分钟后暂停播放');
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimerTicker?.cancel();
    _sleepTimerTicker = null;
    sleepTimerEndsAt = null;
    sleepTimerRemaining = null;
    _emitUiMessage('已关闭定时停止');
    notifyListeners();
  }

  Future<void> syncTimeBasedState() async {
    final end = sleepTimerEndsAt;
    if (end == null) return;
    final remaining = end.difference(_now());
    if (remaining <= Duration.zero) {
      _sleepTimerTicker?.cancel();
      _sleepTimerTicker = null;
      sleepTimerEndsAt = null;
      sleepTimerRemaining = null;
      await audioHandler.pause();
      _emitUiMessage('睡眠定时结束，已暂停');
    } else {
      sleepTimerRemaining = remaining;
      _startSleepTimerTicker();
    }
    notifyListeners();
  }

  void _startSleepTimerTicker() {
    _sleepTimerTicker?.cancel();
    _sleepTimerTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(syncTimeBasedState());
    });
  }

  void _emitUiMessage(String message) {
    if (!_disposed) _uiMessageController.add(message);
  }

  void setFamiliarityPreference(FamiliarityPreference value) {
    listeningPreference = listeningPreference.copyWith(familiarity: value);
    notifyListeners();
  }

  void setMoodPreference(MoodPreference value) {
    listeningPreference = listeningPreference.copyWith(mood: value);
    notifyListeners();
  }

  void cycleScenePreference(String scene) {
    if (!harmonyListeningScenes.contains(scene)) return;
    final current = listeningPreference.sceneLevel(scene);
    final next = switch (current) {
      ScenePreferenceLevel.balanced => ScenePreferenceLevel.frequent,
      ScenePreferenceLevel.frequent => ScenePreferenceLevel.random,
      ScenePreferenceLevel.random => ScenePreferenceLevel.balanced,
    };
    final scenes = Map<String, ScenePreferenceLevel>.of(
      listeningPreference.scenes,
    )..[scene] = next;
    listeningPreference = listeningPreference.copyWith(scenes: scenes);
    notifyListeners();
  }

  Future<void> saveListeningPreference() async {
    listeningPreference = listeningPreference.copyWith(savedAt: _now());
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _listeningPreferenceKey,
      jsonEncode(listeningPreference.toJson()),
    );
    await _loadOrBuildHomeSmartPlayPool(force: true);
    _emitUiMessage('偏好已保存，这次就按它听');
    notifyListeners();
  }

  Future<void> resetListeningPreference() async {
    listeningPreference = const ListeningPreference();
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_listeningPreferenceKey);
    await _loadOrBuildHomeSmartPlayPool(force: true);
    notifyListeners();
  }

  Future<void> _loadListeningPreference() async {
    const fallback = ListeningPreference();
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_listeningPreferenceKey);
      if (raw == null) {
        listeningPreference = fallback;
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        listeningPreference = fallback;
        return;
      }
      final loaded = ListeningPreference.fromJson(
        decoded.map((key, value) => MapEntry('$key', value)),
      );
      listeningPreference = loaded.isActiveAt(_now()) ? loaded : fallback;
      if (!loaded.isActiveAt(_now())) {
        await preferences.remove(_listeningPreferenceKey);
      }
    } catch (_) {
      listeningPreference = fallback;
    }
  }

  static const _listeningPreferenceKey = 'harmony.listening_preference.v1';
  static const _homeSmartPlayPoolKey = 'harmony.home_smart_play_pool.v1';
  static const _playbackSessionKey = 'harmony.playback_session.v1';

  Future<void> savePlaybackSession() async {
    if (_savingPlaybackSession || _restoringPlaybackSession || _restoringData) {
      return;
    }
    final track = currentLibraryTrack;
    if (track == null ||
        audioHandler.mediaItem.value?.id != track.track.trackId) {
      return;
    }
    _savingPlaybackSession = true;
    _playbackSessionSaved = Completer<void>();
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _playbackSessionKey,
        jsonEncode({
          'trackId': track.track.trackId,
          'positionMs': player.position.inMilliseconds,
          'contextType': _activePlaybackContext.type,
          'contextId': _activePlaybackContext.id,
        }),
      );
    } finally {
      _savingPlaybackSession = false;
      _playbackSessionSaved?.complete();
      _playbackSessionSaved = null;
    }
  }

  Future<void> savePlaybackState() async {
    await Future.wait([savePlaybackSession(), _playbackHistory.checkpoint()]);
  }

  Future<void> _restorePlaybackSession() async {
    if (libraryTracks.isEmpty || currentLibraryTrack != null) return;
    _restoringPlaybackSession = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_playbackSessionKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final trackId = decoded['trackId'] as String?;
      if (trackId == null) return;
      final matches = libraryTracks.where(
        (item) => item.track.trackId == trackId && item.isPlayable,
      );
      if (matches.isEmpty) return;
      final track = matches.first;
      final savedMs = (decoded['positionMs'] as num?)?.toInt() ?? 0;
      final durationMs = track.track.durationMs;
      final positionMs = durationMs > 0 && savedMs >= durationMs - 1000
          ? 0
          : savedMs.clamp(0, durationMs > 0 ? durationMs : savedMs);
      final context = PlaybackContext(
        type: decoded['contextType'] as String? ?? 'library',
        id: decoded['contextId'] as String?,
      );
      // Only the current track and position are persisted. Do not treat the
      // full library loaded below as a restored rolling radio queue.
      _restoredHomeQuickStartWithoutQueue = context.type == 'home_quick_start';
      _activePlaybackContext = context;
      audioHandler.setTrackLibrary(libraryTracks, context: context);
      currentLibraryTrack = track;
      currentSong = LegacySongCompatibility.libraryTrackToLegacySong(track);
      _scheduleNotifyListeners();
      await audioHandler.restoreTrack(
        track,
        position: Duration(milliseconds: positionMs),
        context: context,
      );
    } catch (exception, stackTrace) {
      debugPrint('恢复上次播放位置失败，继续正常启动：$exception');
      debugPrintStack(stackTrace: stackTrace);
      _restoredHomeQuickStartWithoutQueue = false;
      currentLibraryTrack = null;
      currentSong = null;
    } finally {
      _restoringPlaybackSession = false;
    }
  }

  Future<bool> chooseMusicFolderAndScan() async {
    if (backupBusy || scanningLibrary) return false;
    _scanRequested = true;
    notifyListeners();
    try {
      final root = await _scanService.chooseRoot(
        makePrimary: scanRoots.isEmpty,
      );
      if (root == null) return false;
      await _reloadScanRoots();
      await _scanService.scanRoot(root);
      await _reloadV4Library();
      await _reloadScanRoots();
      return true;
    } finally {
      _scanRequested = false;
      notifyListeners();
    }
  }

  Future<void> scanConfiguredRoots() async {
    if (backupBusy || scanningLibrary || scanRoots.isEmpty) return;
    _scanRequested = true;
    notifyListeners();
    try {
      await _scanService.scanAll();
      await _reloadV4Library();
      await _reloadScanRoots();
    } catch (exception) {
      scanProgress = LibraryScanProgress(
        scanId: '',
        phase: 'failed',
        discovered: 0,
        processed: 0,
        total: 0,
        finished: true,
        message: '$exception',
      );
      notifyListeners();
    } finally {
      _scanRequested = false;
      notifyListeners();
    }
  }

  Future<void> _reloadScanRoots() async {
    scanRoots = await _scanService.scanRoots();
    notifyListeners();
  }

  Future<bool> _reloadV4Library() async {
    final tracks = await _libraryRepository.allTracks(
      sort: LibraryTrackSort.recentlyAdded,
    );
    if (tracks.isEmpty) {
      // A V4 database containing only missing files is still authoritative.
      // Falling back to legacy MediaStore rows would resurrect ghost songs.
      final unavailable = await _libraryRepository.allTracks(
        limit: 1,
        includeUnavailable: true,
      );
      if (unavailable.isEmpty) return false;
    }
    _legacyTrackById.clear();
    final usedIds = <int>{};
    final runtimeTracks = <LibraryTrack>[];
    final compatibleSongs = <Song>[];
    final likedIds = <int>{};
    for (final item in tracks) {
      var legacyId =
          item.legacySongId ??
          item.preferredFile?.mediaStoreId ??
          LegacySongCompatibility.stableLegacyId(item.track.trackId);
      while (!usedIds.add(legacyId)) {
        legacyId = legacyId == 0x7fffffff ? 1 : legacyId + 1;
      }
      final runtimeItem = item.copyWith(legacySongId: legacyId);
      runtimeTracks.add(runtimeItem);
      _legacyTrackById[legacyId] = runtimeItem;
      compatibleSongs.add(
        LegacySongCompatibility.libraryTrackToLegacySong(
          runtimeItem,
          legacyNumericId: legacyId,
        ),
      );
      if (runtimeItem.preference.liked) likedIds.add(legacyId);
    }
    libraryTracks = List.unmodifiable(runtimeTracks);
    await _loadOrBuildHomeSmartPlayPool();
    songs = List.unmodifiable(compatibleSongs);
    favoriteIds = likedIds;
    // A library refresh must not replace an album/playlist/folder queue that
    // is already active. Only establish the default library queue when there
    // is no runtime queue to preserve.
    if (audioHandler.queueSnapshot.entries.isEmpty) {
      audioHandler.setTrackLibrary(libraryTracks);
    }
    return true;
  }

  Future<bool> _ensureAudioPermission() async {
    final status = await Permission.audio.request();
    return status.isGranted;
  }

  Future<void> refresh() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final loadedV4 = await _reloadV4Library();
      if (loadedV4) {
        error = null;
      } else if (!await _ensureAudioPermission()) {
        error = '需要“音乐和音频”权限，才能显示手机里的歌曲。';
        songs = const [];
      } else {
        libraryTracks = const [];
        _legacyTrackById.clear();
        songs = await _platform.scanMusic();
        final overrides = await _database.songOverrides();
        _manualOverrideIds = overrides.keys.toSet();
        songs = songs
            .map((song) {
              final override = overrides[song.id];
              return override == null
                  ? song
                  : song.copyWith(
                      title: override.title,
                      artist: override.artist,
                      album: override.album,
                    );
            })
            .toList(growable: false);
        audioHandler.setLibrary(songs);
        favoriteIds = await _database.favoriteIds();
      }
      categories = await _database.categories();
      await _playlistRepository.synchronizeLegacyCategories();
      await _playlistRepository.ensureManualOnlyPlaylist();
      await _reloadExperienceData();
    } catch (exception) {
      error = '读取音乐库失败：$exception';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> runDataHealthCheck() async {
    if (backupBusy || scanningLibrary) return;
    backupBusy = true;
    notifyListeners();
    try {
      dataHealthReport = await _backupService.inspectData(
        activePlaybackEventId: _playbackHistory.activeEventId,
      );
      _emitUiMessage(
        dataHealthReport!.healthy
            ? '数据检查通过'
            : '检查完成，发现 ${dataHealthReport!.issues.length} 类需要关注的问题',
      );
    } catch (exception) {
      _emitUiMessage('数据检查失败：$exception');
    } finally {
      backupBusy = false;
      notifyListeners();
    }
  }

  Future<void> exportBackup() async {
    if (backupBusy || scanningLibrary) return;
    backupBusy = true;
    notifyListeners();
    try {
      final result = await _backupService.exportBackup();
      if (result != null) {
        lastSuccessfulBackupAt = result.manifest.createdAt;
        backupReminderDue = false;
        _emitUiMessage('备份已保存');
      }
    } catch (exception) {
      _emitUiMessage('备份失败：$exception');
    } finally {
      backupBusy = false;
      notifyListeners();
    }
  }

  Future<bool> restoreBackup() async {
    if (backupBusy || scanningLibrary) return false;
    backupBusy = true;
    _restoringData = true;
    notifyListeners();
    try {
      await audioHandler.stop();
      _experienceRefreshTimer?.cancel();
      _experienceRefreshPending = false;
      await _experienceRefreshDone?.future;
      await _playbackSessionSaved?.future;
      final result = await _backupService.restoreBackup();
      if (result == null) return false;
      final searchTerm = searchResults.query;
      _searchGeneration++;
      _homeSmartPlayGeneration++;
      _homeSmartPlayDayKey = null;
      _homeSmartPlayTracks = const [];
      _homeSmartPlaySelectedIds.clear();
      audioHandler.setTrackLibrary(const []);
      currentSong = null;
      currentLibraryTrack = null;
      await _loadListeningPreference();
      await refresh();
      await searchLibrary(searchTerm);
      await _reloadScanRoots();
      await _refreshBackupState();
      _emitUiMessage('数据恢复成功；如音乐目录权限失效，请重新选择原目录');
      return true;
    } catch (exception) {
      _emitUiMessage('恢复失败：$exception');
      return false;
    } finally {
      _restoringData = false;
      backupBusy = false;
      notifyListeners();
    }
  }

  Future<void> snoozeBackupReminder() async {
    await _backupService.snoozeReminder(_now());
    backupReminderDue = false;
    notifyListeners();
  }

  Future<void> _refreshBackupState() async {
    lastSuccessfulBackupAt = await _backupService.lastSuccessfulBackupAt();
    final hasUserPlaylist = playlistSummaries.any(
      (playlist) =>
          playlist.playlist.playlistId !=
          PlaylistRepository.manualOnlyPlaylistId,
    );
    backupReminderDue = await _backupService.reminderDue(
      hasMeaningfulData: libraryCounts.likedCount > 0 || hasUserPlaylist,
      now: _now(),
    );
    if (!_disposed) notifyListeners();
  }

  Future<void> refreshExperience() async {
    experienceLoading = true;
    notifyListeners();
    try {
      await _reloadExperienceData();
    } catch (exception, stackTrace) {
      debugPrint('刷新音乐体验数据失败，继续使用已有内容：$exception');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      experienceLoading = false;
      notifyListeners();
    }
  }

  void markSmartPlayVisibleTracks(Iterable<String> ids) {
    final poolIds = _homeSmartPlayTracks
        .map((track) => track.track.trackId)
        .toSet();
    final visibleIds = ids.where(poolIds.contains).toSet();
    // Pulling at the top can scroll the pager offscreen. Keep the last page
    // actually seen so the refresh still brings new songs into that page.
    if (visibleIds.isEmpty) return;
    _homeSmartPlayVisibleIds = visibleIds;
    _homeSmartPlayViewedIds.addAll(_homeSmartPlayVisibleIds);
  }

  Future<void> refreshHomeRecommendations() =>
      _homeRecommendationRefresh ??= _refreshHomeRecommendations().whenComplete(
        () => _homeRecommendationRefresh = null,
      );

  Future<void> _refreshHomeRecommendations() async {
    try {
      await refreshExperience();
      if (_disposed) return;
      final before = _homeSmartPlayTracks;
      if (before.isEmpty) {
        _emitUiMessage('暂无可推荐歌曲，请先添加本地音乐');
        return;
      }
      final now = _now();
      final generation = ++_homeSmartPlayGeneration;
      final nextSerial = _homeSmartPlayRefreshSerial + 1;
      final selectedIds = {
        ..._homeSmartPlaySelectedIds,
        for (final track in recentlyPlayedTracks)
          if (track.stats.lastPlayedAt?.year == now.year &&
              track.stats.lastPlayedAt?.month == now.month &&
              track.stats.lastPlayedAt?.day == now.day)
            track.track.trackId,
      };
      final refreshed = await _homeSmartPlayPool.refreshAsync(
        library: libraryTracks,
        current: before,
        now: now,
        refreshKey: '$_homeSmartPlayDayKey-refresh-$nextSerial',
        preference: listeningPreference,
        behaviorStrength: _smartPlayBehaviorStrength(
          await _playbackHistoryRepository.validEventCount(),
        ),
        behaviorSignals: _recommendationBehaviorSignals,
        viewedTrackIds: Set.of(_homeSmartPlayViewedIds),
        selectedTrackIds: selectedIds,
        visibleTrackIds: _homeSmartPlayVisibleIds.isEmpty
            ? before.take(3).map((track) => track.track.trackId).toSet()
            : Set.of(_homeSmartPlayVisibleIds),
        currentTrackId: currentLibraryTrack?.track.trackId,
      );
      if (_disposed || generation != _homeSmartPlayGeneration) return;
      final eligible = {
        for (final track in RecommendationEligibility.filter(libraryTracks))
          track.track.trackId: track,
      };
      final previousSerial = _homeSmartPlayRefreshSerial;
      _homeSmartPlayTracks = List.unmodifiable(
        refreshed
            .map((track) => eligible[track.track.trackId])
            .whereType<LibraryTrack>(),
      );
      _homeSmartPlayRefreshSerial = nextSerial;
      try {
        await _persistHomeSmartPlayPool();
      } catch (_) {
        if (generation == _homeSmartPlayGeneration) {
          _homeSmartPlayTracks = before;
          _homeSmartPlayRefreshSerial = previousSerial;
        }
        rethrow;
      }
      if (_disposed || generation != _homeSmartPlayGeneration) return;
      notifyListeners();
      final previousIds = before.map((track) => track.track.trackId).toSet();
      final changed = _homeSmartPlayTracks
          .where((track) => !previousIds.contains(track.track.trackId))
          .length;
      _emitUiMessage(changed > 0 ? '已更新 $changed 首智能播放歌曲' : '已刷新，暂时没有更多合适的新歌曲');
    } catch (exception) {
      if (!_disposed) _emitUiMessage('刷新失败，已保留原有推荐，请稍后重试');
    }
  }

  void _scheduleExperienceRefresh() {
    if (_restoringData) return;
    _experienceRefreshPending = true;
    if (_disposed) return;
    _experienceRefreshTimer?.cancel();
    // A manual skip finishes one event and immediately starts another. Merge
    // those writes into one lightweight summary refresh after playback has
    // already responded to the user.
    _experienceRefreshTimer = Timer(const Duration(milliseconds: 900), () {
      _experienceRefreshTimer = null;
      if (!_experienceRefreshRunning && !_disposed) {
        unawaited(_refreshExperienceAfterHistoryChange());
      }
    });
  }

  Future<void> refreshPlaybackExperience() async {
    if (_disposed || _restoringData) return;
    _experienceRefreshTimer?.cancel();
    _experienceRefreshTimer = null;
    _experienceRefreshPending = true;
    if (_experienceRefreshRunning) return;
    await _refreshExperienceAfterHistoryChange();
  }

  Future<void> _refreshExperienceAfterHistoryChange() async {
    _experienceRefreshRunning = true;
    _experienceRefreshDone = Completer<void>();
    try {
      while (_experienceRefreshPending && !_disposed) {
        _experienceRefreshPending = false;
        try {
          await _reloadPlaybackExperienceData();
          if (!_disposed) notifyListeners();
        } catch (exception, stackTrace) {
          debugPrint('播放记录刷新失败，继续使用已有内容：$exception');
          debugPrintStack(stackTrace: stackTrace);
        }
      }
    } finally {
      _experienceRefreshRunning = false;
      _experienceRefreshDone?.complete();
      _experienceRefreshDone = null;
    }
  }

  Future<void> _reloadExperienceData() async {
    final values = await Future.wait<Object>([
      _libraryRepository.counts(),
      _libraryRepository.recentlyAddedTracks(limit: 9),
      _libraryRepository.recentlyPlayedTracks(limit: 9),
      _libraryRepository.likedTracks(limit: 8),
      _libraryRepository.mostPlayedTracks(limit: 8),
      _libraryRepository.artists(),
      _libraryRepository.albums(),
      _libraryRepository.folders(),
      _playlistRepository.playlists(),
      _musicArchiveRepository.load(_now()),
      _playbackHistoryRepository.recommendationSignals(now: _now()),
      _playlistRepository.covers(),
    ]);
    libraryCounts = values[0] as LibraryCounts;
    recentlyAddedTracks = values[1] as List<LibraryTrack>;
    recentlyPlayedTracks = values[2] as List<LibraryTrack>;
    likedTracks = values[3] as List<LibraryTrack>;
    mostPlayedTracks = values[4] as List<LibraryTrack>;
    artistSummaries = values[5] as List<ArtistLibrarySummary>;
    albumSummaries = values[6] as List<AlbumLibrarySummary>;
    libraryFolders = values[7] as List<LibraryFolder>;
    playlistSummaries = values[8] as List<PlaylistLibrarySummary>;
    musicArchive = values[9] as MusicArchiveSnapshot;
    _recommendationBehaviorSignals =
        values[10] as Map<String, RecommendationBehaviorSignal>;
    playlistCovers = values[11] as Map<String, ArtworkReference>;
    _rebuildHomeExperience();
    await _loadOrBuildHomeSmartPlayPool();
  }

  Future<void> _reloadPlaybackExperienceData() async {
    final values = await Future.wait<Object>([
      _libraryRepository.counts(),
      _libraryRepository.recentlyPlayedTracks(limit: 9),
      _libraryRepository.mostPlayedTracks(limit: 8),
      _musicArchiveRepository.load(_now()),
      _playbackHistoryRepository.recommendationSignals(now: _now()),
    ]);
    libraryCounts = values[0] as LibraryCounts;
    recentlyPlayedTracks = values[1] as List<LibraryTrack>;
    mostPlayedTracks = values[2] as List<LibraryTrack>;
    musicArchive = values[3] as MusicArchiveSnapshot;
    _recommendationBehaviorSignals =
        values[4] as Map<String, RecommendationBehaviorSignal>;
    _rebuildHomeExperience();
    await _loadOrBuildHomeSmartPlayPool();
  }

  Future<void> _loadOrBuildHomeSmartPlayPool({bool force = false}) async {
    final generationAtStart = _homeSmartPlayGeneration;
    final eligible = RecommendationEligibility.filter(libraryTracks);
    if (eligible.isEmpty) {
      _homeSmartPlayGeneration++;
      _homeSmartPlayTracks = const [];
      _homeSmartPlayDayKey = null;
      return;
    }

    final now = _now();
    final unsuppressed = eligible
        .where(
          (track) =>
              !(_recommendationBehaviorSignals[track.track.trackId]
                      ?.isTemporarilySuppressedAt(now) ??
                  false),
        )
        .toList(growable: false);
    final candidates = unsuppressed.isEmpty ? eligible : unsuppressed;
    final dayKey =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final byId = {for (final track in candidates) track.track.trackId: track};
    final target = min(HomeSmartPlayPool.trackCount, candidates.length);
    final minimumRestored = min(24, target);
    final validEventCount = await _playbackHistoryRepository.validEventCount();
    if (_disposed || generationAtStart != _homeSmartPlayGeneration) return;
    final behaviorStrength = _smartPlayBehaviorStrength(validEventCount);

    List<LibraryTrack> restore(Iterable<String> ids) {
      final restored = <LibraryTrack>[];
      final seen = <String>{};
      for (final id in ids) {
        final track = byId[id];
        if (track != null && seen.add(id)) restored.add(track);
        if (restored.length == target) break;
      }
      return restored;
    }

    if (!force && _homeSmartPlayDayKey == dayKey) {
      final restored = restore(
        _homeSmartPlayTracks.map((track) => track.track.trackId),
      );
      if (restored.length >= minimumRestored) {
        _homeSmartPlayTracks = List.unmodifiable(restored);
        return;
      }
    }

    final generation = ++_homeSmartPlayGeneration;
    final preferences = await SharedPreferences.getInstance();
    final previousSuggestedIds = <String>{};
    if (_disposed || generation != _homeSmartPlayGeneration) return;
    if (!force) {
      try {
        final raw = preferences.getString(_homeSmartPlayPoolKey);
        final decoded = raw == null ? null : jsonDecode(raw);
        if (decoded is Map) {
          final storedIds = decoded['trackIds'];
          if (storedIds is List) {
            previousSuggestedIds.addAll(storedIds.map((id) => '$id'));
            final restored = restore(storedIds.map((id) => '$id'));
            if (decoded['date'] == dayKey &&
                decoded['algorithmVersion'] ==
                    HomeSmartPlayPool.algorithmVersion &&
                restored.length >= minimumRestored) {
              _homeSmartPlayTracks = List.unmodifiable(restored);
              _homeSmartPlayDayKey = dayKey;
              _homeSmartPlayRefreshSerial =
                  decoded['refreshSerial'] is int &&
                      decoded['refreshSerial'] >= 0
                  ? decoded['refreshSerial'] as int
                  : 0;
              return;
            }
          }
        }
      } catch (_) {
        // Invalid lightweight cache is rebuilt below; library data is intact.
      }
    }

    final generated = await _homeSmartPlayPool.buildAsync(
      library: candidates,
      now: now,
      dayKey: dayKey,
      preference: listeningPreference,
      behaviorStrength: behaviorStrength,
      behaviorSignals: _recommendationBehaviorSignals,
      previouslySuggestedTrackIds: previousSuggestedIds,
    );
    if (_disposed || generation != _homeSmartPlayGeneration) return;
    final currentEligible = {
      for (final track in RecommendationEligibility.filter(libraryTracks))
        track.track.trackId: track,
    };
    _homeSmartPlayTracks = List.unmodifiable(
      generated
          .map((track) => currentEligible[track.track.trackId])
          .whereType<LibraryTrack>(),
    );
    _homeSmartPlayDayKey = dayKey;
    _homeSmartPlayRefreshSerial = 0;
    _homeSmartPlayViewedIds.clear();
    _homeSmartPlaySelectedIds.clear();
    _homeSmartPlayVisibleIds = {};
    await _persistHomeSmartPlayPool();
  }

  Future<void> _persistHomeSmartPlayPool() async {
    final payload = jsonEncode({
      'date': _homeSmartPlayDayKey,
      'refreshSerial': _homeSmartPlayRefreshSerial,
      'algorithmVersion': HomeSmartPlayPool.algorithmVersion,
      'trackIds': _homeSmartPlayTracks
          .map((track) => track.track.trackId)
          .toList(),
    });
    final saved = await (await SharedPreferences.getInstance()).setString(
      _homeSmartPlayPoolKey,
      payload,
    );
    if (!saved) throw StateError('智能播放推荐池保存失败');
  }

  double _smartPlayBehaviorStrength(int validEventCount) {
    if (validEventCount <= 0) return 0;
    return sqrt(validEventCount / 100).clamp(0, 1).toDouble();
  }

  void _rebuildHomeExperience() {
    _homeExperience = HomeExperience.compose(
      liked: likedTracks,
      mostPlayed: mostPlayedTracks,
      recentlyPlayed: recentlyPlayedTracks,
      recentlyAdded: recentlyAddedTracks,
      artists: artistSummaries,
      allTracks: libraryTracks,
    );
  }

  Future<void> searchLibrary(String value) async {
    final generation = ++_searchGeneration;
    final term = value.trim();
    if (term.isEmpty) {
      searchResults = LibrarySearchResults.empty('');
      searchLoading = false;
      searchError = null;
      notifyListeners();
      return;
    }
    searchLoading = true;
    searchError = null;
    notifyListeners();
    try {
      final results = await _librarySearchRepository.search(term);
      if (generation != _searchGeneration) return;
      searchResults = results;
    } catch (_) {
      if (generation != _searchGeneration) return;
      searchResults = LibrarySearchResults.empty(term);
      searchError = '搜索暂时不可用，请稍后重试。';
    } finally {
      if (generation == _searchGeneration) {
        searchLoading = false;
        notifyListeners();
      }
    }
  }

  Future<List<LibraryTrack>> tracksForArtist(String artistId) =>
      _libraryRepository.tracksForArtist(artistId);

  Future<List<LibraryTrack>> tracksForAlbum(String albumId) =>
      _libraryRepository.tracksForAlbum(albumId);

  Future<List<AlbumLibrarySummary>> albumsForArtist(String artistId) =>
      _libraryRepository.albums(artistId: artistId);

  Future<List<LibraryTrack>> tracksForArtistSummary(
    ArtistLibrarySummary artist,
  ) => _libraryRepository.tracksForArtists(artist.allArtistIds);

  Future<List<AlbumLibrarySummary>> albumsForArtistSummary(
    ArtistLibrarySummary artist,
  ) => _libraryRepository.albums(artistIds: artist.allArtistIds);

  Future<List<LibraryTrack>> tracksForFolder(LibraryFolder folder) =>
      _libraryRepository.tracksForFolder(
        folder.scanRootId,
        folder.relativePath,
      );

  Future<List<LibraryTrack>> directTracksForFolder(LibraryFolder folder) =>
      _libraryRepository.tracksForFolder(
        folder.scanRootId,
        folder.relativePath,
        recursive: false,
      );

  Future<List<LibraryFolder>> childFolders(LibraryFolder folder) =>
      _libraryRepository.folders(
        scanRootId: folder.scanRootId,
        parentPath: folder.relativePath,
      );

  Future<List<LibraryTrack>> tracksForPlaylist(String playlistId) =>
      _libraryRepository.tracksForPlaylist(playlistId);

  Future<List<LibraryTrack>> allLikedTracks() =>
      _libraryRepository.likedTracks();

  Future<TrackLyrics?> lyricsForTrack(String trackId) =>
      _lyricsService.loadForTrack(trackId);

  Future<void> createPlaylist(String name, {String? coverPath}) async {
    await _playlistRepository.create(name, coverPath: coverPath);
    playlistSummaries = await _playlistRepository.playlists();
    playlistCovers = await _playlistRepository.covers();
    notifyListeners();
    unawaited(_refreshBackupState());
  }

  Future<Set<String>> playlistIdsForTrack(String trackId) =>
      _playlistRepository.playlistIdsForTrack(trackId);

  Future<void> setTrackPlaylistMembership(
    String playlistId,
    LibraryTrack track,
    bool included,
  ) async {
    await _playlistRepository.setTrack(
      playlistId,
      track.track.trackId,
      included,
    );
    playlistSummaries = await _playlistRepository.playlists();
    notifyListeners();
  }

  Future<void> setTrackManualOnly(LibraryTrack track, bool manualOnly) async {
    final trackId = track.track.trackId;
    await _playlistRepository.setManualOnly(trackId, manualOnly);
    await _reloadV4Library();
    if (currentLibraryTrack?.track.trackId == trackId) {
      final refreshed = libraryTracks.where(
        (item) => item.track.trackId == trackId,
      );
      currentLibraryTrack = refreshed.isEmpty ? null : refreshed.first;
    }
    await _reloadExperienceData();
    final activeSearch = searchResults.query.trim();
    if (activeSearch.isNotEmpty) {
      searchResults = await _librarySearchRepository.search(activeSearch);
      searchError = null;
    }
    _emitUiMessage(manualOnly ? '已设为仅手动播放' : '已恢复参与智能播放');
    notifyListeners();
  }

  Future<void> createPlaylistWithTrack(
    String name,
    LibraryTrack track, {
    String? coverPath,
  }) async {
    final playlist = await _playlistRepository.create(
      name,
      coverPath: coverPath,
    );
    await _playlistRepository.addTracks(playlist.playlistId, [
      track.track.trackId,
    ]);
    playlistSummaries = await _playlistRepository.playlists();
    playlistCovers = await _playlistRepository.covers();
    notifyListeners();
    unawaited(_refreshBackupState());
    _emitUiMessage('已加入「${playlist.name}」');
  }

  Future<void> deletePlaylist(String playlistId) async {
    await _playlistRepository.delete(playlistId);
    playlistCovers = await _playlistRepository.covers();
    categories = await _database.categories();
    playlistSummaries = await _playlistRepository.playlists();
    notifyListeners();
  }

  Future<void> addTrackToPlaylist(String playlistId, LibraryTrack track) async {
    await _playlistRepository.addTracks(playlistId, [track.track.trackId]);
    playlistSummaries = await _playlistRepository.playlists();
    notifyListeners();
  }

  Future<void> playLibraryTrack(LibraryTrack track) async {
    await playTrackCollection(
      libraryTracks,
      contextType: 'library',
      startTrack: track,
    );
  }

  Future<void> playHomeCollection(
    List<LibraryTrack> tracks, {
    required String contextType,
  }) async {
    if (contextType != 'home_quick_start') {
      final playable = tracks.where((track) => track.isPlayable).toList();
      if (playable.isEmpty) return;
      await playTrackCollection(playable, contextType: contextType);
      return;
    }

    if (homeQuickStartActive) return;
    final selected = _homeQuickStartRadio.select(
      library: _homeQuickStartCandidates(fallback: tracks),
      count: HomeQuickStartRadio.initialTrackCount,
      now: _now(),
      preference: listeningPreference,
      avoidFirstTrackId: _lastHomeQuickStartFirstTrackId,
      deEmphasizedTrackIds: _homeSmartPlayTracks
          .map((track) => track.track.trackId)
          .toSet(),
      previousTracks: playbackHistory.take(3).toList().reversed.toList(),
      behaviorSignals: _recommendationBehaviorSignals,
    );
    if (selected.isEmpty) return;
    _lastHomeQuickStartFirstTrackId = selected.first.track.trackId;
    await playTrackCollection(
      selected,
      contextType: contextType,
      contextId: '$_homeQuickStartDayKey-${++_homeQuickStartSessionSerial}',
      startTrack: selected.first,
      manuallySelected: false,
    );
  }

  List<LibraryTrack> _homeQuickStartCandidates({
    required List<LibraryTrack> fallback,
  }) {
    final base = libraryTracks.isEmpty ? fallback : libraryTracks;
    final tracks = <String, LibraryTrack>{
      for (final track in base) track.track.trackId: track,
    };
    for (final source in [
      likedTracks,
      recentlyPlayedTracks,
      mostPlayedTracks,
    ]) {
      for (final track in source) {
        if (tracks.containsKey(track.track.trackId)) {
          tracks[track.track.trackId] = track;
        }
      }
    }
    return tracks.values.toList(growable: false);
  }

  Future<void> _refillHomeQuickStartIfNeeded(
    PlaybackQueueSnapshot snapshot,
  ) async {
    if (_disposed ||
        _restoringData ||
        _homeQuickStartRefillRunning ||
        snapshot.currentIndex < 0 ||
        snapshot.upcoming.length > HomeQuickStartRadio.refillThreshold) {
      return;
    }
    _homeQuickStartRefillRunning = true;
    final sessionId = snapshot.context.id;
    try {
      await refreshPlaybackExperience();
      if (_restoringData) return;
      final latest = playbackQueue;
      if (_disposed ||
          latest.context.type != 'home_quick_start' ||
          latest.context.id != sessionId ||
          latest.upcoming.length > HomeQuickStartRadio.refillThreshold) {
        return;
      }
      final usedTrackIds = latest.entries
          .map((entry) => entry.track.track.trackId)
          .toSet();
      final previousTracks = latest.currentIndex < 0
          ? const <LibraryTrack>[]
          : latest.entries
                .take(latest.currentIndex + 1)
                .map((entry) => entry.track)
                .toList(growable: false);
      final additions = _homeQuickStartRadio.select(
        library: _homeQuickStartCandidates(fallback: const []),
        count: HomeQuickStartRadio.refillTrackCount,
        now: _now(),
        preference: listeningPreference,
        excludingTrackIds: usedTrackIds,
        deEmphasizedTrackIds: _homeSmartPlayTracks
            .map((track) => track.track.trackId)
            .toSet(),
        previousTracks: previousTracks,
        behaviorSignals: _recommendationBehaviorSignals,
      );
      if (additions.isNotEmpty) {
        await audioHandler.addTracksToQueue(additions);
      }
    } finally {
      _homeQuickStartRefillRunning = false;
    }
  }

  String get _homeQuickStartDayKey {
    final day = _now();
    return '${day.year.toString().padLeft(4, '0')}'
        '${day.month.toString().padLeft(2, '0')}'
        '${day.day.toString().padLeft(2, '0')}';
  }

  Future<LibraryTrack?> playHomeRandom() async {
    final playable = RecommendationEligibility.filter(libraryTracks)
        .toList(growable: true);
    if (playable.isEmpty) return null;
    playable.shuffle(_homeRandom);
    final selected = playable.first;
    await playTrackCollection(
      playable,
      contextType: 'home_random',
      startTrack: selected,
      manuallySelected: false,
    );
    _emitUiMessage('随机播放 · ${selected.track.title}');
    return selected;
  }

  Future<void> playTrackCollection(
    List<LibraryTrack> tracks, {
    required String contextType,
    String? contextId,
    LibraryTrack? startTrack,
    bool manuallySelected = true,
  }) async {
    if (_restoringData) return;
    final playable = tracks.where((track) => track.isPlayable).toList();
    if (playable.isEmpty) return;
    final selected = startTrack == null
        ? playable.first
        : playable.firstWhere(
            (track) => track.track.trackId == startTrack.track.trackId,
            orElse: () => playable.first,
          );
    final context = PlaybackContext(type: contextType, id: contextId);
    if (contextType == 'home_smart_play' && manuallySelected) {
      _homeSmartPlaySelectedIds.add(selected.track.trackId);
    }
    _restoredHomeQuickStartWithoutQueue = false;
    // Keep presentation routing synchronous with the user's latest action.
    // The queue stream is asynchronous and can briefly still contain the
    // previous source (for example home quick start) on a real device.
    _activePlaybackContext = context;
    audioHandler.setTrackLibrary(playable, context: context);
    currentLibraryTrack = selected;
    // Make navigation responsive even when opening a large FLAC through SAF
    // takes a moment. The player page can render immediately while just_audio
    // finishes loading the actual file in the background.
    currentSong = LegacySongCompatibility.libraryTrackToLegacySong(selected);
    _scheduleNotifyListeners();
    final sameLoadedTrack =
        audioHandler.mediaItem.value?.id == selected.track.trackId;
    if (sameLoadedTrack) {
      if (!player.playing) await audioHandler.play();
      return;
    }
    await audioHandler.playTrack(
      selected,
      manuallySelected: manuallySelected,
      context: context,
    );
    // Re-assert the source after the asynchronous media load. A queued
    // snapshot from the previous context can otherwise arrive while
    // setAudioSource is awaiting the real file and briefly route the newly
    // opened player to the wrong presentation on a physical device.
    _activePlaybackContext = context;
    _scheduleNotifyListeners();
  }

  void _scheduleNotifyListeners() {
    if (_disposed || _notifyTimer?.isActive == true) return;
    _notifyTimer = Timer(Duration.zero, () {
      _notifyTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> playNext(LibraryTrack track) => audioHandler.playNext(track);

  Future<void> addToQueue(LibraryTrack track) => audioHandler.addToQueue(track);

  Future<void> moveUpcoming(int oldIndex, int newIndex) =>
      audioHandler.moveUpcoming(oldIndex, newIndex);

  Future<void> removeQueueEntry(String entryId) =>
      audioHandler.removeQueueEntry(entryId);

  Future<void> clearUpcoming() => audioHandler.clearUpcoming();

  Future<void> playQueueEntry(String entryId) =>
      audioHandler.playQueueEntry(entryId);

  Future<void> toggleTrackLiked(LibraryTrack track) async {
    final trackId = track.track.trackId;
    await _libraryRepository.setLiked(trackId, !track.preference.liked);
    await _reloadV4Library();
    if (currentLibraryTrack?.track.trackId == trackId) {
      final refreshed = libraryTracks.where(
        (item) => item.track.trackId == trackId,
      );
      currentLibraryTrack = refreshed.isEmpty ? null : refreshed.first;
    }
    await _reloadExperienceData();
    final activeSearch = searchResults.query.trim();
    if (activeSearch.isNotEmpty) {
      searchResults = await _librarySearchRepository.search(activeSearch);
      searchError = null;
    }
    notifyListeners();
  }

  Future<void> requestMetadata(Song song) async {
    if (_legacyTrackById.containsKey(song.id) ||
        _manualOverrideIds.contains(song.id) ||
        _enrichingIds.contains(song.id) ||
        _enrichmentCompleted.contains(song.id)) {
      return;
    }
    _enrichingIds.add(song.id);
    try {
      final enriched = await _metadataService.enrich(song);
      final index = songs.indexWhere((item) => item.id == song.id);
      if (index >= 0 && enriched != songs[index]) {
        final updated = List<Song>.of(songs)..[index] = enriched;
        songs = List.unmodifiable(updated);
        if (currentSong?.id == enriched.id) currentSong = enriched;
        audioHandler.setLibrary(songs);
        notifyListeners();
      }
    } finally {
      _enrichingIds.remove(song.id);
      _enrichmentCompleted.add(song.id);
    }
  }

  Future<void> editSongInfo(
    Song song, {
    required String title,
    required String artist,
    required String album,
  }) async {
    final safeTitle = title.trim().isEmpty ? '未知歌曲' : title.trim();
    final safeArtist = artist.trim().isEmpty ? '未知歌手' : artist.trim();
    final safeAlbum = album.trim().isEmpty ? '未知专辑' : album.trim();
    final libraryTrack = _legacyTrackById[song.id];
    if (libraryTrack == null) {
      await _database.saveSongOverride(
        song.id,
        title: safeTitle,
        artist: safeArtist,
        album: safeAlbum,
      );
    } else {
      await _libraryRepository.saveDisplayOverride(
        libraryTrack.track.trackId,
        title: safeTitle,
        artist: safeArtist,
        album: safeAlbum,
      );
      await _reloadV4Library();
      final editedIndex = songs.indexWhere((item) => item.id == song.id);
      final edited = editedIndex < 0 ? null : songs[editedIndex];
      if (currentSong?.id == song.id && edited != null) currentSong = edited;
      notifyListeners();
      return;
    }
    _manualOverrideIds.add(song.id);
    final index = songs.indexWhere((item) => item.id == song.id);
    if (index >= 0) {
      final edited = songs[index].copyWith(
        title: safeTitle,
        artist: safeArtist,
        album: safeAlbum,
      );
      final updated = List<Song>.of(songs)..[index] = edited;
      songs = List.unmodifiable(updated);
      if (currentSong?.id == song.id) currentSong = edited;
      audioHandler.setLibrary(songs);
      notifyListeners();
    }
  }

  Future<DuplicateCleanupResult> cleanupDuplicates() async {
    final result = await _platform.cleanupDuplicates();
    await _database.removeSongReferences(result.removedIds);
    await refresh();
    return result;
  }

  Future<int> importFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const [
        'mp3',
        'flac',
        'wav',
        'm4a',
        'aac',
        'ogg',
        'opus',
      ],
    );
    if (result == null) return 0;
    final paths = result.paths.whereType<String>().toList();
    final count = await _platform.importMusic(paths);
    await refresh();
    return count;
  }

  void search(String value) {
    query = value;
    notifyListeners();
  }

  Future<void> playSong(Song song) async {
    currentSong = song;
    _activePlaybackContext = PlaybackContext.library;
    notifyListeners();
    final libraryTrack = _legacyTrackById[song.id];
    if (libraryTrack == null) {
      await audioHandler.playSong(song);
    } else {
      await audioHandler.playTrack(libraryTrack);
    }
  }

  Future<void> setPlaybackMode(PlaybackMode mode) async {
    await audioHandler.setPlaybackMode(mode);
    notifyListeners();
  }

  Future<void> setRepeatCount(int count) async {
    await audioHandler.setRepeatCount(count);
    notifyListeners();
  }

  Future<void> togglePlay() async {
    if (_restoringData) return;
    if (player.playing) {
      await audioHandler.pause();
    } else if (currentSong != null) {
      await audioHandler.play();
    }
  }

  Future<void> next() async {
    if (_restoringData) return;
    await audioHandler.skipToNext();
  }

  Future<void> previous() async {
    if (_restoringData) return;
    await audioHandler.skipToPrevious();
  }

  Future<void> toggleFavorite(Song song) async {
    final shouldFavorite = !favoriteIds.contains(song.id);
    final libraryTrack = _legacyTrackById[song.id];
    if (libraryTrack == null) {
      await _database.setFavorite(song.id, shouldFavorite);
    } else {
      await _libraryRepository.setLiked(
        libraryTrack.track.trackId,
        shouldFavorite,
      );
    }
    if (shouldFavorite) {
      favoriteIds.add(song.id);
    } else {
      favoriteIds.remove(song.id);
    }
    await _reloadExperienceData();
    notifyListeners();
    unawaited(_refreshBackupState());
  }

  Future<void> createCategory(String name) async {
    if (name.trim().isEmpty) return;
    await _database.createCategory(name);
    await _playlistRepository.synchronizeLegacyCategories();
    categories = await _database.categories();
    notifyListeners();
  }

  Future<Set<int>> categorySongIds(int categoryId) =>
      _database.categorySongIds(categoryId);

  Future<void> setSongInCategory(
    int categoryId,
    int songId,
    bool included,
  ) async {
    await _database.setSongInCategory(categoryId, songId, included);
    final libraryTrack = _legacyTrackById[songId];
    if (libraryTrack != null) {
      await _playlistRepository.setLegacyCategoryTrack(
        categoryId,
        libraryTrack.track.trackId,
        included,
      );
    }
    categories = await _database.categories();
    notifyListeners();
  }

  Future<void> deleteCategory(int categoryId) async {
    await _playlistRepository.deleteLegacyCategoryPlaylist(categoryId);
    await _database.deleteCategory(categoryId);
    categories = await _database.categories();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(savePlaybackState());
    _disposed = true;
    _notifyTimer?.cancel();
    _scanProgressNotifyTimer?.cancel();
    _experienceRefreshTimer?.cancel();
    _sleepTimerTicker?.cancel();
    _playbackSessionTimer?.cancel();
    _playerSubscription?.cancel();
    _songSubscription?.cancel();
    _trackSubscription?.cancel();
    _queueSubscription?.cancel();
    _scanProgressSubscription?.cancel();
    _metadataService.dispose();
    _playbackHistory.dispose();
    if (_ownsScanService) unawaited(_scanService.dispose());
    if (_ownsAudioHandler) unawaited(audioHandler.disposeHandler());
    unawaited(_uiMessageController.close());
    super.dispose();
  }
}
