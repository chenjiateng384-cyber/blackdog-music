import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/file_identity_repository.dart';
import 'package:my_music_library/data/scan_repository.dart';
import 'package:my_music_library/models/v4/library_entities.dart';
import 'package:my_music_library/models/v4/scan_models.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDirectory;
  late LibraryDatabase library;
  late ScanRepository scanRepository;
  late FileIdentityRepository identityRepository;
  late ScanRoot root;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('file-identity-');
    library = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${tempDirectory.path}/library.db',
    );
    scanRepository = ScanRepository(library);
    identityRepository = FileIdentityRepository(library);
    root = await scanRepository.savePickedRoot(
      const PickedScanRoot(
        treeUri: 'content://tree/real-music',
        displayName: '音乐文件',
        permissionPersisted: true,
      ),
    );
  });
  tearDown(() async {
    await library.close();
    await tempDirectory.delete(recursive: true);
  });

  test('文件大小和修改时间不变时复用 SHA-256，不重新计算', () async {
    const firstScan = '00000000-0000-4000-8000-000000000301';
    const secondScan = '00000000-0000-4000-8000-000000000302';
    final file = audio('周杰伦/2004_七里香/03_借口.flac');
    await _startAndIngest(scanRepository, root, firstScan, [file]);
    var jobs = await identityRepository.pendingHashJobs(firstScan);
    expect(jobs, hasLength(1));
    await identityRepository.applyHashResults(firstScan, [
      hashResult(jobs.single, hashA),
    ]);
    await identityRepository.finalizeIdentity(
      scanId: firstScan,
      rootId: root.rootId,
    );
    await scanRepository.finishScan(
      scanId: firstScan,
      rootId: root.rootId,
      total: 1,
    );

    final db = await library.database;
    final firstRow = (await db.query('media_files')).single;
    final stableFileId = firstRow['file_id'];
    final stableTrackId = firstRow['track_id'];
    await _startAndIngest(scanRepository, root, secondScan, [
      file.copyWith(mediaStoreId: 999, contentUri: 'content://media/new-id'),
    ]);
    jobs = await identityRepository.pendingHashJobs(secondScan);
    expect(jobs, isEmpty);
    final secondRow = (await db.query('media_files')).single;
    expect(secondRow['file_id'], stableFileId);
    expect(secondRow['track_id'], stableTrackId);
    expect(secondRow['sha256'], hashA);
    expect(secondRow['media_store_id'], 999);
  });

  test('相同 MediaStore ID 在路径变化后立即复用稳定身份', () async {
    const firstScan = '00000000-0000-4000-8000-000000000305';
    const secondScan = '00000000-0000-4000-8000-000000000306';
    final original = audio(
      '周杰伦/2004_七里香/03_借口.flac',
      mediaStoreId: 77,
      contentUri: 'content://media/77',
    );
    await _startAndIngest(scanRepository, root, firstScan, [original]);
    final db = await library.database;
    final stable = (await db.query('media_files')).single;

    final moved = audio(
      '周杰伦/重新整理/借口.flac',
      mediaStoreId: 77,
      contentUri: 'content://media/77-renamed',
    );
    await _startAndIngest(scanRepository, root, secondScan, [moved]);
    final after = (await db.query('media_files')).single;
    expect(await db.query('media_files'), hasLength(1));
    expect(await db.query('tracks'), hasLength(1));
    expect(after['file_id'], stable['file_id']);
    expect(after['track_id'], stable['track_id']);
    expect(after['relative_path'], moved.relativePath);
    expect(after['content_uri'], moved.contentUri);
  });

  test('真实内容 Hash 相同且旧路径消失时保留稳定 FileId、TrackId 和喜欢状态', () async {
    const firstScan = '00000000-0000-4000-8000-000000000311';
    const secondScan = '00000000-0000-4000-8000-000000000312';
    await _startAndIngest(scanRepository, root, firstScan, [
      audio('周杰伦/2004_七里香/03_借口.flac'),
    ]);
    final firstJob = (await identityRepository.pendingHashJobs(firstScan))
        .single;
    await identityRepository.applyHashResults(firstScan, [
      hashResult(firstJob, hashA),
    ]);
    await identityRepository.finalizeIdentity(
      scanId: firstScan,
      rootId: root.rootId,
    );
    await scanRepository.finishScan(
      scanId: firstScan,
      rootId: root.rootId,
      total: 1,
    );
    final db = await library.database;
    final stable = (await db.query('media_files')).single;
    await db.insert('track_preferences', {
      'track_id': stable['track_id'],
      'liked': 1,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });

    await _startAndIngest(scanRepository, root, secondScan, [
      audio('周杰伦/2004_七里香/03_借口_已移动.flac'),
    ]);
    final movedJob = (await identityRepository.pendingHashJobs(secondScan))
        .single;
    await identityRepository.applyHashResults(secondScan, [
      hashResult(movedJob, hashA),
    ]);
    final summary = await identityRepository.finalizeIdentity(
      scanId: secondScan,
      rootId: root.rootId,
    );
    expect(summary.movedFiles, 1);
    final files = await db.query('media_files');
    expect(files, hasLength(1));
    expect(files.single['file_id'], stable['file_id']);
    expect(files.single['track_id'], stable['track_id']);
    expect(files.single['relative_path'], contains('已移动'));
    expect(await db.query('tracks'), hasLength(1));
    expect((await db.query('track_preferences')).single['liked'], 1);
  });

  test('完全相同 Hash 保留两个文件并归入同一稳定 Track', () async {
    const scanId = '00000000-0000-4000-8000-000000000321';
    await _startAndIngest(scanRepository, root, scanId, [
      audio('周杰伦/2004_七里香/03_借口.flac'),
      audio('周杰伦/_待处理_重复与问题文件/借口副本.flac'),
    ]);
    final db = await library.database;
    final before = await db.query(
      'media_files',
      orderBy: 'created_at, file_id',
    );
    final manuallyPreferred = before.last;
    await db.update(
      'tracks',
      {
        'preferred_media_file_id': manuallyPreferred['file_id'],
        'preferred_file_source': 'manual',
      },
      where: 'track_id = ?',
      whereArgs: [manuallyPreferred['track_id']],
    );
    final jobs = await identityRepository.pendingHashJobs(scanId);
    await identityRepository.applyHashResults(
      scanId,
      jobs.map((job) => hashResult(job, hashA)).toList(),
    );
    final summary = await identityRepository.finalizeIdentity(
      scanId: scanId,
      rootId: root.rootId,
    );
    expect(summary.exactDuplicates, 1);
    expect(await db.query('media_files'), hasLength(2));
    expect(await db.query('tracks'), hasLength(1));
    expect(
      (await db.query('media_files')).map((row) => row['track_id']).toSet(),
      hasLength(1),
    );
    final duplicate = (await db.query(
      'media_files',
      where: 'status = ?',
      whereArgs: ['duplicate'],
    )).single;
    expect(duplicate['duplicate_of_file_id'], isNotNull);
    expect(
      (await db.query('media_file_relations')).single['relation_type'],
      'exactDuplicate',
    );
    final mergedTrack = (await db.query('tracks')).single;
    expect(mergedTrack['preferred_file_source'], 'manual');
    expect(
      mergedTrack['preferred_media_file_id'],
      manuallyPreferred['file_id'],
    );
  });

  test('不同 Hash 的 FLAC/MP3 仅记录疑似多版本，不自动合并', () async {
    const scanId = '00000000-0000-4000-8000-000000000331';
    await _startAndIngest(scanRepository, root, scanId, [
      audio(
        '周杰伦/2004_七里香/03_借口.flac',
        title: '借口',
        artist: '周杰伦',
        bitrate: 1411000,
        bitDepth: 16,
      ),
      audio('周杰伦/EP与单曲/借口.mp3', title: '借口', artist: '周杰伦', bitrate: 320000),
    ]);
    final jobs = await identityRepository.pendingHashJobs(scanId);
    await identityRepository.applyHashResults(scanId, [
      hashResult(jobs[0], hashA),
      hashResult(jobs[1], hashB),
    ]);
    final summary = await identityRepository.finalizeIdentity(
      scanId: scanId,
      rootId: root.rootId,
    );
    final db = await library.database;
    expect(summary.suspectedVersions, 1);
    expect(await db.query('tracks'), hasLength(2));
    expect(
      await db.query('media_files', where: 'status = ?', whereArgs: ['active']),
      hasLength(2),
    );
    final relation = (await db.query('media_file_relations')).single;
    expect(relation['relation_type'], 'suspectedVersion');
    final reason = jsonDecode(relation['reason_json']! as String) as Map;
    final flac = (await db.query(
      'media_files',
      where: 'extension = ?',
      whereArgs: ['flac'],
    )).single;
    expect(reason['suggestedPreferredFileId'], flac['file_id']);
    expect(reason['automaticMerge'], isFalse);
  });
}

