class PickedScanRoot {
  const PickedScanRoot({
    required this.treeUri,
    required this.displayName,
    required this.permissionPersisted,
    this.volumeName,
    this.relativePathHint,
  });

  final String treeUri;
  final String displayName;
  final String? volumeName;
  final String? relativePathHint;
  final bool permissionPersisted;

  factory PickedScanRoot.fromMap(Map<Object?, Object?> map) => PickedScanRoot(
    treeUri: '${map['treeUri']}',
    displayName: '${map['displayName']}',
    volumeName: map['volumeName'] as String?,
    relativePathHint: map['relativePathHint'] as String?,
    permissionPersisted: map['permissionPersisted'] == true,
  );
}

class AudioTagSnapshot {
  const AudioTagSnapshot({
    required this.durationMs,
    required this.readStatus,
    this.title,
    this.artist,
    this.albumArtist,
    this.album,
    this.year,
    this.trackNumber,
    this.discNumber,
    this.bitrate,
    this.sampleRate,
    this.bitDepth,
    this.embeddedLyrics,
    this.embeddedArtworkKey,
    this.embeddedArtworkPath,
    this.embeddedArtworkMime,
    this.tagFormat,
    this.rawPayload,
  });

  final String? title;
  final String? artist;
  final String? albumArtist;
  final String? album;
  final int? year;
  final int? trackNumber;
  final int? discNumber;
  final int durationMs;
  final int? bitrate;
  final int? sampleRate;
  final int? bitDepth;
  final String? embeddedLyrics;
  final String? embeddedArtworkKey;
  final String? embeddedArtworkPath;
  final String? embeddedArtworkMime;
  final String? tagFormat;
  final String readStatus;
  final String? rawPayload;

  bool get hasReliableIdentity =>
      _text(title) != null && (_text(artist) != null || _text(album) != null);

  factory AudioTagSnapshot.fromMap(Map<Object?, Object?> map) =>
      AudioTagSnapshot(
        title: _text(map['title']),
        artist: _text(map['artist']),
        albumArtist: _text(map['albumArtist']),
        album: _text(map['album']),
        year: _integer(map['year']),
        trackNumber: _integer(map['trackNumber']),
        discNumber: _integer(map['discNumber']),
        durationMs: _integer(map['durationMs']) ?? 0,
        bitrate: _integer(map['bitrate']),
        sampleRate: _integer(map['sampleRate']),
        bitDepth: _integer(map['bitDepth']),
        embeddedLyrics: _text(map['embeddedLyrics']),
        embeddedArtworkKey: _text(map['embeddedArtworkKey']),
        embeddedArtworkPath: _text(map['embeddedArtworkPath']),
        embeddedArtworkMime: _text(map['embeddedArtworkMime']),
        tagFormat: _text(map['tagFormat']),
        readStatus: _text(map['readStatus']) ?? 'failed',
        rawPayload: _text(map['rawPayload']),
      );
}

class LyricsCandidate {
  const LyricsCandidate({
    required this.documentUri,
    required this.relativePath,
    required this.filename,
    required this.sizeBytes,
    this.modifiedAt,
  });

  final String documentUri;
  final String relativePath;
  final String filename;
  final int sizeBytes;
  final DateTime? modifiedAt;

  String get basename => filename.replaceFirst(RegExp(r'\.[^.]+$'), '');

  factory LyricsCandidate.fromMap(Map<Object?, Object?> map) => LyricsCandidate(
    documentUri: '${map['documentUri']}',
    relativePath: '${map['relativePath']}',
    filename: '${map['filename']}',
    sizeBytes: _integer(map['sizeBytes']) ?? 0,
    modifiedAt: _date(map['modifiedAt']),
  );
}

class ScannedAudioFile {
  const ScannedAudioFile({
    required this.documentUri,
    required this.relativePath,
    required this.parentFolder,
    required this.filename,
    required this.extension,
    required this.mimeType,
    required this.sizeBytes,
    required this.metadata,
    required this.lyricsCandidates,
    this.localArtworkKey,
    this.localArtworkPath,
    this.localArtworkMime,
    this.localArtworkSource,
    this.libraryArtistFolderName,
    this.libraryArtistRelativeDirectory,
    this.artistArtworkKey,
    this.artistArtworkPath,
    this.artistArtworkMime,
    this.modifiedAt,
    this.mediaStoreVolume,
    this.mediaStoreId,
    this.contentUri,
    this.dateAdded,
  });

  final String documentUri;
  final String relativePath;
  final String parentFolder;
  final String filename;
  final String extension;
  final String mimeType;
  final int sizeBytes;
  final DateTime? modifiedAt;
  final String? mediaStoreVolume;
  final int? mediaStoreId;
  final String? contentUri;
  final DateTime? dateAdded;
  final AudioTagSnapshot metadata;
  final List<LyricsCandidate> lyricsCandidates;
  final String? localArtworkKey;
  final String? localArtworkPath;
  final String? localArtworkMime;
  final String? localArtworkSource;
  final String? libraryArtistFolderName;
  final String? libraryArtistRelativeDirectory;
  final String? artistArtworkKey;
  final String? artistArtworkPath;
  final String? artistArtworkMime;

  String get basename => filename.replaceFirst(RegExp(r'\.[^.]+$'), '');

