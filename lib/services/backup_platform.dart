import 'package:flutter/services.dart';

abstract interface class BackupDocumentGateway {
  Future<String?> exportDirectory({
    required String directoryPath,
    required String suggestedName,
  });

  Future<String?> importPackage({required String destinationDirectory});

  Future<String> appVersion();
}

class BackupPlatform implements BackupDocumentGateway {
  const BackupPlatform();

  static const _channel = MethodChannel('my_music_library/backup');

  @override
  Future<String?> exportDirectory({
    required String directoryPath,
    required String suggestedName,
  }) => _channel.invokeMethod<String>('exportBackup', {
    'sourceDirectory': directoryPath,
    'suggestedName': suggestedName,
  });

  @override
  Future<String?> importPackage({required String destinationDirectory}) =>
      _channel.invokeMethod<String>('importBackup', {
        'destinationDirectory': destinationDirectory,
      });

  @override
  Future<String> appVersion() async =>
      await _channel.invokeMethod<String>('appVersion') ?? 'unknown';
}