const hashA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const hashB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final modifiedAt = DateTime.fromMillisecondsSinceEpoch(1700000000000);

Future<void> _startAndIngest(
  ScanRepository repository,
  ScanRoot root,
  String scanId,
  List<ScannedAudioFile> files,
) async {
  await repository.startScan(scanId: scanId, rootId: root.rootId);
  await repository.ingestBatch(scanId: scanId, root: root, files: files);
}

FileHashResult hashResult(FileHashJob job, String hash) => FileHashResult(
  fileId: job.fileId,
  sha256: hash,
  sizeBytes: job.sizeBytes,
  modifiedAt: job.modifiedAt,
  state: 'ready',
);

ScannedAudioFile audio(
  String relativePath, {
  String? title,
  String? artist,
  int bitrate = 1000000,
  int? bitDepth,
  int? mediaStoreId,
  String? contentUri,
}) {
  final filename = relativePath.split('/').last;
  return ScannedAudioFile(
    documentUri: 'content://document/$relativePath',
    relativePath: relativePath,
    parentFolder: relativePath.split('/').reversed.elementAt(1),
    filename: filename,
    extension: filename.split('.').last,
    mimeType: filename.endsWith('.mp3') ? 'audio/mpeg' : 'audio/flac',
    sizeBytes: 1000000,
    modifiedAt: modifiedAt,
    mediaStoreVolume: mediaStoreId == null ? null : 'external_primary',
    mediaStoreId: mediaStoreId,
    contentUri: contentUri,
    metadata: AudioTagSnapshot(
      title: title,
      artist: artist,
      albumArtist: artist,
      album: title == null ? null : '七里香',
      durationMs: 180000,
      bitrate: bitrate,
      sampleRate: 44100,
      bitDepth: bitDepth,
      readStatus: title == null ? 'partial' : 'complete',
    ),
    lyricsCandidates: const [],
  );
}

extension on ScannedAudioFile {
  ScannedAudioFile copyWith({int? mediaStoreId, String? contentUri}) =>
      ScannedAudioFile(
        documentUri: documentUri,
        relativePath: relativePath,
        parentFolder: parentFolder,
        filename: filename,
        extension: extension,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        modifiedAt: modifiedAt,
        mediaStoreVolume: mediaStoreVolume,
        mediaStoreId: mediaStoreId ?? this.mediaStoreId,
        contentUri: contentUri ?? this.contentUri,
        dateAdded: dateAdded,
        metadata: metadata,
        lyricsCandidates: lyricsCandidates,
      );
}
