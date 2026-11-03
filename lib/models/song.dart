import 'dart:typed_data';

enum AudioQuality { lossless, good, upgradeSuggested, suspicious, unknown }

class Song {
  const Song({
    required this.id,
    required this.uri,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.dateAdded,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    required this.bitrate,
    required this.sampleRate,
    required this.bitsPerSample,
    this.onlineArtwork,
    this.metadataMatched = false,
  });

  final int id;
  final String uri;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final DateTime dateAdded;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final int bitrate;
  final int sampleRate;
  final int bitsPerSample;
  final Uint8List? onlineArtwork;
  final bool metadataMatched;

  String get extension {
    final dot = displayName.lastIndexOf('.');
    return dot < 0 ? '' : displayName.substring(dot + 1).toLowerCase();
  }

  String get formatLabel {
    if (extension.isNotEmpty) return extension.toUpperCase();
    if (mimeType.contains('mpeg')) return 'MP3';
    if (mimeType.contains('flac')) return 'FLAC';
    if (mimeType.contains('wav')) return 'WAV';
    return '音频';
  }

  int get effectiveBitrate {
    if (bitrate > 0) return bitrate;
    if (sizeBytes > 0 && duration.inSeconds > 0) {
      return (sizeBytes * 8 / duration.inSeconds).round();
    }
    return 0;
  }

  AudioQuality get quality {
    if (sizeBytes <= 0 || duration <= Duration.zero) return AudioQuality.suspicious;
    if ({'flac', 'wav', 'wave', 'alac', 'aiff', 'aif'}.contains(extension) ||
        mimeType.contains('flac') ||
        mimeType.contains('alac') ||
        mimeType.contains('wav') ||
        mimeType.contains('aiff')) {
      return AudioQuality.lossless;
    }
    if (extension == 'mp3' || mimeType == 'audio/mpeg') {
      if (effectiveBitrate <= 0) return AudioQuality.unknown;
      if (effectiveBitrate < 64000) return AudioQuality.suspicious;
      return effectiveBitrate >= 256000
          ? AudioQuality.good
          : AudioQuality.upgradeSuggested;
    }
    if ({'m4a', 'aac', 'ogg', 'opus', 'wma'}.contains(extension)) {
      return AudioQuality.good;
    }
    return AudioQuality.unknown;
  }

  bool get needsUpgrade => quality == AudioQuality.upgradeSuggested;
  bool get isSuspicious => quality == AudioQuality.suspicious;
  String get bitrateLabel => effectiveBitrate > 0
      ? '${(effectiveBitrate / 1000).round()} kbps${bitrate <= 0 ? '（估算）' : ''}'
      : '未知码率';

  String get sampleRateLabel {
    if (sampleRate <= 0) return '未知采样率';
    final khz = sampleRate / 1000;
    return '${khz == khz.roundToDouble() ? khz.toStringAsFixed(0) : khz.toStringAsFixed(1)} kHz';
  }

  String get sizeLabel => formatFileSize(sizeBytes);

  Song copyWith({
    String? title,
    String? artist,
    String? album,
    Uint8List? onlineArtwork,
    bool? metadataMatched,
  }) {
    return Song(
      id: id,
      uri: uri,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration,
      dateAdded: dateAdded,
      displayName: displayName,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      bitrate: bitrate,
      sampleRate: sampleRate,
      bitsPerSample: bitsPerSample,
      onlineArtwork: onlineArtwork ?? this.onlineArtwork,
      metadataMatched: metadataMatched ?? this.metadataMatched,
    );
  }

  factory Song.fromMap(Map<Object?, Object?> map) {
    final displayName = (map['displayName'] as String?)?.trim() ?? '';
    final rawTitle = (map['title'] as String?)?.trim();
    final rawArtist = (map['artist'] as String?)?.trim();
    final parsed = parseMusicFileName(displayName);
    final missingTitle = rawTitle == null || rawTitle.isEmpty || rawTitle == displayName;
    final missingArtist = !_isPlausibleArtist(rawArtist);
    final parsedArtist = _isPlausibleArtist(parsed.artist) ? parsed.artist : null;
    final fallbackTitle = parsed.title ?? _nameWithoutExtension(displayName);
    return Song(
      id: (map['id'] as num).toInt(),
      uri: map['uri']! as String,
      title: missingTitle ? (fallbackTitle.isEmpty ? '未知歌曲' : fallbackTitle) : rawTitle,
      artist: missingArtist ? (parsedArtist ?? '未知歌手') : rawArtist!,
      album: ((map['album'] as String?)?.trim().isNotEmpty ?? false)
          ? (map['album']! as String).trim()
          : '未知专辑',
      duration: Duration(milliseconds: ((map['duration'] as num?) ?? 0).toInt()),
      dateAdded: DateTime.fromMillisecondsSinceEpoch(
        (((map['dateAdded'] as num?) ?? 0).toInt()) * 1000,
      ),
      displayName: displayName,
      mimeType: (map['mimeType'] as String?) ?? '',
      sizeBytes: ((map['size'] as num?) ?? 0).toInt(),
      bitrate: ((map['bitrate'] as num?) ?? 0).toInt(),
      sampleRate: ((map['sampleRate'] as num?) ?? 0).toInt(),
      bitsPerSample: ((map['bitsPerSample'] as num?) ?? 0).toInt(),
    );
  }
}

class ParsedMusicName {
  const ParsedMusicName({this.artist, this.title});

  final String? artist;
  final String? title;
}

ParsedMusicName parseMusicFileName(String fileName) {
  final name = _nameWithoutExtension(fileName)
      .replaceAll(RegExp(r'^\s*\d{1,3}[.、_\-\s]+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final parts = name.split(RegExp(r'\s+[-–—]\s+'));
  if (parts.length >= 2) {
    final artist = parts.first.trim();
    final title = parts.sublist(1).join(' - ').trim();
    if (artist.isNotEmpty && title.isNotEmpty) {
      return ParsedMusicName(artist: artist, title: title);
    }
  }
  return ParsedMusicName(title: name.isEmpty ? null : name);
}

String _nameWithoutExtension(String value) {
  final dot = value.lastIndexOf('.');
  return (dot > 0 ? value.substring(0, dot) : value).trim();
}

bool _isPlausibleArtist(String? value) {
  final artist = value?.trim() ?? '';
  if (artist.isEmpty || artist == '<unknown>' || artist == '未知艺术家') return false;
  if (artist.contains('/') || artist.contains(r'\')) return false;
  if (RegExp(r'^[a-fA-F0-9]{16,}$').hasMatch(artist)) return false;
  if (RegExp(r'^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$').hasMatch(artist)) {
    return false;
  }
  return true;
}

String formatDuration(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

String formatFileSize(int bytes) {
  if (bytes <= 0) return '未知大小';
  final megabytes = bytes / (1024 * 1024);
  if (megabytes >= 1024) return '${(megabytes / 1024).toStringAsFixed(1)} GB';
  return '${megabytes.toStringAsFixed(megabytes >= 100 ? 0 : 1)} MB';
}
