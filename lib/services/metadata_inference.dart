import 'dart:convert';

import '../models/v4/scan_models.dart';

class InferredAudioMetadata {
  const InferredAudioMetadata({
    required this.inferenceMethod,
    required this.fieldConfidenceJson,
    required this.needsReview,
    required this.albumType,
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
  final String albumType;
  final String inferenceMethod;
  final String fieldConfidenceJson;
  final bool needsReview;
}

class MetadataInference {
  const MetadataInference();

  InferredAudioMetadata infer(ScannedAudioFile file) {
    final segments = file.relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.trim().isNotEmpty)
        .toList(growable: false);
    final directories = segments.length <= 1
        ? const <String>[]
        : segments.sublist(0, segments.length - 1);
    final artistDirectory = _artistDirectory(directories);
    final albumDirectory = _albumDirectory(directories);
    final parsedAlbum = _parseAlbumDirectory(albumDirectory);
    final parsedFilename = _parseFilename(file.basename, artistDirectory);
    final confidence = <String, double>{};
    if (artistDirectory != null) {
      confidence['artist'] = 0.86;
    }
    if (parsedAlbum.album != null) {
      confidence['album'] = parsedAlbum.confidence;
    }
    if (parsedAlbum.year != null) {
      confidence['year'] = 0.93;
    }
    if (parsedFilename.title != null) {
      confidence['title'] = parsedFilename.titleConfidence;
    }
    if (parsedFilename.trackNumber != null) {
      confidence['trackNumber'] = 0.95;
    }
    if (parsedFilename.artist != null) {
      confidence['artist'] = parsedFilename.artistConfidence;
    }
    final methods = <String>[
      if (artistDirectory != null || parsedAlbum.album != null) 'directory',
      if (parsedFilename.usedPattern) 'filename',
    ];
    // A filename carrying an explicit credit is better evidence than a
    // generic/container folder. For a real artist folder the parser only
    // returns a filename artist when the credit agrees with that folder.
    final inferredArtist = parsedFilename.artist ?? artistDirectory;
    final needsReview =
        inferredArtist == null ||
        parsedFilename.ambiguous ||
        (file.metadata.readStatus == 'failed' && parsedFilename.title == null);
    return InferredAudioMetadata(
      title: parsedFilename.title ?? file.basename.trim(),
      artist: inferredArtist,
      albumArtist: inferredArtist,
      album: parsedAlbum.album,
      year: parsedAlbum.year,
      trackNumber: parsedFilename.trackNumber,
      albumType: parsedAlbum.albumType,
      inferenceMethod: methods.isEmpty ? 'basenameFallback' : methods.join('+'),
      fieldConfidenceJson: jsonEncode(confidence),
      needsReview: needsReview,
    );
  }

  String? _artistDirectory(List<String> directories) {
    if (directories.isEmpty) return null;
    final first = directories.first.trim();
    if (_genericDirectories.contains(_normalized(first))) return null;
    return first;
  }

  String? _albumDirectory(List<String> directories) {
    if (directories.length < 2) return null;
    for (final directory in directories.reversed) {
      final normalized = _normalized(directory);
      if (!_containerDirectories.contains(normalized) &&
          !_genericDirectories.contains(normalized)) {
        return directory.trim();
      }
    }
    return null;
  }

  _ParsedAlbum _parseAlbumDirectory(String? directory) {
    if (directory == null) return const _ParsedAlbum(albumType: 'unknown');
    final name = directory.trim();
    final normalized = _normalized(name);
    if (normalized.contains('演唱会') || normalized.contains('live')) {
      return _ParsedAlbum(album: name, albumType: 'live', confidence: 0.88);
    }
    if (normalized.contains('ep') || normalized.contains('单曲')) {
      return _ParsedAlbum(album: name, albumType: 'single', confidence: 0.86);
    }
    final match = RegExp(r'^((?:19|20)\d{2})[\s_.-]+(.+)$').firstMatch(name);
    if (match != null) {
      return _ParsedAlbum(
        album: match.group(2)!.trim(),
        year: int.parse(match.group(1)!),
        albumType: 'studio',
        confidence: 0.93,
      );
    }
    return _ParsedAlbum(album: name, albumType: 'unknown', confidence: 0.75);
  }

  _ParsedFilename _parseFilename(String basename, String? directoryArtist) {
    final value = basename.trim();
    final numbered = RegExp(r'^\s*(\d{1,3})\s*[._\- ]+\s*(.+)$')
        .firstMatch(value);
    if (numbered != null) {
      return _ParsedFilename(
        title: numbered.group(2)!.trim(),
        trackNumber: int.tryParse(numbered.group(1)!),
        titleConfidence: 0.94,
        usedPattern: true,
      );
    }
    final pair = RegExp(r'^(.+?)\s*[-–—]\s*(.+)$').firstMatch(value);
    if (pair != null) {
      final first = pair.group(1)!.trim();
      final second = pair.group(2)!.trim();
      if (directoryArtist != null && _samePrimary(first, directoryArtist)) {
        return _ParsedFilename(
          title: second,
          artist: first,
          titleConfidence: 0.88,
          artistConfidence: 0.9,
          usedPattern: true,
        );
      }
      if (directoryArtist != null && _samePrimary(second, directoryArtist)) {
        return _ParsedFilename(
          title: first,
          artist: second,
          titleConfidence: 0.88,
          artistConfidence: 0.9,
          usedPattern: true,
        );
      }
      if (directoryArtist == null && _looksLikeTitle(first, second)) {
        return _ParsedFilename(
          title: first,
          artist: second,
          titleConfidence: 0.88,
          artistConfidence: 0.86,
          usedPattern: true,
        );
      }
      return _ParsedFilename(
        title: second,
        artist: first,
        titleConfidence: 0.65,
        artistConfidence: 0.6,
        usedPattern: true,
        ambiguous: true,
      );
    }
    return _ParsedFilename(title: value, titleConfidence: 0.7);
  }

  bool _same(String first, String second) =>
      _normalized(first) == _normalized(second);

  bool _samePrimary(String credit, String directoryArtist) {
    final primary = credit
        .split(
          RegExp(
            r'\s*(?:&|＆|/|\bfeat(?:uring)?\.?\b|\bft\.?\b)\s*',
            caseSensitive: false,
          ),
        )
        .first
        .trim();
    return _same(primary, directoryArtist);
  }

  bool _looksLikeTitle(String first, String second) {
    final firstHasVersion = RegExp(
      r'[（(](?:伴奏|live|remaster(?:ed)?|remix|instrumental|acoustic)[^）)]*[）)]',
      caseSensitive: false,
    ).hasMatch(first);
    final secondHasCreditSeparator = RegExp(
      r'(?:&|＆|/|\bfeat(?:uring)?\.?\b|\bft\.?\b)',
      caseSensitive: false,
    ).hasMatch(second);
    final firstHasCreditSeparator = RegExp(
      r'(?:&|＆|/|\bfeat(?:uring)?\.?\b|\bft\.?\b)',
      caseSensitive: false,
    ).hasMatch(first);
    if (firstHasVersion || secondHasCreditSeparator) return true;
    if (firstHasCreditSeparator) return false;
    // For the common "稻香 - 周杰伦" / "Avicii - The Nights" forms,
    // the shorter side is normally the credit. Ties remain conservative.
    return second.runes.length > first.runes.length;
  }

  String _normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s_.\-/—·（）()\[\]]+'), '');

  static const _genericDirectories = {
    '英文歌',
    '零散单曲',
    '单曲',
    'singles',
    'single',
    '其他歌手',
    '其他',
    '未分类',
    '原版',
    '其他版本',
    '伴奏',
    'original',
    'versions',
    '音乐文件',
    'music',
  };
  static const _containerDirectories = {
    '专辑',
    'albums',
    'album',
    '单曲',
    'singles',
    'single',
    '原版',
    '其他版本',
    '伴奏',
    'original',
    'versions',
  };
}

class _ParsedAlbum {
  const _ParsedAlbum({
    required this.albumType,
    this.album,
    this.year,
    this.confidence = 0,
  });
  final String? album;
  final int? year;
  final String albumType;
  final double confidence;
}

class _ParsedFilename {
  const _ParsedFilename({
    this.title,
    this.artist,
    this.trackNumber,
    this.titleConfidence = 0,
    this.artistConfidence = 0,
    this.usedPattern = false,
    this.ambiguous = false,
  });
  final String? title;
  final String? artist;
  final int? trackNumber;
  final double titleConfidence;
  final double artistConfidence;
  final bool usedPattern;
  final bool ambiguous;
}
