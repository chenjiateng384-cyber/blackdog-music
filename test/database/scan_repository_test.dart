import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/scan_repository.dart';
import 'package:my_music_library/data/library_repository.dart';
import 'package:my_music_library/models/v4/scan_models.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDirectory;
  late LibraryDatabase library;
  late ScanRepository repository;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('scan-repository-');
    library = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${tempDirectory.path}/library.db',
    );
    repository = ScanRepository(library);
  });
  tearDown(() async {
    await library.close();
    await tempDirectory.delete(recursive: true);
  });

  test('ScanRoot 长期授权信息可保存，删除根目录不删除歌曲', () async {
    final root = await repository.savePickedRoot(
      const PickedScanRoot(
        treeUri: 'content://tree/music',
        displayName: '音乐文件',
        volumeName: 'primary',
        relativePathHint: 'Music/音乐文件',
        permissionPersisted: true,
      ),
    );
    await repository.startScan(scanId: scanId, rootId: root.rootId);
    await repository.ingestBatch(
      scanId: scanId,
      root: root,
      files: [audio('周杰伦/2004_七里香/03_借口.flac')],
    );
    await repository.removeScanRoot(root.rootId);
    final db = await library.database;
    expect(await db.query('scan_roots'), isEmpty);
    expect(await db.query('tracks'), hasLength(1));
    expect((await db.query('media_files')).single['scan_root_id'], isNull);
  });

  test('真实目录建立 Track、MediaFile、Raw、推断、专辑曲序和 LRC', () async {
    final root = await createRoot(repository);
    await repository.startScan(scanId: scanId, rootId: root.rootId);
    await repository.ingestBatch(
      scanId: scanId,
      root: root,
      files: [
        audio('周杰伦/2004_七里香/03_借口.flac', lyricsName: '借口.lrc'),
        audio('周杰伦/2004_七里香/01_我的地盘.flac', title: '我的地盘', trackNumber: 1),
        audio(
          '英文歌/Avicii - AIN’T A THING.mp3',
          title: 'AIN’T A THING',
          artist: 'Avicii',
          album: 'TIM',
          trackNumber: 2,
        ),
      ],
    );
    await repository.finishScan(scanId: scanId, rootId: root.rootId, total: 3);
    final db = await library.database;
    expect(await db.query('tracks'), hasLength(3));
    expect(await db.query('media_files'), hasLength(3));
    expect(await db.query('file_metadata_raw'), hasLength(3));
    expect(await db.query('inferred_metadata'), hasLength(3));
    final jay = await db.query(
      'tracks',
      where: 'artist_display = ?',
      whereArgs: ['周杰伦'],
      orderBy: 'disc_number, track_number',
    );
    expect(jay.map((row) => row['track_number']), [1, 3]);
    expect(jay.every((row) => row['album_display'] == '七里香'), isTrue);
    expect(jay.every((row) => row['year'] == 2004), isTrue);
    final lyric = (await db.query('lyrics')).single;
    expect(lyric['source'], 'sidecarLrc');
    expect(lyric['match_method'], 'normalizedWithoutTrack');
    expect(lyric['is_selected'], 1);
    final english = (await db.query(
      'tracks',
      where: 'artist_display = ?',
      whereArgs: ['Avicii'],
    )).single;
    expect(english['title'], 'AIN’T A THING');
    expect(english['album_display'], 'TIM');
  });

  test('重新扫描复用 MediaFile 与 Track，人工 Override 不被覆盖', () async {
    final root = await createRoot(repository);
    await repository.startScan(scanId: scanId, rootId: root.rootId);
    final file = audio('周杰伦/2004_七里香/03_借口.flac');
    await repository.ingestBatch(scanId: scanId, root: root, files: [file]);
    final db = await library.database;
    final firstTrack = (await db.query('tracks')).single['track_id'];
    final firstFile = (await db.query('media_files')).single['file_id'];
    await db.insert('track_overrides', {
      'track_id': firstTrack,
      'title': '人工借口',
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
    const secondScan = '00000000-0000-4000-8000-000000000202';
    await repository.startScan(scanId: secondScan, rootId: root.rootId);
    await repository.ingestBatch(scanId: secondScan, root: root, files: [file]);
    expect(await db.query('tracks'), hasLength(1));
    expect(await db.query('media_files'), hasLength(1));
    expect((await db.query('tracks')).single['track_id'], firstTrack);
    expect((await db.query('media_files')).single['file_id'], firstFile);
    expect((await db.query('tracks')).single['title'], '人工借口');
  });

  test('扫描保存内嵌、同名图片和目录封面并保持明确优先级', () async {
    final root = await createRoot(repository);
    await repository.startScan(scanId: scanId, rootId: root.rootId);
    await repository.ingestBatch(
      scanId: scanId,
      root: root,
      files: [
        audio(
          '周杰伦/2004_七里香/03_借口.flac',
          embeddedArtworkPath: '${tempDirectory.path}/embedded.jpg',
          localArtworkPath: '${tempDirectory.path}/借口.jpg',
          localArtworkSource: 'sidecar',
        ),
      ],
    );
    final rows = await (await library.database).query(
      'artwork_assets',
      orderBy: 'source',
    );
    expect(rows, hasLength(2));
    expect(rows.map((row) => row['source']).toSet(), {'embedded'});
    expect(rows.map((row) => row['confidence']).toSet(), {1.0, 0.98});
  });

  test('歌手目录和专用歌手图独立保存，不进入歌曲封面表', () async {
    final root = await createRoot(repository);
    await repository.startScan(scanId: scanId, rootId: root.rootId);
    await repository.ingestBatch(
      scanId: scanId,
      root: root,
      files: [
        audio(
          '周杰伦/2004_七里香/03_借口.flac',
          artist: '周杰伦 & 杨瑞代',
          libraryArtistFolderName: '周杰伦',
          artistArtworkPath: '${tempDirectory.path}/歌手封面.jpg',
        ),
      ],
    );

    final db = await library.database;
    final profile = (await db.query('artist_profiles')).single;
    expect(profile['relative_directory'], '周杰伦');
    expect(profile['artwork_cache_path'], '${tempDirectory.path}/歌手封面.jpg');
    expect(await db.query('artwork_assets'), isEmpty);
    final artists = await LibraryRepository(library).artists();
    expect(artists.single.artist.displayName, '周杰伦');
    expect(artists.single.isCuratedFolder, isTrue);
    expect(artists.single.artwork?.cachePath, '${tempDirectory.path}/歌手封面.jpg');
  });

  test('同名文件不自动合并为同一个 Track', () async {
    final root = await createRoot(repository);
    await repository.startScan(scanId: scanId, rootId: root.rootId);
    await repository.ingestBatch(
      scanId: scanId,
      root: root,
      files: [
        audio('周杰伦/专辑A/稻香.flac', title: '稻香'),
        audio('周杰伦/专辑B/稻香.mp3', title: '稻香'),
      ],
    );
    final db = await library.database;
    expect(await db.query('tracks'), hasLength(2));
    expect(await db.query('media_files'), hasLength(2));
  });

  test('新扫描开始前自动结束旧的 running 任务', () async {
    final root = await createRoot(repository);
    const oldScan = '00000000-0000-4000-8000-000000000211';
    const newScan = '00000000-0000-4000-8000-000000000212';
    await repository.startScan(scanId: oldScan, rootId: root.rootId);
    await repository.updateScanProgress(
      scanId: oldScan,
      discovered: 10,
      processed: 3,
    );

    await repository.startScan(scanId: newScan, rootId: root.rootId);
    final db = await library.database;
    final old = (await db.query(
      'scan_runs',
      where: 'scan_id = ?',
      whereArgs: [oldScan],
    )).single;
    final current = (await db.query(
      'scan_runs',
      where: 'scan_id = ?',
      whereArgs: [newScan],
    )).single;
    expect(old['status'], 'failed');
    expect(old['finished_at'], isNotNull);
    expect(old['error'], contains('interrupted'));
    expect(old['discovered_count'], 10);
    expect(old['processed_count'], 3);
    expect(current['status'], 'running');
    expect(current['finished_at'], isNull);
  });

  test('启动恢复僵尸扫描是幂等的，成功和失败都有完整收尾', () async {
    final root = await createRoot(repository);
    const interrupted = '00000000-0000-4000-8000-000000000213';
    await repository.startScan(scanId: interrupted, rootId: root.rootId);
    expect(await repository.recoverInterruptedScans(), 1);
    expect(await repository.recoverInterruptedScans(), 0);

    const completed = '00000000-0000-4000-8000-000000000214';
    await repository.startScan(scanId: completed, rootId: root.rootId);
    await repository.finishScan(
      scanId: completed,
      rootId: root.rootId,
      total: 0,
    );
    const failed = '00000000-0000-4000-8000-000000000215';
    await repository.startScan(scanId: failed, rootId: root.rootId);
    await repository.failScan(failed, 'test failure');

    final db = await library.database;
    for (final id in [interrupted, completed, failed]) {
      final row = (await db.query(
        'scan_runs',
        where: 'scan_id = ?',
        whereArgs: [id],
      )).single;
      expect(row['finished_at'], isNotNull);
    }
    expect(
      (await db.query(
        'scan_runs',
        where: 'scan_id = ?',
        whereArgs: [completed],
      )).single['status'],
      'completed',
    );
    expect(
      (await db.query(
        'scan_runs',
        where: 'scan_id = ?',
        whereArgs: [failed],
      )).single['status'],
      'failed',
    );
  });

  test('只有 missing 文件的 Track 不展示且用户关联数据不丢失', () async {
    final root = await createRoot(repository);
    const firstScan = '00000000-0000-4000-8000-000000000216';
    await repository.startScan(scanId: firstScan, rootId: root.rootId);
    await repository.ingestBatch(
      scanId: firstScan,
      root: root,
      files: [audio('周杰伦/2004_七里香/03_借口.flac')],
    );
    await repository.finishScan(
      scanId: firstScan,
      rootId: root.rootId,
      total: 1,
    );
    final db = await library.database;
    final trackId = (await db.query('tracks')).single['track_id']! as String;
    await db.insert('track_preferences', {
      'track_id': trackId,
      'liked': 1,
      'recommendation_excluded': 0,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });

    const emptyScan = '00000000-0000-4000-8000-000000000217';
    await repository.startScan(scanId: emptyScan, rootId: root.rootId);
    await repository.finishScan(
      scanId: emptyScan,
      rootId: root.rootId,
      total: 0,
    );

    final libraryRepository = LibraryRepository(library);
    expect(await libraryRepository.allTracks(), isEmpty);
    expect(
      await libraryRepository.allTracks(includeUnavailable: true),
      hasLength(1),
    );
    expect((await db.query('tracks')).single['track_id'], trackId);
    expect((await db.query('track_preferences')).single['liked'], 1);
    expect((await db.query('media_files')).single['status'], 'missing');
  });

  test('占位单曲不建专辑，合作 Artist 差异不拆分真实专辑', () async {
    final root = await createRoot(repository);
    const id = '00000000-0000-4000-8000-000000000218';
    await repository.startScan(scanId: id, rootId: root.rootId);
    await repository.ingestBatch(
      scanId: id,
      root: root,
      files: [
        audio(
          '英文歌/Loose One.mp3',
          title: 'Loose One',
          artist: 'Singer',
          album: '单曲',
        ),
        audio(
          'Max Oazo/Once upon a Time/01_First.flac',
          title: 'First',
          artist: 'Max Oazo',
          album: 'Once upon a Time',
          trackNumber: 1,
        ),
        audio(
          'Max Oazo/Once upon a Time/02_Second.flac',
          title: 'Second',
          artist: 'Max Oazo&Moonessa',
          album: 'Once upon a Time',
          trackNumber: 2,
        ),
      ],
    );
    await repository.finishScan(scanId: id, rootId: root.rootId, total: 3);
    final db = await library.database;
    final loose = (await db.query(
      'tracks',
      where: 'title = ?',
      whereArgs: ['Loose One'],
    )).single;
    expect(loose['album_id'], isNull);
    expect(loose['album_display'], '未知专辑');
    expect(
      await db.query(
        'file_metadata_raw',
        where: 'album = ?',
        whereArgs: ['单曲'],
      ),
      hasLength(1),
    );
    final albumTracks = await db.query(
      'tracks',
      where: 'album_display = ?',
      whereArgs: ['Once upon a Time'],
    );
    expect(albumTracks, hasLength(2));
    expect(albumTracks.map((row) => row['album_id']).toSet(), hasLength(1));
    expect(await db.query('albums'), hasLength(1));
    expect(albumTracks.map((row) => row['artist_display']).toSet(), {
      'Max Oazo',
      'Max Oazo&Moonessa',
    });
  });

  test('1000 首分批入库不会一次占用整库内存且在合理时间完成', () async {
    final root = await createRoot(repository);
    await repository.startScan(scanId: scanId, rootId: root.rootId);
    final stopwatch = Stopwatch()..start();
    for (var offset = 0; offset < 1000; offset += 20) {
      final batch = List.generate(20, (index) {
        final number = offset + index + 1;
        return audio(
          '周杰伦/2004_七里香/${number.toString().padLeft(3, '0')}_测试$number.flac',
          title: '测试$number',
          trackNumber: number,
        );
      });
      await repository.ingestBatch(scanId: scanId, root: root, files: batch);
    }
    stopwatch.stop();
    final db = await library.database;
    expect(await db.query('tracks'), hasLength(1000));
    expect(await db.query('media_files'), hasLength(1000));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 30)));
  });
}

