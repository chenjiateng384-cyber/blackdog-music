import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../data/data_health_repository.dart';
import '../data/v4_schema.dart';
import '../models/v4/data_safety.dart';
import 'backup_platform.dart';
import 'library_database.dart';
import 'lyrics_service.dart';

class HarmonyBackupService {
  HarmonyBackupService({
    required LibraryDatabase database,
    this._gateway = const BackupPlatform(),
    Future<Directory> Function()? temporaryDirectory,
    Future<Directory> Function()? supportDirectory,
    this.lyricsContentSource = const PlatformLyricsContentSource(),
  }) : _database = database,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _healthRepository = DataHealthRepository(database);

  static const formatVersion = 1;
  static const lastBackupKey = 'harmony.backup.last_success_at.v1';
  static const snoozedUntilKey = 'harmony.backup.snoozed_until.v1';
  static const lastRestoreKey = 'harmony.backup.last_restore_at.v1';
  static const _smartPlayPoolKey = 'harmony.home_smart_play_pool.v1';

  static const _excludedSettings = {
    _smartPlayPoolKey,
    lastBackupKey,
    snoozedUntilKey,
    lastRestoreKey,
  };

  static const _countedTables = [
    'tracks',
    'media_files',
    'track_preferences',
    'playlists',
    'playlist_tracks',
    'play_events',
    'track_stats',
    'track_overrides',
    'lyrics',
  ];

