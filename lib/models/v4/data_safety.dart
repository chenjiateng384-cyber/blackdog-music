class DataHealthIssue {
  const DataHealthIssue({
    required this.code,
    required this.message,
    this.count,
  });

  final String code;
  final String message;
  final int? count;
}

class DataHealthReport {
  const DataHealthReport({
    required this.checkedAt,
    required this.integrityOk,
    required this.issues,
  });

  final DateTime checkedAt;
  final bool integrityOk;
  final List<DataHealthIssue> issues;

  bool get healthy => integrityOk && issues.isEmpty;
}

class BackupManifest {
  const BackupManifest({
    required this.formatVersion,
    required this.databaseVersion,
    required this.appVersion,
    required this.createdAt,
    required this.files,
    required this.rowCounts,
  });

  factory BackupManifest.fromJson(Map<String, Object?> json) {
    final files = json['files'];
    final rowCounts = json['rowCounts'];
    if (files is! Map || rowCounts is! Map) {
      throw const FormatException('备份清单不完整');
    }
    return BackupManifest(
      formatVersion: (json['formatVersion'] as num?)?.toInt() ?? 0,
      databaseVersion: (json['databaseVersion'] as num?)?.toInt() ?? 0,
      appVersion: json['appVersion'] as String? ?? 'unknown',
      createdAt: DateTime.parse(json['createdAt'] as String),
      files: files.map((key, value) => MapEntry('$key', '$value')),
      rowCounts: rowCounts.map(
        (key, value) => MapEntry('$key', (value as num).toInt()),
      ),
    );
  }

  final int formatVersion;
  final int databaseVersion;
  final String appVersion;
  final DateTime createdAt;
  final Map<String, String> files;
  final Map<String, int> rowCounts;

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'databaseVersion': databaseVersion,
    'appVersion': appVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'files': files,
    'rowCounts': rowCounts,
  };
}

class BackupExportResult {
  const BackupExportResult({required this.uri, required this.manifest});

  final String uri;
  final BackupManifest manifest;
}

class BackupRestoreResult {
  const BackupRestoreResult({required this.manifest});

  final BackupManifest manifest;
}