const scanId = '00000000-0000-4000-8000-000000000201';

Future<dynamic> createRoot(ScanRepository repository) =>
    repository.savePickedRoot(
      const PickedScanRoot(
        treeUri: 'content://tree/music',
        displayName: '音乐文件',
        permissionPersisted: true,
      ),
    );

ScannedAudioFile audio(
  String relativePath, {
  String? title,
  String? artist,
  String? album,
  int? trackNumber,
  String? lyricsName,
  String? embeddedArtworkPath,
  String? localArtworkPath,
  String? localArtworkSource,
  String? libraryArtistFolderName,
  String? artistArtworkPath,
}) {
  final filename = relativePath.split('/').last;
  return ScannedAudioFile(
    documentUri: 'content://document/$relativePath',
    relativePath: relativePath,
    parentFolder: relativePath.split('/').reversed.elementAt(1),
    filename: filename,
    extension: filename.split('.').last,
    mimeType: filename.endsWith('.mp3') ? 'audio/mpeg' : 'audio/flac',
    sizeBytes: 1000,
    metadata: AudioTagSnapshot(
      title: title,
      artist: artist,
      albumArtist: artist,
      album: album,
      trackNumber: trackNumber,
      durationMs: 180000,
      sampleRate: 44100,
      bitDepth: filename.endsWith('.flac') ? 16 : null,
      embeddedArtworkKey: embeddedArtworkPath == null
          ? null
          : 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
      embeddedArtworkPath: embeddedArtworkPath,
      embeddedArtworkMime: embeddedArtworkPath == null ? null : 'image/jpeg',
      readStatus: title == null && artist == null ? 'partial' : 'complete',
      tagFormat: filename.endsWith('.mp3') ? 'ID3v2.3' : 'FLAC/VorbisComment',
    ),
    lyricsCandidates: lyricsName == null
        ? const []
        : [
            LyricsCandidate(
              documentUri: 'content://lyrics/$lyricsName',
              relativePath:
                  '${relativePath.substring(0, relativePath.lastIndexOf('/'))}/$lyricsName',
              filename: lyricsName,
              sizeBytes: 100,
            ),
          ],
    localArtworkKey: localArtworkPath == null
        ? null
        : 'ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss',
    localArtworkPath: localArtworkPath,
    localArtworkMime: localArtworkPath == null ? null : 'image/jpeg',
    localArtworkSource: localArtworkSource,
    libraryArtistFolderName: libraryArtistFolderName,
    libraryArtistRelativeDirectory: libraryArtistFolderName,
    artistArtworkKey: artistArtworkPath == null
        ? null
        : 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    artistArtworkPath: artistArtworkPath,
    artistArtworkMime: artistArtworkPath == null ? null : 'image/jpeg',
  );
}