  final LibraryDatabase _database;
  final BackupDocumentGateway _gateway;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<Directory> Function() _supportDirectory;
  final DataHealthRepository _healthRepository;
  final LyricsContentSource lyricsContentSource;
  bool _operationInProgress = false;

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    if (_operationInProgress) throw StateError('另一个备份或恢复操作正在进行');
    _operationInProgress = true;
    try {
      return await operation();
    } finally {
      _operationInProgress = false;
    }
  }

  Future<DataHealthReport> inspectData({String? activePlaybackEventId}) =>
      _healthRepository.inspect(activePlaybackEventId: activePlaybackEventId);

  Future<DateTime?> lastSuccessfulBackupAt() async {
    final value = (await SharedPreferences.getInstance()).getInt(lastBackupKey);
    return value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);
  }

  Future<bool> reminderDue({
    required bool hasMeaningfulData,
    DateTime? now,
  }) async {
    if (!hasMeaningfulData) return false;
    final prefs = await SharedPreferences.getInstance();
    final current = now ?? DateTime.now();
    final snoozed = prefs.getInt(snoozedUntilKey);
    if (snoozed != null &&
        current.isBefore(DateTime.fromMillisecondsSinceEpoch(snoozed))) {
      return false;
    }
    final last = prefs.getInt(lastBackupKey);
    if (last == null) return true;
    return current
            .difference(DateTime.fromMillisecondsSinceEpoch(last))
            .inDays >=
        30;
  }

  Future<void> snoozeReminder([DateTime? now]) async {
    final until = (now ?? DateTime.now()).add(const Duration(days: 7));
    await (await SharedPreferences.getInstance()).setInt(
      snoozedUntilKey,
      until.millisecondsSinceEpoch,
    );
  }

  Future<BackupExportResult?> exportBackup() => _exclusive(_exportBackup);

  Future<BackupExportResult?> _exportBackup() async {
    final health = await inspectData();
    if (!health.integrityOk) {
      throw StateError('数据库完整性检查未通过，未生成备份');
    }
    final workspace = await _createWorkspace('harmony-backup-export');
    try {
      final databasePath = p.join(workspace.path, 'library.db');
      await _database.createConsistentSnapshot(databasePath);
      await _bundleManualArtwork(workspace, databasePath);
      await _bundleManualLyrics(workspace, databasePath);
      await _validateManualResources(workspace, databasePath);
      final settings = await _readPersistentSettings();
      await File(p.join(workspace.path, 'settings.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(settings),
        flush: true,
      );
      final createdAt = DateTime.now();
      final manifest = BackupManifest(
        formatVersion: formatVersion,
        databaseVersion: await _databaseVersion(databasePath),
        appVersion: await _gateway.appVersion(),
        createdAt: createdAt,
        files: await _fileHashes(workspace),
        rowCounts: await _rowCounts(databasePath),
      );
      await File(p.join(workspace.path, 'manifest.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
        flush: true,
      );
      final uri = await _gateway.exportDirectory(
        directoryPath: workspace.path,
        suggestedName: _suggestedName(createdAt),
      );
      if (uri == null) return null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(lastBackupKey, createdAt.millisecondsSinceEpoch);
      await prefs.remove(snoozedUntilKey);
      return BackupExportResult(uri: uri, manifest: manifest);
    } finally {
      await _deleteWorkspace(workspace);
    }
  }

  Future<BackupManifest> inspectBackup(String directoryPath) async {
    final directory = Directory(directoryPath);
    final manifestFile = File(p.join(directory.path, 'manifest.json'));
    final databaseFile = File(p.join(directory.path, 'library.db'));
    if (!await manifestFile.exists() || !await databaseFile.exists()) {
      throw const FormatException('不是有效的黑狗音乐备份文件');
    }
    final json = jsonDecode(await manifestFile.readAsString());
    if (json is! Map<String, Object?>) {
      throw const FormatException('备份清单格式错误');
    }
    final manifest = BackupManifest.fromJson(json);
    if (manifest.formatVersion != formatVersion) {
      throw const FormatException('暂不支持此备份格式版本');
    }
    if (manifest.databaseVersion > V4Schema.version) {
      throw const FormatException('该备份来自更高版本的黑狗音乐，请先升级 App');
    }
    if (manifest.databaseVersion < 4) {
      throw const FormatException('该备份数据库版本过旧');
    }
    if (!manifest.files.containsKey('library.db') ||
        !manifest.files.containsKey('settings.json') ||
        manifest.rowCounts.length != _countedTables.length ||
        !manifest.rowCounts.keys.every(_countedTables.contains)) {
      throw const FormatException('备份清单缺少必要内容或包含未知数据表');
    }
    for (final entry in manifest.files.entries) {
      _safeResourceFile(directory, entry.key);
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.value)) {
        throw const FormatException('备份校验值格式错误');
      }
    }
    final actualHashes = await _fileHashes(directory);
    if (actualHashes.length != manifest.files.length) {
      throw const FormatException('备份文件清单不一致');
    }
    for (final entry in manifest.files.entries) {
      if (actualHashes[entry.key] != entry.value) {
        throw FormatException('备份文件校验失败：${entry.key}');
      }
    }
    await _readValidatedSettings(directory);
    await _validateDatabase(databaseFile.path, manifest.rowCounts);
    if (await _databaseVersion(databaseFile.path) != manifest.databaseVersion) {
      throw const FormatException('备份清单与实际数据库版本不一致');
    }
    await _validateManualResources(directory, databaseFile.path);
    return manifest;
  }

  Future<BackupRestoreResult?> restoreBackup() => _exclusive(_restoreBackup);

  Future<BackupRestoreResult?> _restoreBackup() async {
    final workspace = await _createWorkspace('harmony-backup-import');
    final emergency = await _createWorkspace('harmony-backup-emergency');
    Map<String, Object?>? previousSettings;
    var databaseReplaced = false;
    var committed = false;
    var rollbackFailed = false;
    Directory? restoredAssets;
    try {
      final uri = await _gateway.importPackage(
        destinationDirectory: workspace.path,
      );
      if (uri == null) return null;
      final manifest = await inspectBackup(workspace.path);
      final settings = await _readValidatedSettings(workspace);
      final emergencyDatabase = p.join(emergency.path, 'library.db');
      await _database.createConsistentSnapshot(emergencyDatabase);
      previousSettings = await _readPersistentSettings(includeTransient: true);
      final importedDatabase = p.join(workspace.path, 'library.db');
      final support = await _supportDirectory();
      final assetParent = Directory(
        p.join(support.path, 'harmony_user_assets'),
      );
      await assetParent.create(recursive: true);
      restoredAssets = await assetParent.createTemp('restore-');
      await _restoreManualArtwork(workspace, importedDatabase, restoredAssets);
      await _restoreManualLyrics(workspace, importedDatabase, restoredAssets);
      await _database.replaceWithBackup(importedDatabase);
      databaseReplaced = true;
      await _restoreSettings(settings);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_smartPlayPoolKey);
      await prefs.setInt(
        lastBackupKey,
        manifest.createdAt.millisecondsSinceEpoch,
      );
      await prefs.setInt(lastRestoreKey, DateTime.now().millisecondsSinceEpoch);
      await prefs.remove(snoozedUntilKey);
      committed = true;
      return BackupRestoreResult(manifest: manifest);
    } catch (_) {
      try {
        if (databaseReplaced) {
          await _database.replaceWithBackup(
            p.join(emergency.path, 'library.db'),
          );
        }
        if (previousSettings != null) {
          await _restoreSettings(previousSettings, includeTransient: true);
        }
      } catch (exception) {
        rollbackFailed = true;
        throw StateError('回退未完成，紧急快照已保留：${emergency.path}；$exception');
      }
      rethrow;
    } finally {
      if (!committed && !rollbackFailed && restoredAssets != null) {
        await _deleteWorkspace(restoredAssets);
      }
      await _deleteWorkspace(workspace);
      if (!rollbackFailed) await _deleteWorkspace(emergency);
    }
  }

  Future<Directory> _createWorkspace(String prefix) async {
    final parent = await _temporaryDirectory();
    return Directory(
      p.join(parent.path, '$prefix-${DateTime.now().microsecondsSinceEpoch}'),
    ).create(recursive: true);
  }

  Future<void> _deleteWorkspace(Directory directory) async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<void> _bundleManualArtwork(
    Directory workspace,
    String databasePath,
  ) async {
    final db = await _database.factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final rows = await db.query(
        'artwork_assets',
        columns: ['artwork_id', 'cache_path'],
        where: "source = 'manual' AND cache_path IS NOT NULL",
      );
      for (final row in rows) {
        final source = File(row['cache_path'] as String);
        if (!await source.exists()) throw StateError('人工封面文件缺失，请先重新选择封面');
        _validateResourceId('${row['artwork_id']}');
        final extension = p.extension(source.path);
        final relative = p.join(
          'assets',
          '${row['artwork_id']}${extension.isEmpty ? '.img' : extension}',
        );
        final target = File(p.join(workspace.path, relative));
        await target.parent.create(recursive: true);
        await source.copy(target.path);
        await db.update(
          'artwork_assets',
          {
            'cache_path':
                'harmony-backup://${p.posix.normalize(relative.replaceAll('\\', '/'))}',
          },
          where: 'artwork_id = ?',
          whereArgs: [row['artwork_id']],
        );
      }
    } finally {
      await db.close();
    }
  }

  Future<void> _restoreManualArtwork(
    Directory workspace,
    String databasePath,
    Directory destination,
  ) async {
    final db = await _database.factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final rows = await db.query(
        'artwork_assets',
        columns: ['artwork_id', 'cache_path'],
        where: "source = 'manual' AND cache_path LIKE 'harmony-backup://%'",
      );
      for (final row in rows) {
        final stored = row['cache_path'] as String;
        final relative = stored.substring('harmony-backup://'.length);
        _validateResourceId('${row['artwork_id']}');
        final source = _safeResourceFile(workspace, relative);
        if (!await source.exists()) {
          throw FormatException('备份中的人工封面缺失：$relative');
        }
        final target = File(
          p.join(
            destination.path,
            '${row['artwork_id']}${p.extension(source.path)}',
          ),
        );
        await source.copy(target.path);
        await db.update(
          'artwork_assets',
          {'cache_path': target.path},
          where: 'artwork_id = ?',
          whereArgs: [row['artwork_id']],
        );
      }
    } finally {
      await db.close();
    }
  }

  File _safeResourceFile(Directory root, String relative) {
    if (relative.isEmpty ||
        relative.contains('\\') ||
        relative.contains(':') ||
        relative.contains('\u0000') ||
        p.posix.isAbsolute(relative) ||
        p.posix.normalize(relative) != relative ||
        relative.split('/').contains('..') ||
        (relative != 'library.db' &&
            relative != 'settings.json' &&
            !relative.startsWith('assets/'))) {
      throw const FormatException('备份包含非法资源路径');
    }
    return File(p.joinAll([root.path, ...relative.split('/')]));
  }

  void _validateResourceId(String value) {
    if (!RegExp(r'^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$')
        .hasMatch(value)) {
      throw const FormatException('备份资源标识无效');
    }
  }

  Future<Map<String, Object?>> _readValidatedSettings(Directory root) async {
    final value = jsonDecode(
      await File(p.join(root.path, 'settings.json')).readAsString(),
    );
    if (value is! Map<String, dynamic>) throw const FormatException('设置备份格式错误');
    for (final entry in value.entries) {
      final setting = entry.value;
      if (!entry.key.startsWith('harmony.') ||
          _excludedSettings.contains(entry.key) ||
          !(setting is bool ||
              setting is String ||
              setting is int ||
              (setting is double && setting.isFinite) ||
              (setting is List && setting.every((item) => item is String)))) {
        throw const FormatException('备份设置名称或类型无效');
      }
    }
    return value;
  }

  Future<void> _validateManualResources(
    Directory workspace,
    String databasePath,
  ) async {
    final db = await _database.factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      for (final query in [
        "SELECT artwork_id AS id, cache_path AS path FROM artwork_assets WHERE source = 'manual'",
        "SELECT lyrics_id AS id, COALESCE(document_uri, content_uri) AS path FROM lyrics WHERE source = 'manual'",
      ]) {
        for (final row in await db.rawQuery(query)) {
          _validateResourceId('${row['id']}');
          final stored = row['path'];
          if (stored is! String ||
              !stored.startsWith('harmony-backup://assets/')) {
            throw const FormatException('备份未包含必要的人工资源文件');
          }
          final file = _safeResourceFile(
            workspace,
            stored.substring('harmony-backup://'.length),
          );
          if (!await file.exists()) throw const FormatException('备份中的人工资源文件缺失');
        }
      }
    } finally {
      await db.close();
    }
  }

  Future<void> _bundleManualLyrics(
    Directory workspace,
    String databasePath,
  ) async {
    final db = await _database.factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final rows = await db.query('lyrics', where: "source = 'manual'");
      for (final row in rows) {
        final id = '${row['lyrics_id']}';
        _validateResourceId(id);
        final uri = row['document_uri'] ?? row['content_uri'];
        if (uri is! String || uri.isEmpty) throw StateError('人工歌词文件缺失');
        final parsed = Uri.parse(uri);
        final local = parsed.scheme == 'file' ? File.fromUri(parsed) : null;
        if (local != null && await local.length() > 2 * 1024 * 1024) {
          throw StateError('人工歌词文件超过2MB');
        }
        final bytes = local != null
            ? await local.readAsBytes()
            : utf8.encode(await lyricsContentSource.read(uri));
        if (bytes.length > 2 * 1024 * 1024) throw StateError('人工歌词文件超过2MB');
        final relative = 'assets/lyrics-$id.lrc';
        final target = _safeResourceFile(workspace, relative);
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes, flush: true);
        await db.update(
          'lyrics',
          {
            'document_uri': 'harmony-backup://$relative',
            'content_uri': null,
            'size_bytes': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
          },
          where: 'lyrics_id = ?',
          whereArgs: [id],
        );
      }
    } finally {
      await db.close();
    }
  }

  Future<void> _restoreManualLyrics(
    Directory workspace,
    String databasePath,
    Directory destination,
  ) async {
    final db = await _database.factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      for (final row in await db.query('lyrics', where: "source = 'manual'")) {
        final stored = row['document_uri'] as String;
        final source = _safeResourceFile(
          workspace,
          stored.substring('harmony-backup://'.length),
        );
        final target = File(
          p.join(destination.path, 'lyrics-${row['lyrics_id']}.lrc'),
        );
        await source.copy(target.path);
        await db.update(
          'lyrics',
          {'document_uri': target.uri.toString(), 'content_uri': null},
          where: 'lyrics_id = ?',
          whereArgs: [row['lyrics_id']],
        );
      }
    } finally {
      await db.close();
    }
  }

  Future<Map<String, Object?>> _readPersistentSettings({
    bool includeTransient = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final key in prefs.getKeys())
        if (key.startsWith('harmony.') &&
            (includeTransient || !_excludedSettings.contains(key)))
          key: prefs.get(key),
    };
  }

  Future<void> _restoreSettings(
    Object? value, {
    bool includeTransient = false,
  }) async {
    if (value is! Map) throw const FormatException('设置备份格式错误');
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().where(
      (key) =>
          key.startsWith('harmony.') &&
          (includeTransient || !_excludedSettings.contains(key)),
    )) {
      if (!await prefs.remove(key)) throw StateError('无法移除旧设置，恢复未完成');
    }
    for (final entry in value.entries) {
      final key = '${entry.key}';
      if (!key.startsWith('harmony.') ||
          (!includeTransient && _excludedSettings.contains(key))) {
        continue;
      }
      final setting = entry.value;
      bool saved;
      if (setting is bool) {
        saved = await prefs.setBool(key, setting);
      } else if (setting is int) {
        saved = await prefs.setInt(key, setting);
      } else if (setting is double) {
        saved = await prefs.setDouble(key, setting);
      } else if (setting is String) {
        saved = await prefs.setString(key, setting);
      } else if (setting is List) {
        saved = await prefs.setStringList(key, setting.cast<String>());
      } else {
        throw const FormatException('设置类型无效');
      }
      if (!saved) throw StateError('无法保存恢复设置');
    }
  }

  Future<Map<String, String>> _fileHashes(Directory root) async {
    final result = <String, String>{};
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Link) throw const FormatException('备份不能包含符号链接');
      if (entity is! File ||
          entity.path == p.join(root.path, 'manifest.json')) {
        continue;
      }
      final relative = p
          .relative(entity.path, from: root.path)
          .replaceAll('\\', '/');
      _safeResourceFile(root, relative);
      result[relative] = (await sha256.bind(entity.openRead()).first)
          .toString();
    }
    return result;
  }

  Future<int> _databaseVersion(String path) async {
    final db = await _database.factory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      return await db.getVersion();
    } finally {
      await db.close();
    }
  }

  Future<Map<String, int>> _rowCounts(String path) async {
    final db = await _database.factory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      return {
        for (final table in _countedTables)
          table:
              Sqflite.firstIntValue(
                await db.rawQuery('SELECT COUNT(*) FROM $table'),
              ) ??
              0,
      };
    } finally {
      await db.close();
    }
  }

  Future<void> _validateDatabase(
    String path,
    Map<String, int> expectedCounts,
  ) async {
    final db = await _database.factory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final integrity = await db.rawQuery('PRAGMA integrity_check');
      if (integrity.length != 1 ||
          '${integrity.single.values.first}'.toLowerCase() != 'ok') {
        throw const FormatException('备份数据库完整性检查失败');
      }
      final foreignKeys = await db.rawQuery('PRAGMA foreign_key_check');
      if (foreignKeys.isNotEmpty) {
        throw const FormatException('备份数据库存在关联异常');
      }
      for (final entry in expectedCounts.entries) {
        if (!_countedTables.contains(entry.key) || entry.value < 0) {
          throw const FormatException('备份数据表或数量无效');
        }
        final actual =
            Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM ${entry.key}'),
            ) ??
            0;
        if (actual != entry.value) {
          throw FormatException('备份数据数量不一致：${entry.key}');
        }
      }
    } finally {
      await db.close();
    }
  }

  String _suggestedName(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '黑狗音乐-${time.year}${two(time.month)}${two(time.day)}-'
        '${two(time.hour)}${two(time.minute)}.harmonybackup';
  }
}
