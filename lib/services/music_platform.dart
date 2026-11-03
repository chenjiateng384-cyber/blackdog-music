import 'package:flutter/services.dart';

import '../models/song.dart';

class DuplicateCleanupResult {
  const DuplicateCleanupResult({required this.removed, required this.failed, required this.removedIds});

  final int removed;
  final int failed;
  final List<int> removedIds;
}

class MusicPlatform {
  static const _channel = MethodChannel('my_music_library/media');

  Future<List<Song>> scanMusic() async {
    final rows = await _channel.invokeListMethod<Object?>('scanMusic') ?? const [];
    return rows
        .whereType<Map<Object?, Object?>>()
        .map(Song.fromMap)
        .toList(growable: false);
  }

  Future<int> importMusic(List<String> paths) async {
    if (paths.isEmpty) return 0;
    return await _channel.invokeMethod<int>('importMusic', {'paths': paths}) ?? 0;
  }

  Future<Uint8List?> artwork(String uri) =>
      _channel.invokeMethod<Uint8List>('artwork', {'uri': uri});

  Future<DuplicateCleanupResult> cleanupDuplicates() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>('cleanupDuplicates') ?? const {};
    return DuplicateCleanupResult(
      removed: ((result['removed'] as num?) ?? 0).toInt(),
      failed: ((result['failed'] as num?) ?? 0).toInt(),
      removedIds: (result['removedIds'] as List<Object?>? ?? const [])
          .whereType<num>()
          .map((id) => id.toInt())
          .toList(growable: false),
    );
  }
}
