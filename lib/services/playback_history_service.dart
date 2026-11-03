import 'dart:async';

import 'package:uuid/uuid.dart';

import '../data/playback_history_repository.dart';
import '../models/v4/library_track.dart';
import '../models/v4/playback.dart';

class PlaybackHistoryService {
  PlaybackHistoryService(
    this._repository, {
    DateTime Function()? now,
    Duration Function()? monotonicNow,
    Uuid? uuid,
    this.onHistoryChanged,
    this.quickSkipThreshold = const Duration(seconds: 60),
    this.completionRatio = 0.9,
    this.checkpointInterval = const Duration(seconds: 15),
  }) : assert(completionRatio > 0 && completionRatio <= 1),
       assert(checkpointInterval > Duration.zero),
       _now = now ?? DateTime.now,
       _monotonicNowOverride = monotonicNow,
       _uuid = uuid ?? const Uuid() {
    _stopwatch.start();
  }

  final PlaybackHistoryRepository _repository;
  final DateTime Function() _now;
  final Duration Function()? _monotonicNowOverride;
  final Uuid _uuid;
  final void Function()? onHistoryChanged;
  final Duration quickSkipThreshold;
  final double completionRatio;
  final Duration checkpointInterval;
  final Stopwatch _stopwatch = Stopwatch();
  _ActivePlayback? _active;
  Timer? _checkpointTimer;
  String? _sessionId;

  Duration get _monotonicNow =>
      _monotonicNowOverride?.call() ?? _stopwatch.elapsed;

  bool get hasActivePlayback => _active != null;
  String? get activeTrackId => _active?.item.track.trackId;
  String? get activeEventId => _active?.eventId;

  Future<void> recoverInterruptedEvents() =>
      _repository.recoverInterruptedEvents(_now());

  Future<void> start({
    required LibraryTrack item,
    required bool manuallySelected,
    required PlaybackContext context,
    required PlaybackMode mode,
  }) async {
    if (_active != null) {
      await finish(PlaybackEndReason.userSelectedAnother);
    }
    final startedAt = _now();
    final eventId = await _repository.beginPlayback(
      item: item,
      startedAt: startedAt,
      manuallySelected: manuallySelected,
      context: context,
      mode: mode,
      sessionId: _sessionId ??= _uuid.v4(),
    );
    _active = _ActivePlayback(eventId: eventId, item: item);
    _checkpointTimer?.cancel();
    _checkpointTimer = Timer.periodic(
      checkpointInterval,
      (_) => unawaited(checkpoint()),
    );
    onHistoryChanged?.call();
  }

  void setPlaying(bool playing) {
    final active = _active;
    if (active == null) return;
    final now = _monotonicNow;
    if (playing && active.runningSince == null) {
      active.runningSince = now;
    } else if (!playing && active.runningSince != null) {
      active.listened += now - active.runningSince!;
      active.runningSince = null;
      unawaited(checkpoint());
    }
  }

  Future<void> checkpoint() async {
    final active = _active;
    if (active == null) return;
    await _repository.checkpointPlayback(
      eventId: active.eventId,
      listenedDuration: _listenedDuration(active),
      updatedAt: _now(),
    );
  }

  Future<void> finish(PlaybackEndReason reason) async {
    final active = _active;
    if (active == null) return;
    setPlaying(false);
    _active = null;
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    final duration = Duration(milliseconds: active.item.track.durationMs);
    final listened = active.listened > duration && duration > Duration.zero
        ? duration
        : active.listened;
    final ratioCompleted =
        duration > Duration.zero &&
        listened.inMilliseconds >=
            (duration.inMilliseconds * completionRatio).round();
    final completed = reason == PlaybackEndReason.completed || ratioCompleted;
    final skipAction =
        reason == PlaybackEndReason.userSkipped ||
        reason == PlaybackEndReason.userSelectedAnother;
    final skipped = skipAction && !completed && listened <= quickSkipThreshold;
    await _repository.finishPlayback(
      eventId: active.eventId,
      endedAt: _now(),
      listenedDuration: listened,
      completed: completed,
      skipped: skipped,
    );
    if (reason == PlaybackEndReason.stopped ||
        reason == PlaybackEndReason.interrupted) {
      _sessionId = null;
    }
    onHistoryChanged?.call();
  }

  Duration _listenedDuration(_ActivePlayback active) {
    final runningSince = active.runningSince;
    if (runningSince == null) return active.listened;
    final running = _monotonicNow - runningSince;
    return active.listened + (running.isNegative ? Duration.zero : running);
  }

  void dispose() {
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    _stopwatch.stop();
  }
}

class _ActivePlayback {
  _ActivePlayback({required this.eventId, required this.item});

  final String eventId;
  final LibraryTrack item;
  Duration listened = Duration.zero;
  Duration? runningSince;
}
