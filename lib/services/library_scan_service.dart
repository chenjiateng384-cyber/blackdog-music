import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:uuid/uuid.dart';

import '../data/migration_repository.dart';
import '../data/file_identity_repository.dart';
import '../data/scan_repository.dart';
import '../models/v4/library_entities.dart';
import '../models/v4/scan_models.dart';
import 'v4_scan_platform.dart';

class LibraryScanService {
  LibraryScanService({
    required ScanRepository repository,
    required MigrationRepository migrationRepository,
    required FileIdentityRepository identityRepository,
    V4ScanPlatform platform = const V4ScanPlatform(),
    Uuid? uuid,
  }) : _repository = repository,
       _migrationRepository = migrationRepository,
       _identityRepository = identityRepository,
       _platform = platform,
       _uuid = uuid ?? const Uuid();

  final ScanRepository _repository;
  final MigrationRepository _migrationRepository;
  final FileIdentityRepository _identityRepository;
  final V4ScanPlatform _platform;
  final Uuid _uuid;
  final StreamController<LibraryScanProgress> _progress =
      StreamController<LibraryScanProgress>.broadcast();
  bool _scanning = false;

  Stream<LibraryScanProgress> get progress => _progress.stream;
  bool get isScanning => _scanning;

  Future<int> recoverInterruptedScans() =>
      _repository.recoverInterruptedScans();

  Future<List<ScanRoot>> scanRoots() => _repository.scanRoots();

  Future<ScanRoot?> chooseRoot({bool makePrimary = false}) async {
    final picked = await _platform.pickScanRoot();
    if (picked == null) return null;
    if (!picked.permissionPersisted) {
      throw StateError('系统没有保存音乐目录的长期读取权限，请重新选择。');
    }
    return _repository.savePickedRoot(picked, makePrimary: makePrimary);
  }

  Future<void> scanAll() async {
    final roots = await _repository.scanRoots(enabledOnly: true);
    for (final root in roots) {
      await scanRoot(root);
    }
  }

  Future<void> scanRoot(ScanRoot root) async {
    if (_scanning) throw StateError('已有音乐扫描正在进行。');
    _scanning = true;
    late final String scanId;
    try {
      final permissionValid = await _platform.validateScanRoot(root.treeUri);
      if (!permissionValid) {
        await _repository.setRootPermission(root.rootId, false);
        throw StateError('“${root.displayName}”目录授权已失效，请重新选择目录。');
      }
      scanId = _uuid.v4();
      await _repository.startScan(scanId: scanId, rootId: root.rootId);
    } catch (_) {
      _scanning = false;
      rethrow;
    }
    final done = Completer<void>();
    var queue = Future<void>.value();
    var discovered = 0;
    var processed = 0;
    var total = 0;
    late StreamSubscription<NativeScanEvent> subscription;
    subscription = _platform.events.listen(
      (event) {
        if (event.scanId != scanId) return;
        queue = queue
            .then((_) async {
              discovered = event.discovered ?? discovered;
              total = event.total ?? total;
              processed = event.processed ?? processed;
              if (event.type == 'batch') {
                _emit(scanId, 'organizing', discovered, processed, total);
                final result = await _repository.ingestBatch(
                  scanId: scanId,
                  root: root,
                  files: event.files,
                );
                for (final link in result.legacyLinks) {
                  await _migrationRepository.linkLegacySong(
                    legacySongId: link.legacySongId,
                    trackId: link.trackId,
                    fileId: link.fileId,
                  );
                }
                _emit(scanId, 'matchingLyrics', discovered, processed, total);
              } else if (event.type == 'complete') {
                if (!done.isCompleted) done.complete();
              } else if (event.type == 'error') {
                final message = event.message ?? '扫描失败';
                await _repository.failScan(scanId, message);
                _emit(
                  scanId,
                  'failed',
                  discovered,
                  processed,
                  total,
                  finished: true,
                  message: message,
                );
                if (!done.isCompleted) done.completeError(StateError(message));
              } else if (event.type == 'cancelled') {
                await _repository.cancelScan(scanId);
                _emit(
                  scanId,
                  'cancelled',
                  discovered,
                  processed,
                  total,
                  finished: true,
                );
                if (!done.isCompleted) done.complete();
              } else {
                _emit(scanId, event.phase, discovered, processed, total);
                await _repository.updateScanProgress(
                  scanId: scanId,
                  discovered: discovered,
                  processed: processed,
                );
              }
            })
            .catchError((Object error, StackTrace stackTrace) async {
              await _repository.failScan(scanId, '$error');
              if (!done.isCompleted) done.completeError(error, stackTrace);
            });
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!done.isCompleted) done.completeError(error, stackTrace);
      },
    );
    try {
      await _platform.startScan(scanId: scanId, treeUri: root.treeUri);
      await done.future;
      await queue;
      final hashJobs = await _identityRepository.pendingHashJobs(scanId);
      var hashed = 0;
      _emit(scanId, 'hashing', discovered, hashed, hashJobs.length);
      for (var offset = 0; offset < hashJobs.length; offset += 12) {
        final end = (offset + 12).clamp(0, hashJobs.length);
        final results = await _platform.hashFiles(
          hashJobs.sublist(offset, end),
        );
        await _identityRepository.applyHashResults(scanId, results);
        hashed += results.length;
        _emit(scanId, 'hashing', discovered, hashed, hashJobs.length);
      }
      _emit(scanId, 'detectingDuplicates', discovered, total, total);
      final identity = await _identityRepository.finalizeIdentity(
        scanId: scanId,
        rootId: root.rootId,
      );
      await _repository.finishScan(
        scanId: scanId,
        rootId: root.rootId,
        total: total,
      );
      _emit(
        scanId,
        'complete',
        discovered,
        total,
        total,
        finished: true,
        message:
            '移动 ${identity.movedFiles}，重复 ${identity.exactDuplicates}，'
            '疑似多版本 ${identity.suspectedVersions}',
      );
    } catch (error) {
      await _repository.failScan(scanId, '$error');
      _emit(
        scanId,
        'failed',
        discovered,
        processed,
        total,
        finished: true,
        message: '$error',
      );
      rethrow;
    } finally {
      await subscription.cancel();
      _scanning = false;
    }
  }

  Future<void> cancel() => _platform.cancelScan();

  Future<void> dispose() async {
    if (_scanning) await cancel();
    await _progress.close();
  }

  void _emit(
    String scanId,
    String phase,
    int discovered,
    int processed,
    int total, {
    bool finished = false,
    String? message,
  }) {
    if (_progress.isClosed) return;
    _progress.add(
      LibraryScanProgress(
        scanId: scanId,
        phase: phase,
        discovered: discovered,
        processed: processed,
        total: total,
        finished: finished,
        message: message,
      ),
    );
  }
}
