class TrackPreference {
  const TrackPreference({
    required this.trackId,
    required this.liked,
    required this.recommendationExcluded,
    required this.updatedAt,
    this.likedAt,
    this.exclusionReason,
  });

  final String trackId;
  final bool liked;
  final DateTime? likedAt;
  final bool recommendationExcluded;
  final String? exclusionReason;
  final DateTime updatedAt;

  Map<String, Object?> toMap() => {
    'track_id': trackId,
    'liked': liked ? 1 : 0,
    'liked_at': likedAt?.millisecondsSinceEpoch,
    'recommendation_excluded': recommendationExcluded ? 1 : 0,
    'exclusion_reason': exclusionReason,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory TrackPreference.fromMap(Map<String, Object?> map) => TrackPreference(
    trackId: map['track_id']! as String,
    liked: map['liked'] == 1,
    likedAt: _date(map['liked_at']),
    recommendationExcluded: map['recommendation_excluded'] == 1,
    exclusionReason: map['exclusion_reason'] as String?,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
  );

  factory TrackPreference.empty(String trackId, DateTime updatedAt) =>
      TrackPreference(
        trackId: trackId,
        liked: false,
        recommendationExcluded: false,
        updatedAt: updatedAt,
      );
}

class TrackStats {
  const TrackStats({
    required this.trackId,
    required this.playCount,
    required this.completedCount,
    required this.skipCount,
    required this.manuallySelectedCount,
    required this.totalPlayDurationMs,
    required this.updatedAt,
    this.lastPlayedAt,
    this.lastSkippedAt,
    this.firstPlayedAt,
  });

  final String trackId;
  final int playCount;
  final int completedCount;
  final int skipCount;
  final int manuallySelectedCount;
  final int totalPlayDurationMs;
  final DateTime? lastPlayedAt;
  final DateTime? lastSkippedAt;
  final DateTime? firstPlayedAt;
  final DateTime updatedAt;

  Map<String, Object?> toMap() => {
    'track_id': trackId,
    'play_count': playCount,
    'completed_count': completedCount,
    'skip_count': skipCount,
    'manually_selected_count': manuallySelectedCount,
    'total_play_duration_ms': totalPlayDurationMs,
    'last_played_at': lastPlayedAt?.millisecondsSinceEpoch,
    'last_skipped_at': lastSkippedAt?.millisecondsSinceEpoch,
    'first_played_at': firstPlayedAt?.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory TrackStats.fromMap(Map<String, Object?> map) => TrackStats(
    trackId: map['track_id']! as String,
    playCount: map['play_count']! as int,
    completedCount: map['completed_count']! as int,
    skipCount: map['skip_count']! as int,
    manuallySelectedCount: map['manually_selected_count']! as int,
    totalPlayDurationMs: map['total_play_duration_ms']! as int,
    lastPlayedAt: _date(map['last_played_at']),
    lastSkippedAt: _date(map['last_skipped_at']),
    firstPlayedAt: _date(map['first_played_at']),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
  );

  factory TrackStats.empty(String trackId, DateTime updatedAt) => TrackStats(
    trackId: trackId,
    playCount: 0,
    completedCount: 0,
    skipCount: 0,
    manuallySelectedCount: 0,
    totalPlayDurationMs: 0,
    updatedAt: updatedAt,
  );
}

class PlayEvent {
  const PlayEvent({
    required this.eventId,
    required this.trackId,
    required this.startedAt,
    required this.listenedDurationMs,
    required this.trackDurationMs,
    required this.completed,
    required this.skipped,
    required this.manuallySelected,
    required this.contextType,
    required this.playbackMode,
    this.mediaFileId,
    this.sessionId,
    this.endedAt,
    this.contextId,
  });

  final String eventId;
  final String trackId;
  final String? mediaFileId;
  final String? sessionId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int listenedDurationMs;
  final int trackDurationMs;
  final bool completed;
  final bool skipped;
  final bool manuallySelected;
  final String contextType;
  final String? contextId;
  final String playbackMode;

  Map<String, Object?> toMap() => {
    'event_id': eventId,
    'track_id': trackId,
    'media_file_id': mediaFileId,
    'session_id': sessionId,
    'started_at': startedAt.millisecondsSinceEpoch,
    'ended_at': endedAt?.millisecondsSinceEpoch,
    'listened_duration_ms': listenedDurationMs,
    'track_duration_ms': trackDurationMs,
    'completed': completed ? 1 : 0,
    'skipped': skipped ? 1 : 0,
    'manually_selected': manuallySelected ? 1 : 0,
    'context_type': contextType,
    'context_id': contextId,
    'playback_mode': playbackMode,
  };
}

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.fromMillisecondsSinceEpoch(value as int);
