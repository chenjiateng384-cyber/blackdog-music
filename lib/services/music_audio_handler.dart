import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../models/song.dart';
import '../models/v4/legacy_song_compatibility.dart';
import '../models/v4/library_track.dart';
import '../models/v4/playback.dart';
import 'playback_history_service.dart';
import 'playback_queue.dart';

class MusicAudioHandler extends BaseAudioHandler with SeekHandler {
  MusicAudioHandler({PlaybackQueue? playbackQueue})
    : _playbackQueue = playbackQueue ?? PlaybackQueue() {
    _playbackEventSubscription = player.playbackEventStream.listen((event) {
      _history?.setPlaying(player.playing);
      playbackState.add(_toPlaybackState(event));
    });
    _completionSubscription = player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && !_handlingCompletion) {
        unawaited(_handleCompletion());
      }
    });
  }

  final AudioPlayer player = AudioPlayer();
  final StreamController<Song?> _currentSongController =
      StreamController<Song?>.broadcast();
  final StreamController<LibraryTrack?> _currentTrackController =
      StreamController<LibraryTrack?>.broadcast();
  final StreamController<PlaybackQueueSnapshot> _queueSnapshotController =
      StreamController<PlaybackQueueSnapshot>.broadcast();
  final PlaybackQueue _playbackQueue;
  late final StreamSubscription<PlaybackEvent> _playbackEventSubscription;
  late final StreamSubscription<ProcessingState> _completionSubscription;
  PlaybackHistoryService? _history;
  LibraryTrack? _loadedTrack;
  PlaybackContext _queueContext = PlaybackContext.library;
  List<String> _publishedMediaQueueEntryIds = const [];
  bool _handlingCompletion = false;

  Stream<Song?> get currentSongStream => _currentSongController.stream;
  Stream<LibraryTrack?> get currentTrackStream =>
      _currentTrackController.stream;
  Stream<PlaybackQueueSnapshot> get queueSnapshotStream =>
      _queueSnapshotController.stream;
  List<String> get queueTrackIds => _playbackQueue.trackIds;
  PlaybackMode get playbackMode => _playbackQueue.mode;
  int? get repeatCount => _playbackQueue.repeatCount;
  int? get repeatLeft => _playbackQueue.repeatLeft;
  double get volumePercent => player.volume * 100;
  PlaybackQueueSnapshot get queueSnapshot =>
      _playbackQueue.snapshot(_queueContext);

  void attachPlaybackHistory(PlaybackHistoryService history) {
    _history = history;
  }

  Future<void> preparePlaybackHistory() async {
    await _history?.recoverInterruptedEvents();
  }

  void setLibrary(List<Song> songs) {
    setTrackLibrary(
      songs.map(LegacySongCompatibility.libraryTrackFromLegacySong).toList(),
    );
  }

  void setTrackLibrary(
    List<LibraryTrack> tracks, {
    PlaybackContext context = PlaybackContext.library,
  }) {
    if (_queueContext.type == context.type &&
        _queueContext.id == context.id &&
        _playbackQueue.matchesTracks(tracks)) {
      return;
    }
    _queueContext = context;
    _playbackQueue.setTracks(tracks);
    _broadcastQueue();
  }

  void _broadcastQueue({bool publishMediaQueue = true}) {
    final snapshot = queueSnapshot;
    _queueSnapshotController.add(snapshot);
    if (!publishMediaQueue) return;
    final mediaEntries = _mediaSessionEntries(snapshot);
    _publishedMediaQueueEntryIds = [
      for (final entry in mediaEntries) entry.entryId,
    ];
    queue.add(
      mediaEntries
          .map(
            (entry) =>
                _mediaItemForTrack(entry.track, queueEntryId: entry.entryId),
          )
          .toList(growable: false),
    );
  }

  List<QueueEntry> _mediaSessionEntries(PlaybackQueueSnapshot snapshot) {
    const windowSize = 120;
    if (snapshot.entries.length <= windowSize) return snapshot.entries;
    final current = snapshot.currentIndex;
    if (current < 0) {
      return snapshot.entries.take(windowSize).toList(growable: false);
    }
    final start = (current - 20)
        .clamp(0, snapshot.entries.length - windowSize)
        .toInt();
    return snapshot.entries
        .skip(start)
        .take(windowSize)
        .toList(growable: false);
  }

  void _broadcastSelection() {
    final currentEntryId = _playbackQueue.currentEntry?.entryId;
    _broadcastQueue(
      publishMediaQueue:
          currentEntryId != null &&
          !_publishedMediaQueueEntryIds.contains(currentEntryId),
    );
  }

  Future<void> playSong(Song song) async {
    await playTrack(LegacySongCompatibility.libraryTrackFromLegacySong(song));
  }

  Future<void> playTrack(
    LibraryTrack item, {
    bool manuallySelected = true,
    PlaybackContext? context,
  }) async {
    if (context != null) _queueContext = context;
    _playbackQueue.select(item);
    // Selecting another item does not change the media-session queue. Avoid
    // rebuilding hundreds (eventually 1000+) of MediaItems on every tap.
    _broadcastSelection();
    if (mediaItem.value != null) {
      await _history?.finish(PlaybackEndReason.userSelectedAnother);
    }
    await _loadTrack(
      item,
      manuallySelected: manuallySelected,
      context: _queueContext,
    );
  }

  Future<void> restoreTrack(
    LibraryTrack item, {
    required Duration position,
    PlaybackContext context = PlaybackContext.library,
  }) async {
    final uri = item.playbackUri;
    if (uri == null) return;
    _queueContext = context;
    _playbackQueue.select(item);
    _broadcastSelection();
    final song = LegacySongCompatibility.libraryTrackToLegacySong(item);
    _currentTrackController.add(item);
    _currentSongController.add(song);
    mediaItem.add(_mediaItemForTrack(item));
    await player.setAudioSource(
      AudioSource.uri(Uri.parse(uri)),
      initialPosition: position,
    );
    _loadedTrack = item;
  }

  Future<void> _loadTrack(
    LibraryTrack item, {
    required bool manuallySelected,
    required PlaybackContext context,
  }) async {
    final uri = item.playbackUri;
    if (uri == null) {
      throw StateError('歌曲“${item.track.title}”没有可播放的本地文件。');
    }
    final song = LegacySongCompatibility.libraryTrackToLegacySong(item);
    _currentTrackController.add(item);
    _currentSongController.add(song);
    mediaItem.add(_mediaItemForTrack(item));
    await player.setAudioSource(AudioSource.uri(Uri.parse(uri)));
    _loadedTrack = item;
    await _history?.start(
      item: item,
      manuallySelected: manuallySelected,
      context: context,
      mode: playbackMode,
    );
    try {
      await player.play();
    } catch (_) {
      await _history?.finish(PlaybackEndReason.interrupted);
      rethrow;
    }
  }

  Future<void> setPlaybackMode(PlaybackMode mode) async {
    _playbackQueue.setMode(mode);
    _broadcastQueue();
    playbackState.add(_toPlaybackState(player.playbackEvent));
  }

  Future<void> setRepeatCount(int count) async {
    _playbackQueue.setRepeatCount(count);
    _broadcastQueue();
    playbackState.add(_toPlaybackState(player.playbackEvent));
  }

  Future<void> setVolumePercent(double percent) =>
      player.setVolume(percent.clamp(0, 100).toDouble() / 100);

  Future<void> playNext(LibraryTrack item) async {
    _playbackQueue.insertNext(item);
    _broadcastQueue();
  }

  Future<void> addToQueue(LibraryTrack item) async {
    _playbackQueue.appendAll([item]);
    _broadcastQueue();
  }

  Future<void> addTracksToQueue(Iterable<LibraryTrack> items) async {
    if (_playbackQueue.appendAll(items).isNotEmpty) _broadcastQueue();
  }

  Future<void> moveUpcoming(int oldIndex, int newIndex) async {
    if (_playbackQueue.moveUpcoming(oldIndex, newIndex)) _broadcastQueue();
  }

  Future<void> removeQueueEntry(String entryId) async {
    if (_playbackQueue.removeEntry(entryId)) _broadcastQueue();
  }

  Future<void> clearUpcoming() async {
    if (_playbackQueue.clearUpcoming() > 0) _broadcastQueue();
  }

  Future<void> playQueueEntry(String entryId) async {
    final entry = _playbackQueue.selectEntry(entryId);
    if (entry == null) return;
    await _history?.finish(PlaybackEndReason.userSelectedAnother);
    _broadcastSelection();
    await _loadTrack(
      entry.track,
      manuallySelected: true,
      context: _queueContext,
    );
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      setPlaybackMode(switch (repeatMode) {
        AudioServiceRepeatMode.one => PlaybackMode.repeatOne,
        AudioServiceRepeatMode.all => PlaybackMode.repeatAll,
        _ => PlaybackMode.sequential,
      });

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      setPlaybackMode(
        shuffleMode == AudioServiceShuffleMode.none
            ? PlaybackMode.sequential
            : PlaybackMode.shuffle,
      );

  @override
  Future<void> play() async {
    final history = _history;
    final loadedTrack = _loadedTrack;
    if (history != null && !history.hasActivePlayback && loadedTrack != null) {
      await history.start(
        item: loadedTrack,
        manuallySelected: false,
        context: _queueContext,
        mode: playbackMode,
      );
    }
    try {
      await player.play();
    } catch (_) {
      await history?.finish(PlaybackEndReason.interrupted);
      rethrow;
    }
  }

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() async {
    final next = _playbackQueue.next(automatic: false);
    if (next == null) return;
    _broadcastSelection();
    await _history?.finish(PlaybackEndReason.userSkipped);
    await _loadTrack(next, manuallySelected: false, context: _queueContext);
  }

  @override
  Future<void> skipToPrevious() async {
    if (player.position > const Duration(seconds: 3)) {
      await player.seek(Duration.zero);
      return;
    }
    final previous = _playbackQueue.previous();
    if (previous == null) return;
    _broadcastSelection();
    await _history?.finish(PlaybackEndReason.userSkipped);
    await _loadTrack(previous, manuallySelected: false, context: _queueContext);
  }

  @override
  Future<void> stop() async {
    await _history?.finish(PlaybackEndReason.stopped);
    await player.stop();
    await super.stop();
  }

  Future<void> _handleCompletion() async {
    _handlingCompletion = true;
    try {
      await _history?.finish(PlaybackEndReason.completed);
      final next = _playbackQueue.next(automatic: true);
      if (next == null) {
        await player.stop();
        return;
      }
      _broadcastSelection();
      await _loadTrack(next, manuallySelected: false, context: _queueContext);
    } finally {
      _handlingCompletion = false;
    }
  }

  MediaItem _mediaItemForTrack(LibraryTrack item, {String? queueEntryId}) {
    final track = item.track;
    final cachePath = item.artwork?.cachePath?.trim();
    final contentUri = item.artwork?.contentUri?.trim();
    final artUri = cachePath != null && cachePath.isNotEmpty
        ? Uri.file(cachePath)
        : contentUri != null && contentUri.isNotEmpty
        ? Uri.tryParse(contentUri)
        : null;
    final playbackUri = item.playbackUri;
    final extras = <String, dynamic>{};
    final preferredFile = item.preferredFile;
    if (preferredFile != null) extras['mediaFileId'] = preferredFile.fileId;
    if (playbackUri != null) extras['uri'] = playbackUri;
    if (queueEntryId != null) extras['queueEntryId'] = queueEntryId;
    return MediaItem(
      id: track.trackId,
      title: track.title,
      artist: track.artistDisplay,
      album: track.albumDisplay,
      duration: Duration(milliseconds: track.durationMs),
      artUri: artUri,
      displayTitle: track.title,
      displaySubtitle: track.artistDisplay,
      displayDescription: track.albumDisplay,
      extras: extras,
    );
  }

  int? get _systemQueueIndex {
    final entryId = _playbackQueue.currentEntry?.entryId;
    if (entryId == null) return null;
    final index = _publishedMediaQueueEntryIds.indexOf(entryId);
    return index < 0 ? null : index;
  }

  PlaybackState _toPlaybackState(PlaybackEvent event) => PlaybackState(
    controls: [
      MediaControl.skipToPrevious,
      if (player.playing) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
    ],
    systemActions: const {MediaAction.seek},
    androidCompactActionIndices: const [0, 1, 2],
    processingState: const {
      ProcessingState.idle: AudioProcessingState.idle,
      ProcessingState.loading: AudioProcessingState.loading,
      ProcessingState.buffering: AudioProcessingState.buffering,
      ProcessingState.ready: AudioProcessingState.ready,
      ProcessingState.completed: AudioProcessingState.completed,
    }[player.processingState]!,
    playing: player.playing,
    updatePosition: player.position,
    bufferedPosition: player.bufferedPosition,
    speed: player.speed,
    queueIndex: _systemQueueIndex,
    repeatMode: switch (playbackMode) {
      PlaybackMode.repeatOne => AudioServiceRepeatMode.one,
      PlaybackMode.repeatCount => AudioServiceRepeatMode.one,
      PlaybackMode.repeatAll => AudioServiceRepeatMode.all,
      _ => AudioServiceRepeatMode.none,
    },
    shuffleMode:
        playbackMode == PlaybackMode.shuffle ||
            playbackMode == PlaybackMode.smartShuffle
        ? AudioServiceShuffleMode.all
        : AudioServiceShuffleMode.none,
  );

  Future<void> disposeHandler() async {
    await _history?.finish(PlaybackEndReason.interrupted);
    await _playbackEventSubscription.cancel();
    await _completionSubscription.cancel();
    await _currentSongController.close();
    await _currentTrackController.close();
    await _queueSnapshotController.close();
    await player.dispose();
  }
}
