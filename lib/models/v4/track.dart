class Track {
  const Track({
    required this.trackId,
    required this.title,
    required this.artistDisplay,
    required this.albumArtistDisplay,
    required this.albumDisplay,
    required this.durationMs,
    required this.metadataState,
    required this.addedAt,
    required this.updatedAt,
    this.albumId,
    this.year,
    this.discNumber,
    this.trackNumber,
    this.preferredMediaFileId,
    this.preferredFileSource = 'automatic',
    this.deletedAt,
  });

  final String trackId;
  final String title;
  final String artistDisplay;
  final String albumArtistDisplay;
  final String albumDisplay;
  final String? albumId;
  final int? year;
  final int? discNumber;
  final int? trackNumber;
  final int durationMs;
  final String? preferredMediaFileId;
  final String preferredFileSource;
  final String metadataState;
  final DateTime addedAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toMap() => {
    'track_id': trackId,
    'title': title,
    'artist_display': artistDisplay,
    'album_artist_display': albumArtistDisplay,
    'album_display': albumDisplay,
    'album_id': albumId,
    'year': year,
    'disc_number': discNumber,
    'track_number': trackNumber,
    'duration_ms': durationMs,
    'preferred_media_file_id': preferredMediaFileId,
    'preferred_file_source': preferredFileSource,
    'metadata_state': metadataState,
    'added_at': addedAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'deleted_at': deletedAt?.millisecondsSinceEpoch,
  };

  factory Track.fromMap(Map<String, Object?> map) => Track(
    trackId: map['track_id']! as String,
    title: map['title']! as String,
    artistDisplay: map['artist_display']! as String,
    albumArtistDisplay: map['album_artist_display']! as String,
    albumDisplay: map['album_display']! as String,
    albumId: map['album_id'] as String?,
    year: map['year'] as int?,
    discNumber: map['disc_number'] as int?,
    trackNumber: map['track_number'] as int?,
    durationMs: map['duration_ms']! as int,
    preferredMediaFileId: map['preferred_media_file_id'] as String?,
    preferredFileSource: map['preferred_file_source'] as String? ?? 'automatic',
    metadataState: map['metadata_state']! as String,
    addedAt: DateTime.fromMillisecondsSinceEpoch(map['added_at']! as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
    deletedAt: _date(map['deleted_at']),
  );
}

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.fromMillisecondsSinceEpoch(value as int);
