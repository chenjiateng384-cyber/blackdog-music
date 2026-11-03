class ArtworkReference {
  const ArtworkReference({
    required this.artworkId,
    required this.source,
    required this.confidence,
    required this.createdAt,
    this.trackId,
    this.fileId,
    this.cachePath,
    this.contentUri,
    this.mimeType,
    this.sha256,
  });

  final String artworkId;
  final String? trackId;
  final String? fileId;
  final String source;
  final String? cachePath;
  final String? contentUri;
  final String? mimeType;
  final String? sha256;
  final double confidence;
  final DateTime createdAt;

  bool get hasReadableLocation =>
      (cachePath != null && cachePath!.isNotEmpty) ||
      (contentUri != null && contentUri!.isNotEmpty);

  factory ArtworkReference.fromAliasedMap(
    Map<String, Object?> map, {
    String prefix = 'art_',
  }) {
    return ArtworkReference(
      artworkId: map['${prefix}artwork_id']! as String,
      trackId: map['${prefix}track_id'] as String?,
      fileId: map['${prefix}file_id'] as String?,
      source: map['${prefix}source']! as String,
      cachePath: map['${prefix}cache_path'] as String?,
      contentUri: map['${prefix}content_uri'] as String?,
      mimeType: map['${prefix}mime_type'] as String?,
      sha256: map['${prefix}sha256'] as String?,
      confidence: (map['${prefix}confidence']! as num).toDouble(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        map['${prefix}created_at']! as int,
      ),
    );
  }

  static ArtworkReference? maybeFromAliasedMap(
    Map<String, Object?> map, {
    String prefix = 'art_',
  }) => map['${prefix}artwork_id'] == null
      ? null
      : ArtworkReference.fromAliasedMap(map, prefix: prefix);
}
