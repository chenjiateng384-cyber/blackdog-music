import 'library_track.dart';

enum PlaybackMode {
  sequential('sequential'),
  repeatAll('repeatAll'),
  repeatOne('repeatOne'),
  repeatCount('repeatCount'),
  shuffle('shuffle'),
  smartShuffle('smartShuffle');

  const PlaybackMode(this.dbValue);

  final String dbValue;

  static PlaybackMode fromDbValue(String value) => values.firstWhere(
    (mode) => mode.dbValue == value,
    orElse: () => PlaybackMode.sequential,
  );
}

class PlaybackContext {
  const PlaybackContext({required this.type, this.id});

  static const library = PlaybackContext(type: 'library');

  final String type;
  final String? id;

  PlayerPageKind get playerPageKind => switch (type) {
    'home_quick_start' || 'home_random' => PlayerPageKind.crystal,
    _ => PlayerPageKind.immersive,
  };
}

enum PlayerPageKind { crystal, immersive }

enum CrystalPlayerView { artwork, lyrics }

enum ImmersivePlayerView { artwork, lyrics }

class QueueEntry {
  const QueueEntry({required this.entryId, required this.track});

  final String entryId;
  final LibraryTrack track;
}

class PlaybackQueueSnapshot {
  const PlaybackQueueSnapshot({
    required this.entries,
    required this.currentIndex,
    required this.mode,
    required this.context,
    this.repeatCount,
    this.repeatLeft,
  });

  const PlaybackQueueSnapshot.empty()
    : entries = const [],
      currentIndex = -1,
      mode = PlaybackMode.sequential,
      context = PlaybackContext.library,
      repeatCount = null,
      repeatLeft = null;

  final List<QueueEntry> entries;
  final int currentIndex;
  final PlaybackMode mode;
  final PlaybackContext context;
  final int? repeatCount;
  final int? repeatLeft;

  QueueEntry? get current => currentIndex < 0 || currentIndex >= entries.length
      ? null
      : entries[currentIndex];

  List<QueueEntry> get upcoming => currentIndex < 0
      ? entries
      : entries.skip(currentIndex + 1).toList(growable: false);
}

enum PlaybackEndReason {
  completed,
  userSkipped,
  userSelectedAnother,
  stopped,
  interrupted,
}
