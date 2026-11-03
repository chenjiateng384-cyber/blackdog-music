import 'package:flutter/services.dart';

import '../models/v4/scan_models.dart';

class V4ScanPlatform {
  const V4ScanPlatform();

  static const _methods = MethodChannel('my_music_library/v4_scan');
  static const _events = EventChannel('my_music_library/v4_scan_events');

  Stream<NativeScanEvent> get events => _events
      .receiveBroadcastStream()
      .where((event) => event is Map<Object?, Object?>)
      .map((event) => NativeScanEvent.fromMap(event as Map<Object?, Object?>));

  Future<PickedScanRoot?> pickScanRoot() async {
    final map = await _methods.invokeMapMethod<Object?, Object?>(
      'pickScanRoot',
    );
    return map == null ? null : PickedScanRoot.fromMap(map);
  }

  Future<bool> validateScanRoot(String treeUri) async =>
      await _methods.invokeMethod<bool>('validateScanRoot', {
        'treeUri': treeUri,
      }) ??
      false;

  Future<String> startScan({
    required String scanId,
    required String treeUri,
  }) async =>
      await _methods.invokeMethod<String>('startScan', {
        'scanId': scanId,
        'treeUri': treeUri,
      }) ??
      scanId;

  Future<void> cancelScan() => _methods.invokeMethod<void>('cancelScan');

  Future<List<FileHashResult>> hashFiles(List<FileHashJob> files) async {
    final values = await _methods.invokeListMethod<Object?>('hashFiles', {
      'files': files
          .map((file) => file.toPlatformMap())
          .toList(growable: false),
    });
    return (values ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(FileHashResult.fromMap)
        .toList(growable: false);
  }

  Future<String> readTextDocument(String uri) async =>
      await _methods.invokeMethod<String>('readTextDocument', {'uri': uri}) ??
      '';
}
