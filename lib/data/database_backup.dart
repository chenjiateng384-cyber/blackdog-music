// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'v4_schema.dart';

class DatabaseBackupResult {
  const DatabaseBackupResult({
    required this.databasePath,
    required this.exportPath,
    required this.manifestPath,
    required this.createdAt,
    required this.sourceVersion,
    required this.databaseSize,
    required this.sha256,
    required this.journalMode,
    required this.checkpointVerified,
    required this.databaseVerified,
    required this.tableRowCounts,
    required this.sidecarPaths,
  });

  final String databasePath;
  final String exportPath;
  final String manifestPath;
  final DateTime createdAt;
  final int sourceVersion;
  final int databaseSize;
  final String sha256;
  final String journalMode;
  final bool checkpointVerified;
  final bool databaseVerified;
  final Map<String, int> tableRowCounts;
  final List<String> sidecarPaths;

  Map<String, Object?> toJson() => {
    'databasePath': databasePath,
    'exportPath': exportPath,
    'manifestPath': manifestPath,
    'createdAt': createdAt.toIso8601String(),
    'sourceVersion': sourceVersion,
    'databaseSize': databaseSize,
    'sha256': sha256,
    'journalMode': journalMode,
    'checkpointVerified': checkpointVerified,
    'databaseVerified': databaseVerified,
    'tableRowCounts': tableRowCounts,
    'sidecarPaths': sidecarPaths,
  };
}

class DatabaseBackupService {
  DatabaseBackupService({
    required DatabaseFactory factory,
    required Directory backupDirectory,
  }) : _factory = factory,
       _backupDirectory = backupDirectory;

  final DatabaseFactory _factory;
  final Directory _backupDirectory;

  Future<DatabaseBackupResult> backupV3(String sourcePath) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw StateError('V3 database does not exist: $sourcePath');
    }

    final createdAt = DateTime.now().toUtc();
    final stamp = createdAt.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    await _backupDirectory.create(recursive: true);
    final backupPath = p.join(
      _backupDirectory.path,
      'my_music_library-v3-$stamp.db',
    );
    final exportPath = '$backupPath.user-data.json';
    final manifestPath = '$backupPath.manifest.json';

    Database? source;
    var sourceVersion = 0;
    var journalMode = 'unknown';
    var checkpointVerified = false;
    final data = <String, List<Map<String, Object?>>>{};
    final counts = <String, int>{};
    try {
      source = await _factory.openDatabase(
        sourcePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      sourceVersion = await source.getVersion();
      if (sourceVersion != 3) {
        throw StateError('Expected database version 3, got $sourceVersion');
      }
      final journalRows = await source.rawQuery('PRAGMA journal_mode');
      if (journalRows.isNotEmpty && journalRows.first.values.isNotEmpty) {
        journalMode = '${journalRows.first.values.first}'.toLowerCase();
      }
      final checkpointRows = await source.rawQuery(
        'PRAGMA wal_checkpoint(TRUNCATE)',
      );
      final checkpoint = checkpointRows.isEmpty
          ? const <String, Object?>{}
          : checkpointRows.first;
      final busy =
          (checkpoint['busy'] as num?)?.toInt() ??
          (checkpoint.values.isEmpty
              ? 0
              : (checkpoint.values.first as num?)?.toInt() ?? 0);
      if (busy != 0) throw StateError('SQLite WAL checkpoint is busy');
      checkpointVerified = true;

      final existingTables = await _tableNames(source);
      for (final table in V4Schema.legacyTables) {
        if (!existingTables.contains(table)) {
          throw StateError('Required V3 table is missing: $table');
        }
        final rows = await source.query(table);
        data[table] = rows.map(_jsonSafeRow).toList(growable: false);
        counts[table] = rows.length;
      }
    } finally {
      await source?.close();
    }

    await sourceFile.copy(backupPath);
    final copiedSidecars = <String>[];
    for (final suffix in const ['-wal', '-shm']) {
      final sidecar = File('$sourcePath$suffix');
      if (await sidecar.exists() && await sidecar.length() > 0) {
        final destination = '$backupPath$suffix';
        await sidecar.copy(destination);
        copiedSidecars.add(destination);
      }
    }
    await File(exportPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'createdAt': createdAt.toIso8601String(),
        'sourceVersion': sourceVersion,
        'tables': data,
      }),
      flush: true,
    );

    await _verifyBackup(backupPath, sourceVersion, counts);
    final size = await File(backupPath).length();
    final digest = await sha256.bind(File(backupPath).openRead()).first;
    final result = DatabaseBackupResult(
      databasePath: backupPath,
      exportPath: exportPath,
      manifestPath: manifestPath,
      createdAt: createdAt,
      sourceVersion: sourceVersion,
      databaseSize: size,
      sha256: digest.toString(),
      journalMode: journalMode,
      checkpointVerified: checkpointVerified,
      databaseVerified: true,
      tableRowCounts: Map.unmodifiable(counts),
      sidecarPaths: List.unmodifiable(copiedSidecars),
    );
    await File(manifestPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(result.toJson()),
      flush: true,
    );
    return result;
  }

  Future<void> restore({
    required DatabaseBackupResult backup,
    required String targetPath,
  }) async {
    await _verifyBackup(
      backup.databasePath,
      backup.sourceVersion,
      backup.tableRowCounts,
    );
    final digest = await sha256
        .bind(File(backup.databasePath).openRead())
        .first;
    if (digest.toString() != backup.sha256) {
      throw StateError('Backup checksum mismatch');
    }

    await File(backup.databasePath).copy(targetPath);
    for (final suffix in const ['-wal', '-shm']) {
      final targetSidecar = File('$targetPath$suffix');
      if (await targetSidecar.exists()) {
        await targetSidecar.delete();
      }
      final backupSidecar = File('${backup.databasePath}$suffix');
      if (await backupSidecar.exists()) {
        await backupSidecar.copy(targetSidecar.path);
      }
    }
  }

  Future<void> _verifyBackup(
    String backupPath,
    int expectedVersion,
    Map<String, int> expectedCounts,
  ) async {
    Database? verification;
    try {
      verification = await _factory.openDatabase(
        backupPath,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      if (await verification.getVersion() != expectedVersion) {
        throw StateError('Backup database version mismatch');
      }
      final tables = await _tableNames(verification);
      for (final entry in expectedCounts.entries) {
        if (!tables.contains(entry.key)) {
          throw StateError('Backup table missing: ${entry.key}');
        }
        final rows = await verification.rawQuery(
          'SELECT COUNT(*) AS count FROM ${entry.key}',
        );
        final count = (rows.single['count']! as num).toInt();
        if (count != entry.value) {
          throw StateError(
            'Backup row count mismatch for ${entry.key}: $count != ${entry.value}',
          );
        }
      }
    } finally {
      await verification?.close();
    }
  }

  Future<Set<String>> _tableNames(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    return rows.map((row) => row['name']! as String).toSet();
  }

  Map<String, Object?> _jsonSafeRow(Map<String, Object?> row) => {
    for (final entry in row.entries) entry.key: _jsonSafe(entry.value),
  };

  Object? _jsonSafe(Object? value) {
    if (value is Uint8List) {
      return {'encoding': 'base64', 'data': base64Encode(value)};
    }
    return value;
  }
}
