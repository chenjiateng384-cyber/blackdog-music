abstract class MetadataLayer {
  const MetadataLayer({
    this.title,
    this.artist,
    this.albumArtist,
    this.album,
    this.year,
    this.discNumber,
    this.trackNumber,
  });

  final String? title;
  final String? artist;
  final String? albumArtist;
  final String? album;
  final int? year;
  final int? discNumber;
  final int? trackNumber;

  Map<String, Object?> fields() => {
    'title': title,
    'artist': artist,
    'album_artist': albumArtist,
    'album': album,
    'year': year,
    'disc_number': discNumber,
    'track_number': trackNumber,
  };
}

class FileMetadataRaw extends MetadataLayer {
  const FileMetadataRaw({
    required this.fileId,
    required this.readStatus,
    required this.readAt,
    super.title,
    super.artist,
    super.albumArtist,
    super.album,
    super.year,
    super.discNumber,
    super.trackNumber,
    this.embeddedLyrics,
    this.embeddedArtworkKey,
    this.tagFormat,
    this.rawPayload,
  });

  final String fileId;
  final String? embeddedLyrics;
  final String? embeddedArtworkKey;
  final String? tagFormat;
  final String? rawPayload;
  final String readStatus;
  final DateTime readAt;
}

class InferredMetadata extends MetadataLayer {
  const InferredMetadata({
    required this.fileId,
    required this.inferenceMethod,
    required this.fieldConfidenceJson,
    required this.needsReview,
    required this.createdAt,
    super.title,
    super.artist,
    super.albumArtist,
    super.album,
    super.year,
    super.discNumber,
    super.trackNumber,
  });

  final String fileId;
  final String inferenceMethod;
  final String fieldConfidenceJson;
  final bool needsReview;
  final DateTime createdAt;
}

class OnlineMetadata extends MetadataLayer {
  const OnlineMetadata({
    required this.onlineMetadataId,
    required this.trackId,
    required this.provider,
    required this.confidence,
    required this.confirmed,
    required this.rejected,
    required this.fetchedAt,
    super.title,
    super.artist,
    super.albumArtist,
    super.album,
    super.year,
    super.discNumber,
    super.trackNumber,
    this.providerRecordingId,
    this.providerReleaseId,
    this.durationMs,
  });

  final String onlineMetadataId;
  final String trackId;
  final String provider;
  final String? providerRecordingId;
  final String? providerReleaseId;
  final int? durationMs;
  final double confidence;
  final bool confirmed;
  final bool rejected;
  final DateTime fetchedAt;
}

class TrackOverride extends MetadataLayer {
  const TrackOverride({
    required this.trackId,
    required this.updatedAt,
    super.title,
    super.artist,
    super.albumArtist,
    super.album,
    super.year,
    super.discNumber,
    super.trackNumber,
    this.customArtworkId,
  });

  final String trackId;
  final String? customArtworkId;
  final DateTime updatedAt;
}
