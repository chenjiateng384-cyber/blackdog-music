class Artist {
  const Artist({
    required this.artistId,
    required this.displayName,
    required this.normalizedName,
  });
  final String artistId;
  final String displayName;
  final String normalizedName;
  Map<String, Object?> toMap() => {
    'artist_id': artistId,
    'display_name': displayName,
    'normalized_name': normalizedName,
  };

  factory Artist.fromMap(Map<String, Object?> map) => Artist(
    artistId: map['artist_id']! as String,
    displayName: map['display_name']! as String,
    normalizedName: map['normalized_name']! as String,
  );
}

class Album {
  const Album({
    required this.albumId,
    required this.title,
    required this.normalizedTitle,
    required this.albumType,
    this.albumArtistId,
    this.year,
  });
  final String albumId;
  final String title;
  final String normalizedTitle;
  final String? albumArtistId;
  final int? year;
  final String albumType;
  Map<String, Object?> toMap() => {
    'album_id': albumId,
    'title': title,
    'normalized_title': normalizedTitle,
    'album_artist_id': albumArtistId,
    'year': year,
    'album_type': albumType,
  };

  factory Album.fromMap(Map<String, Object?> map) => Album(
    albumId: map['album_id']! as String,
    title: map['title']! as String,
    normalizedTitle: map['normalized_title']! as String,
    albumArtistId: map['album_artist_id'] as String?,
    year: map['year'] as int?,
    albumType: map['album_type']! as String,
  );
}

class ScanRoot {
  const ScanRoot({
    required this.rootId,
    required this.treeUri,
    required this.displayName,
    required this.accessType,
    required this.isPrimary,
    required this.permissionPersisted,
    required this.enabled,
    required this.createdAt,
    this.volumeName,
    this.relativePathHint,
    this.lastScanAt,
  });
  final String rootId;
  final String treeUri;
  final String displayName;
  final String? volumeName;
  final String? relativePathHint;
  final String accessType;
  final bool isPrimary;
  final bool permissionPersisted;
  final bool enabled;
  final DateTime? lastScanAt;
  final DateTime createdAt;
  Map<String, Object?> toMap() => {
    'root_id': rootId,
    'tree_uri': treeUri,
    'display_name': displayName,
    'volume_name': volumeName,
    'relative_path_hint': relativePathHint,
    'access_type': accessType,
    'is_primary': isPrimary ? 1 : 0,
    'permission_persisted': permissionPersisted ? 1 : 0,
    'enabled': enabled ? 1 : 0,
    'last_scan_at': lastScanAt?.millisecondsSinceEpoch,
    'created_at': createdAt.millisecondsSinceEpoch,
  };
}

class Playlist {
  const Playlist({
    required this.playlistId,
    required this.name,
    required this.type,
    required this.createdAt,
    required this.updatedAt,
    this.legacyCategoryId,
  });
  final String playlistId;
  final String name;
  final String type;
  final int? legacyCategoryId;
  final DateTime createdAt;
  final DateTime updatedAt;
  Map<String, Object?> toMap() => {
    'playlist_id': playlistId,
    'name': name,
    'type': type,
    'legacy_category_id': legacyCategoryId,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory Playlist.fromMap(Map<String, Object?> map) => Playlist(
    playlistId: map['playlist_id']! as String,
    name: map['name']! as String,
    type: map['type']! as String,
    legacyCategoryId: map['legacy_category_id'] as int?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
  );
}

class LyricsReference {
  const LyricsReference({
    required this.lyricsId,
    required this.trackId,
    required this.source,
    required this.matchMethod,
    required this.matched,
    required this.confidence,
    required this.offsetMs,
    required this.isSelected,
    required this.createdAt,
    this.mediaFileId,
    this.scanRootId,
    this.contentUri,
    this.documentUri,
    this.relativePath,
    this.filename,
    this.sizeBytes,
    this.modifiedAt,
    this.sha256,
  });
  final String lyricsId;
  final String trackId;
  final String? mediaFileId;
  final String? scanRootId;
  final String? contentUri;
  final String? documentUri;
  final String? relativePath;
  final String? filename;
  final String source;
  final String matchMethod;
  final bool matched;
  final double confidence;
  final int offsetMs;
  final int? sizeBytes;
  final DateTime? modifiedAt;
  final String? sha256;
  final bool isSelected;
  final DateTime createdAt;

  factory LyricsReference.fromMap(Map<String, Object?> map) => LyricsReference(
    lyricsId: map['lyrics_id']! as String,
    trackId: map['track_id']! as String,
    mediaFileId: map['media_file_id'] as String?,
    scanRootId: map['scan_root_id'] as String?,
    contentUri: map['content_uri'] as String?,
    documentUri: map['document_uri'] as String?,
    relativePath: map['relative_path'] as String?,
    filename: map['filename'] as String?,
    source: map['source']! as String,
    matchMethod: map['match_method']! as String,
    matched: map['matched'] == 1,
    confidence: (map['confidence']! as num).toDouble(),
    offsetMs: map['offset_ms']! as int,
    sizeBytes: map['size_bytes'] as int?,
    modifiedAt: _dateFromMilliseconds(map['modified_at']),
    sha256: map['sha256'] as String?,
    isSelected: map['is_selected'] == 1,
    createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
  );
}

DateTime? _dateFromMilliseconds(Object? value) =>
    value == null ? null : DateTime.fromMillisecondsSinceEpoch(value as int);
