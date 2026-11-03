class MediaFile {
  const MediaFile({
    required this.fileId,
    required this.trackId,
    required this.filename,
    required this.normalizedFilename,
    required this.extension,
    required this.mimeType,
    required this.sizeBytes,
    required this.durationMs,
    required this.hashState,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.scanRootId,
    this.mediaStoreVolume,
    this.mediaStoreId,
    this.contentUri,
    this.documentUri,
    this.relativePath,
    this.parentFolder,
    this.modifiedAt,
    this.bitrate,
    this.sampleRate,
    this.bitDepth,
    this.sha256,
    this.hashSize,
    this.hashModifiedAt,
    this.duplicateOfFileId,
    this.lastSeenScanId,
    this.missingSince,
  });

  final String fileId;
  final String trackId;
  final String? scanRootId;
  final String? mediaStoreVolume;
  final int? mediaStoreId;
  final String? contentUri;
  final String? documentUri;
  final String? relativePath;
  final String? parentFolder;
  final String filename;
  final String normalizedFilename;
  final String extension;
  final String mimeType;
  final int sizeBytes;
  final DateTime? modifiedAt;
  final int durationMs;
  final int? bitrate;
  final int? sampleRate;
  final int? bitDepth;
  final String? sha256;
  final int? hashSize;
  final DateTime? hashModifiedAt;
  final String hashState;
  final String? duplicateOfFileId;
  final String? lastSeenScanId;
  final DateTime? missingSince;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toMap() => {
    'file_id': fileId,
    'track_id': trackId,
    'scan_root_id': scanRootId,
    'media_store_volume': mediaStoreVolume,
    'media_store_id': mediaStoreId,
    'content_uri': contentUri,
    'document_uri': documentUri,
    'relative_path': relativePath,
    'parent_folder': parentFolder,
    'filename': filename,
    'normalized_filename': normalizedFilename,
    'extension': extension,
    'mime_type': mimeType,
    'size_bytes': sizeBytes,
    'modified_at': modifiedAt?.millisecondsSinceEpoch,
    'duration_ms': durationMs,
    'bitrate': bitrate,
    'sample_rate': sampleRate,
    'bit_depth': bitDepth,
    'sha256': sha256,
    'hash_size': hashSize,
    'hash_modified_at': hashModifiedAt?.millisecondsSinceEpoch,
    'hash_state': hashState,
    'duplicate_of_file_id': duplicateOfFileId,
    'last_seen_scan_id': lastSeenScanId,
    'missing_since': missingSince?.millisecondsSinceEpoch,
    'status': status,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory MediaFile.fromMap(Map<String, Object?> map) => MediaFile(
    fileId: map['file_id']! as String,
    trackId: map['track_id']! as String,
    scanRootId: map['scan_root_id'] as String?,
    mediaStoreVolume: map['media_store_volume'] as String?,
    mediaStoreId: map['media_store_id'] as int?,
    contentUri: map['content_uri'] as String?,
    documentUri: map['document_uri'] as String?,
    relativePath: map['relative_path'] as String?,
    parentFolder: map['parent_folder'] as String?,
    filename: map['filename']! as String,
    normalizedFilename: map['normalized_filename']! as String,
    extension: map['extension']! as String,
    mimeType: map['mime_type']! as String,
    sizeBytes: map['size_bytes']! as int,
    modifiedAt: _date(map['modified_at']),
    durationMs: map['duration_ms']! as int,
    bitrate: map['bitrate'] as int?,
    sampleRate: map['sample_rate'] as int?,
    bitDepth: map['bit_depth'] as int?,
    sha256: map['sha256'] as String?,
    hashSize: map['hash_size'] as int?,
    hashModifiedAt: _date(map['hash_modified_at']),
    hashState: map['hash_state']! as String,
    duplicateOfFileId: map['duplicate_of_file_id'] as String?,
    lastSeenScanId: map['last_seen_scan_id'] as String?,
    missingSince: _date(map['missing_since']),
    status: map['status']! as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
  );
}

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.fromMillisecondsSinceEpoch(value as int);