  factory ScannedAudioFile.fromMap(Map<Object?, Object?> map) {
    final metadata = Map<Object?, Object?>.from(
      map['metadata'] as Map<Object?, Object?>? ?? const {},
    );
    final candidates = (map['lyricsCandidates'] as List<Object?>? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(LyricsCandidate.fromMap)
        .toList(growable: false);
    final addedSeconds = _integer(map['dateAdded']);
    return ScannedAudioFile(
      documentUri: '${map['documentUri']}',
      relativePath: '${map['relativePath']}',
      parentFolder: _text(map['parentFolder']) ?? '',
      filename: '${map['filename']}',
      extension: _text(map['extension']) ?? '',
      mimeType: _text(map['mimeType']) ?? 'audio/*',
      sizeBytes: _integer(map['sizeBytes']) ?? 0,
      modifiedAt: _date(map['modifiedAt']),
      mediaStoreVolume: _text(map['mediaStoreVolume']),
      mediaStoreId: _integer(map['mediaStoreId']),
      contentUri: _text(map['contentUri']),
      dateAdded: addedSeconds == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(addedSeconds * 1000),
      metadata: AudioTagSnapshot.fromMap(metadata),
      lyricsCandidates: candidates,
      localArtworkKey: _text(map['localArtworkKey']),
      localArtworkPath: _text(map['localArtworkPath']),
      localArtworkMime: _text(map['localArtworkMime']),
      localArtworkSource: _text(map['localArtworkSource']),
      libraryArtistFolderName: _text(map['libraryArtistFolderName']),
      libraryArtistRelativeDirectory: _text(
        map['libraryArtistRelativeDirectory'],
      ),
      artistArtworkKey: _text(map['artistArtworkKey']),
      artistArtworkPath: _text(map['artistArtworkPath']),
      artistArtworkMime: _text(map['artistArtworkMime']),
    );
  }
}

class NativeScanEvent {
  const NativeScanEvent({
    required this.scanId,
    required this.type,
    required this.phase,
    required this.files,
    this.discovered,
    this.total,
    this.processed,
    this.message,
  });

  final String scanId;
  final String type;
  final String phase;
  final int? discovered;
  final int? total;
  final int? processed;
  final String? message;
  final List<ScannedAudioFile> files;

  factory NativeScanEvent.fromMap(Map<Object?, Object?> map) => NativeScanEvent(
    scanId: _text(map['scanId']) ?? '',
    type: _text(map['type']) ?? 'progress',
    phase: _text(map['phase']) ?? 'discovering',
    discovered: _integer(map['discovered']),
    total: _integer(map['total']),
    processed: _integer(map['processed']),
    message: _text(map['message']),
    files: (map['files'] as List<Object?>? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(ScannedAudioFile.fromMap)
        .toList(growable: false),
  );
}

class FileHashJob {
  const FileHashJob({
    required this.fileId,
    required this.uri,
    required this.sizeBytes,
    this.modifiedAt,
  });

  final String fileId;
  final String uri;
  final int sizeBytes;
  final DateTime? modifiedAt;

  Map<String, Object?> toPlatformMap() => {
    'fileId': fileId,
    'uri': uri,
    'sizeBytes': sizeBytes,
    'modifiedAt': modifiedAt?.millisecondsSinceEpoch,
  };
}

class FileHashResult {
  const FileHashResult({
    required this.fileId,
    required this.sizeBytes,
    required this.state,
    this.sha256,
    this.modifiedAt,
    this.error,
  });

  final String fileId;
  final String? sha256;
  final int sizeBytes;
  final DateTime? modifiedAt;
  final String state;
  final String? error;

  bool get succeeded => state == 'ready' && sha256?.length == 64;

  factory FileHashResult.fromMap(Map<Object?, Object?> map) => FileHashResult(
    fileId: _text(map['fileId']) ?? '',
    sha256: _text(map['sha256']),
    sizeBytes: _integer(map['sizeBytes']) ?? 0,
    modifiedAt: _date(map['modifiedAt']),
    state: _text(map['state']) ?? 'failed',
    error: _text(map['error']),
  );
}

class LibraryScanProgress {
  const LibraryScanProgress({
    required this.scanId,
    required this.phase,
    required this.discovered,
    required this.processed,
    required this.total,
    required this.finished,
    this.message,
  });

  final String scanId;
  final String phase;
  final int discovered;
  final int processed;
  final int total;
  final bool finished;
  final String? message;

  String get displayText => switch (phase) {
    'discovering' => '发现音乐 $discovered 首',
    'readingMetadata' => '读取信息 $processed/$total',
    'organizing' => '整理音乐 $processed/$total',
    'matchingLyrics' => '关联歌词 $processed/$total',
    'hashing' => '校验文件 $processed/$total',
    'detectingDuplicates' => '检查重复和多版本',
    'complete' => '扫描完成，共 $total 首',
    'cancelled' => '扫描已取消',
    'failed' => message ?? '扫描失败',
    _ => '准备扫描',
  };
}

int? _integer(Object? value) => value is num ? value.toInt() : null;

String? _text(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty || text == 'null' ? null : text;
}

DateTime? _date(Object? value) {
  final milliseconds = _integer(value);
  return milliseconds == null || milliseconds <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(milliseconds);
}
