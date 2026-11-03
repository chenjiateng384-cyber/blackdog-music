import 'dart:math';

import '../models/v4/library_track.dart';
import '../models/v4/playback.dart';

abstract interface class SmartPlaybackOrder {
  List<LibraryTrack> buildOrder(
    List<LibraryTrack> tracks, {
    LibraryTrack? current,
  });
}

class PlaybackQueue {
  PlaybackQueue({Random? random, this.smartOrder})
    : _random = random ?? Random();

  final Random _random;
  final SmartPlaybackOrder? smartOrder;
  List<QueueEntry> _source = const [];
  List<QueueEntry> _order = const [];
  int _index = -1;
  int _nextEntryId = 0;
  PlaybackMode _mode = PlaybackMode.sequential;
  int? _repeatCount;
  int? _repeatLeft;

  PlaybackMode get mode => _mode;
  int? get repeatCount => _repeatCount;
  int? get repeatLeft => _repeatLeft;
  int get currentIndex => _index;
  QueueEntry? get currentEntry =>
      _index < 0 || _index >= _order.length ? null : _order[_index];
  LibraryTrack? get current => currentEntry?.track;
  // The order list is already immutable whenever it is assigned.
  List<QueueEntry> get entries => _order;
  List<LibraryTrack> get tracks =>
      _order.map((entry) => entry.track).toList(growable: false);
  List<String> get trackIds =>
      _order.map((entry) => entry.track.track.trackId).toList(growable: false);

  bool matchesTracks(List<LibraryTrack> tracks) {
    var queueIndex = 0;
    for (final track in tracks) {
      if (!track.isPlayable) continue;
      if (queueIndex >= _order.length ||
          _order[queueIndex].track.track.trackId != track.track.trackId) {
        return false;
      }
      queueIndex++;
    }
    return queueIndex == _order.length;
  }

  PlaybackQueueSnapshot snapshot(PlaybackContext context) =>
      PlaybackQueueSnapshot(
        entries: entries,
        currentIndex: _index,
        mode: _mode,
        context: context,
        repeatCount: _repeatCount,
        repeatLeft: _repeatLeft,
      );

  void setTracks(List<LibraryTrack> tracks) {
    final currentTrackId = current?.track.trackId;
    _source = List.unmodifiable(
      tracks.where((item) => item.isPlayable).map(_entryFor),
    );
    _order = _buildOrder(currentTrackId: currentTrackId);
    _index = currentTrackId == null
        ? -1
        : _order.indexWhere(
            (entry) => entry.track.track.trackId == currentTrackId,
          );
    _resetRepeatProgress();
  }

  void setMode(PlaybackMode mode) {
    if (_mode == mode) return;
    final currentEntryId = currentEntry?.entryId;
    _mode = mode;
    if (mode == PlaybackMode.repeatCount) {
      _repeatCount ??= 2;
      _repeatLeft = _repeatCount;
    } else {
      _repeatCount = null;
      _repeatLeft = null;
    }
    _order = _buildOrder(currentEntryId: currentEntryId);
    _index = currentEntryId == null
        ? -1
        : _order.indexWhere((entry) => entry.entryId == currentEntryId);
  }

  void setRepeatCount(int count) {
    if (count < 2 || count > 5) {
      throw RangeError.range(count, 2, 5, 'count');
    }
    final currentEntryId = currentEntry?.entryId;
    _mode = PlaybackMode.repeatCount;
    _repeatCount = count;
    _repeatLeft = count;
    _order = _buildOrder(currentEntryId: currentEntryId);
    _index = currentEntryId == null
        ? _index
        : _order.indexWhere((entry) => entry.entryId == currentEntryId);
  }

  QueueEntry? select(LibraryTrack item) {
    var index = _order.indexWhere(
      (entry) => entry.track.track.trackId == item.track.trackId,
    );
    if (index < 0 && item.isPlayable) {
      final entry = _entryFor(item);
      _source = List.unmodifiable([..._source, entry]);
      _order = List.unmodifiable([..._order, entry]);
      index = _order.length - 1;
    }
    _index = index;
    _resetRepeatProgress();
    return currentEntry;
  }

  QueueEntry? selectEntry(String entryId) {
    final index = _order.indexWhere((entry) => entry.entryId == entryId);
    if (index < 0) return null;
    _index = index;
    _resetRepeatProgress();
    return currentEntry;
  }

  QueueEntry? insertNext(LibraryTrack item) {
    if (!item.isPlayable) return null;
    final entry = _entryFor(item);
    final insertIndex = _index < 0 ? 0 : _index + 1;
    final updated = List<QueueEntry>.of(_order)..insert(insertIndex, entry);
    _order = List.unmodifiable(updated);
    _syncSourceToOrder();
    return entry;
  }

  List<QueueEntry> appendAll(Iterable<LibraryTrack> items) {
    final appended = items
        .where((item) => item.isPlayable)
        .map(_entryFor)
        .toList(growable: false);
    if (appended.isEmpty) return const [];
    _order = List.unmodifiable([..._order, ...appended]);
    _syncSourceToOrder();
    return appended;
  }

  bool moveUpcoming(int oldIndex, int newIndex) {
    final upcomingStart = _index < 0 ? 0 : _index + 1;
    final upcomingCount = _order.length - upcomingStart;
    if (oldIndex < 0 || oldIndex >= upcomingCount) return false;
    if (newIndex < 0 || newIndex >= upcomingCount) return false;
    if (newIndex == oldIndex) return false;
    final updated = List<QueueEntry>.of(_order);
    final entry = updated.removeAt(upcomingStart + oldIndex);
    updated.insert(upcomingStart + newIndex, entry);
    _order = List.unmodifiable(updated);
    _syncSourceToOrder();
    return true;
  }

  bool removeEntry(String entryId) {
    final index = _order.indexWhere((entry) => entry.entryId == entryId);
    if (index < 0 || index <= _index) return false;
    final updated = List<QueueEntry>.of(_order)..removeAt(index);
    _order = List.unmodifiable(updated);
    _syncSourceToOrder();
    return true;
  }

  int clearUpcoming() {
    final start = _index < 0 ? 0 : _index + 1;
    final removed = _order.length - start;
    if (removed <= 0) return 0;
    _order = List.unmodifiable(_order.take(start));
    _syncSourceToOrder();
    return removed;
  }

  LibraryTrack? next({required bool automatic}) {
    if (_order.isEmpty) return null;
    if (_index < 0) {
      _index = 0;
      _resetRepeatProgress();
      return current;
    }
    if (automatic && _mode == PlaybackMode.repeatOne) return current;
    if (automatic && _mode == PlaybackMode.repeatCount) {
      final remaining = _repeatLeft ?? _repeatCount ?? 2;
      if (remaining > 1) {
        _repeatLeft = remaining - 1;
        return current;
      }
      _mode = PlaybackMode.sequential;
      _repeatCount = null;
      _repeatLeft = null;
    }
    if (_index + 1 < _order.length) {
      _index++;
      _resetRepeatProgress();
      return current;
    }
    if (_mode == PlaybackMode.sequential) return null;
    if (_mode == PlaybackMode.repeatAll || _mode == PlaybackMode.repeatOne) {
      _index = 0;
      _resetRepeatProgress();
      return current;
    }
    final previous = currentEntry;
    _order = _buildOrder(currentEntryId: previous?.entryId);
    if (_order.length <= 1) {
      _index = _order.isEmpty ? -1 : 0;
      return current;
    }
    _index = 1;
    _resetRepeatProgress();
    return current;
  }

  LibraryTrack? previous() {
    if (_order.isEmpty) return null;
    if (_index < 0) {
      _index = _order.length - 1;
      _resetRepeatProgress();
      return current;
    }
    if (_index > 0) {
      _index--;
      _resetRepeatProgress();
      return current;
    }
    if (_mode == PlaybackMode.sequential) return null;
    _index = _order.length - 1;
    _resetRepeatProgress();
    return current;
  }

  void _resetRepeatProgress() {
    if (_mode == PlaybackMode.repeatCount) _repeatLeft = _repeatCount;
  }

  QueueEntry _entryFor(LibraryTrack track) =>
      QueueEntry(entryId: 'queue-${++_nextEntryId}', track: track);

  void _syncSourceToOrder() {
    _source = List.unmodifiable(_order);
  }

  List<QueueEntry> _buildOrder({
    String? currentEntryId,
    String? currentTrackId,
  }) {
    if (_mode != PlaybackMode.shuffle && _mode != PlaybackMode.smartShuffle) {
      return List.unmodifiable(_source);
    }
    QueueEntry? current;
    if (currentEntryId != null) {
      final index = _source.indexWhere(
        (entry) => entry.entryId == currentEntryId,
      );
      if (index >= 0) current = _source[index];
    } else if (currentTrackId != null) {
      final index = _source.indexWhere(
        (entry) => entry.track.track.trackId == currentTrackId,
      );
      if (index >= 0) current = _source[index];
    }
    final candidates = _source
        .where((entry) => entry.entryId != current?.entryId)
        .toList(growable: true);
    late List<QueueEntry> ordered;
    if (_mode == PlaybackMode.smartShuffle && smartOrder != null) {
      final tracks = smartOrder!.buildOrder(
        candidates.map((entry) => entry.track).toList(growable: false),
        current: current?.track,
      );
      final remaining = List<QueueEntry>.of(candidates);
      ordered = <QueueEntry>[];
      for (final track in tracks) {
        final index = remaining.indexWhere(
          (entry) => identical(entry.track, track),
        );
        if (index >= 0) ordered.add(remaining.removeAt(index));
      }
      ordered.addAll(remaining);
    } else {
      candidates.shuffle(_random);
      ordered = candidates;
    }
    return List.unmodifiable([?current, ...ordered]);
  }
}
