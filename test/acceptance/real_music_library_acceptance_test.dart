import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/file_identity_repository.dart';
import 'package:my_music_library/data/library_repository.dart';
import 'package:my_music_library/data/library_search_repository.dart';
import 'package:my_music_library/data/lyrics_repository.dart';
import 'package:my_music_library/data/scan_repository.dart';
import 'package:my_music_library/models/v4/scan_models.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:my_music_library/services/lyrics_service.dart';
import 'package:my_music_library/services/lrc_matcher.dart';
import 'package:my_music_library/services/metadata_inference.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final rootPath = Platform.environment['REAL_MUSIC_ROOT'];
  final realRoot = rootPath == null ? null : Directory(rootPath);
  final enabled = realRoot?.existsSync() ?? false;

  setUpAll(sqfliteFfiInit);

  test('真实周杰伦、邓紫棋、英文歌目录可读并完成目录/LRC/Hash 验收', () async {
    final allAudio = <File>[];
    final samples = <String, File>{};
    for (final artist in artists) {
      final directory = Directory(p.join(realRoot!.path, artist));
      expect(directory.existsSync(), isTrue, reason: '缺少真实目录：$artist');
      final audio = directory
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => audioExtensions.contains(_extension(file)))
          .toList(growable: false);
      final lyrics = directory
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => _extension(file) == 'lrc')
          .toList(growable: false);
      expect(audio, isNotEmpty, reason: '$artist 没有真实音频');
      expect(lyrics, isNotEmpty, reason: '$artist 没有真实 LRC');
      allAudio.addAll(audio);
      final readable = audio.where(_isReadable).toList(growable: false);
      expect(readable, isNotEmpty, reason: '$artist 没有可读取的真实音频');
      samples[artist] = ([
        ...readable,
      ]..sort((a, b) => a.lengthSync().compareTo(b.lengthSync()))).first;
      // ignore: avoid_print
      print(
        '$artist：音频 ${audio.length}，LRC ${lyrics.length}，'
        '不可读 ${audio.length - readable.length}',
      );
    }

    const inference = MetadataInference();
    const matcher = LrcMatcher();
    var inferredAlbums = 0;
    var inferredYears = 0;
    var matchedLyrics = 0;
    for (final file in allAudio) {
      final scanned = _realScannedFile(realRoot!, file);
      final inferred = inference.infer(scanned);
      expect(inferred.title, isNotEmpty);
      if (inferred.album != null) inferredAlbums++;
      if (inferred.year != null) inferredYears++;
      if (matcher.match(
            audio: scanned,
            resolvedTitle: inferred.title ?? scanned.basename,
            resolvedArtist: inferred.artist ?? '未知歌手',
          ) !=
          null) {
        matchedLyrics++;
      }
    }
    expect(inferredAlbums, greaterThan(0));
    expect(inferredYears, greaterThan(0));
    expect(matchedLyrics, greaterThan(0));

    for (final entry in samples.entries) {
      final first = await sha256.bind(entry.value.openRead()).first;
      final second = await sha256.bind(entry.value.openRead()).first;
      expect(first.toString(), hasLength(64));
      expect(second, first);
      // ignore: avoid_print
      print(
        '${entry.key} Hash 样本：${p.basename(entry.value.path)} '
        '${entry.value.lengthSync()} bytes ${first.toString().substring(0, 12)}…',
      );
    }

    final sameSizeGroups = <int, List<File>>{};
    for (final file in allAudio) {
      sameSizeGroups.putIfAbsent(file.lengthSync(), () => []).add(file);
    }
    final possibleDuplicates = sameSizeGroups.values
        .where((files) => files.length > 1)
        .expand((files) => files)
        .length;
    // Exact duplicates must first share size. Hashing is only needed for
    // those groups, avoiding a second full read of a 15 GB real library.
    var exactDuplicates = 0;
    for (final group in sameSizeGroups.values.where(
      (files) => files.length > 1,
    )) {
      final hashes = <String, int>{};
      for (final file in group) {
        final digest = await sha256.bind(file.openRead()).first;
        hashes.update(
          digest.toString(),
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
      exactDuplicates += hashes.values
          .where((count) => count > 1)
          .fold(0, (sum, count) => sum + count - 1);
    }
    // ignore: avoid_print
    print('真实目录潜在同大小文件 $possibleDuplicates，完全重复 $exactDuplicates');
  }, skip: enabled ? false : '需要 REAL_MUSIC_ROOT 指向真实音乐文件目录');

  test('真实音频内容 Hash 可在路径变化后保持 FileId、TrackId 与喜欢状态', () async {
    final jayDirectory = Directory(p.join(realRoot!.path, '周杰伦'));
    final source = jayDirectory
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where(
          (file) =>
              audioExtensions.contains(_extension(file)) && _isReadable(file),
        )
        .reduce(
          (first, second) =>
              first.lengthSync() <= second.lengthSync() ? first : second,
        );
    final digest = await sha256.bind(source.openRead()).first;
    final temp = await Directory.systemTemp.createTemp(
      'real-library-identity-',
    );
    final library = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'library.db'),
    );
    try {
      final scanRepository = ScanRepository(library);
      final identityRepository = FileIdentityRepository(library);
      final root = await scanRepository.savePickedRoot(
        PickedScanRoot(
          treeUri: realRoot.uri.toString(),
          displayName: p.basename(realRoot.path),
          permissionPersisted: true,
        ),
      );
      const firstScan = '00000000-0000-4000-8000-000000000401';
      const secondScan = '00000000-0000-4000-8000-000000000402';
      final actual = _realScannedFile(realRoot, source);
      await scanRepository.startScan(scanId: firstScan, rootId: root.rootId);
      await scanRepository.ingestBatch(
        scanId: firstScan,
        root: root,
        files: [actual],
      );
      var job = (await identityRepository.pendingHashJobs(firstScan)).single;
      await identityRepository.applyHashResults(firstScan, [
        FileHashResult(
          fileId: job.fileId,
          sha256: digest.toString(),
          sizeBytes: source.lengthSync(),
          modifiedAt: job.modifiedAt,
          state: 'ready',
        ),
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

      final moved = actual.copyWithLocation(
        documentUri: '${actual.documentUri}?moved=1',
        relativePath: '周杰伦/验收移动/${actual.filename}',
        parentFolder: '验收移动',
      );
      await scanRepository.startScan(scanId: secondScan, rootId: root.rootId);
      await scanRepository.ingestBatch(
        scanId: secondScan,
        root: root,
        files: [moved],
      );
      job = (await identityRepository.pendingHashJobs(secondScan)).single;
      await identityRepository.applyHashResults(secondScan, [
        FileHashResult(
          fileId: job.fileId,
          sha256: digest.toString(),
          sizeBytes: source.lengthSync(),
          modifiedAt: job.modifiedAt,
          state: 'ready',
        ),
      ]);
      final summary = await identityRepository.finalizeIdentity(
        scanId: secondScan,
        rootId: root.rootId,
      );
      final after = (await db.query('media_files')).single;
      expect(summary.movedFiles, 1);
      expect(after['file_id'], stable['file_id']);
      expect(after['track_id'], stable['track_id']);
      expect((await db.query('track_preferences')).single['liked'], 1);
    } finally {
      await library.close();
      await temp.delete(recursive: true);
    }
  }, skip: enabled ? false : '需要 REAL_MUSIC_ROOT 指向真实音乐文件目录');

  test('真实音乐目录可进入 V4 查询层并按歌手和专辑查询', () async {
    final rootDirectory = realRoot!;
    final realFiles = <File>[];
    final artistFileCounts = <String, int>{};
    for (final artist in artists) {
      final files = Directory(p.join(rootDirectory.path, artist))
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => audioExtensions.contains(_extension(file)))
          .toList(growable: false);
      artistFileCounts[artist] = files.length;
      realFiles.addAll(files);
    }
    final temp = await Directory.systemTemp.createTemp('real-library-query-');
    final database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'library.db'),
    );
    try {
      final scanner = ScanRepository(database);
      final library = LibraryRepository(database);
      final root = await scanner.savePickedRoot(
        PickedScanRoot(
          treeUri: rootDirectory.uri.toString(),
          displayName: p.basename(rootDirectory.path),
          permissionPersisted: true,
        ),
      );
      const scanId = '00000000-0000-4000-8000-000000000403';
      await scanner.startScan(scanId: scanId, rootId: root.rootId);
      for (var offset = 0; offset < realFiles.length; offset += 20) {
        final end = (offset + 20).clamp(0, realFiles.length);
        await scanner.ingestBatch(
          scanId: scanId,
          root: root,
          files: realFiles
              .sublist(offset, end)
              .map((file) => _realScannedFile(rootDirectory, file))
              .toList(growable: false),
        );
      }
      await scanner.finishScan(
        scanId: scanId,
        rootId: root.rootId,
        total: realFiles.length,
      );

      final counts = await library.counts();
      final artistRows = await library.artists();
      final jay = artistRows.singleWhere(
        (item) => item.artist.displayName == '周杰伦',
      );
      final gem = artistRows.singleWhere(
        (item) => item.artist.displayName == '邓紫棋',
      );
      final jayAlbums = await library.albums(artistId: jay.artist.artistId);
      final jayTracks = await library.tracksForArtist(jay.artist.artistId);
      final search = LibrarySearchRepository(database, library);
      final jaySearch = await search.search('周杰伦');
      final albumSearch = await search.search('七里香');
      final englishSearch = await search.search('英文歌');

      expect(counts.trackCount, realFiles.length);
      expect(counts.artistCount, greaterThanOrEqualTo(3));
      expect(jay.trackCount, artistFileCounts['周杰伦']);
      expect(gem.trackCount, artistFileCounts['邓紫棋']);
      expect(jayAlbums, isNotEmpty);
      expect(jayTracks, hasLength(artistFileCounts['周杰伦']!));
      expect(
        jaySearch.artists.any((item) => item.artist.displayName == '周杰伦'),
        isTrue,
      );
      expect(
        albumSearch.albums.any((item) => item.album.title.contains('七里香')),
        isTrue,
      );
      expect(englishSearch.folders.any((item) => item.name == '英文歌'), isTrue);

      final lyricsService = LyricsService(
        repository: LyricsRepository(database),
        contentSource: const _FileLyricsContentSource(),
      );
      final db = await database.database;
      for (final artist in artists) {
        final rows = await db.query(
          'lyrics',
          columns: ['track_id'],
          where: 'is_selected = 1 AND relative_path LIKE ?',
          whereArgs: ['$artist/%'],
        );
        var parsedTimeline = false;
        for (final row in rows) {
          final parsed = await lyricsService.loadForTrack(
            row['track_id']! as String,
          );
          if (parsed != null && parsed.lines.isNotEmpty) {
            parsedTimeline = true;
            break;
          }
        }
        expect(parsedTimeline, isTrue, reason: '$artist 没有可解析的真实 LRC 时间轴');
      }
      // ignore: avoid_print
      print(
        'V4真实查询：${counts.trackCount}首，${counts.artistCount}位歌手，'
        '${counts.albumCount}张专辑；周杰伦${jay.trackCount}首/'
        '${jayAlbums.length}张专辑，邓紫棋${gem.trackCount}首；'
        '周杰伦/邓紫棋/英文歌真实 LRC 时间轴均可读取',
      );
    } finally {
      await database.close();
      await temp.delete(recursive: true);
    }
  }, skip: enabled ? false : '需要 REAL_MUSIC_ROOT 指向真实音乐文件目录');
}

class _FileLyricsContentSource implements LyricsContentSource {
  const _FileLyricsContentSource();

  @override
  Future<String> read(String uri) async => utf8.decode(
    await File.fromUri(Uri.parse(uri)).readAsBytes(),
    allowMalformed: true,
  );
}

const artists = ['周杰伦', '邓紫棋', '英文歌'];
const audioExtensions = {'flac', 'mp3', 'wav', 'm4a', 'aac', 'ogg', 'opus'};

ScannedAudioFile _realScannedFile(Directory root, File file) {
  final relativePath = p
      .relative(file.path, from: root.path)
      .replaceAll('\\', '/');
  final parent = file.parent;
  final lyrics = parent
      .listSync(followLinks: false)
      .whereType<File>()
      .where((candidate) => _extension(candidate) == 'lrc')
      .map(
        (candidate) => LyricsCandidate(
          documentUri: candidate.uri.toString(),
          relativePath: p
              .relative(candidate.path, from: root.path)
              .replaceAll('\\', '/'),
          filename: p.basename(candidate.path),
          sizeBytes: candidate.lengthSync(),
          modifiedAt: candidate.lastModifiedSync(),
        ),
      )
      .toList(growable: false);
  return ScannedAudioFile(
    documentUri: file.uri.toString(),
    relativePath: relativePath,
    parentFolder: p.basename(parent.path),
    filename: p.basename(file.path),
    extension: _extension(file),
    mimeType: 'audio/${_extension(file)}',
    sizeBytes: file.lengthSync(),
    modifiedAt: file.lastModifiedSync(),
    metadata: const AudioTagSnapshot(durationMs: 0, readStatus: 'partial'),
    lyricsCandidates: lyrics,
  );
}

String _extension(File file) =>
    p.extension(file.path).replaceFirst('.', '').toLowerCase();

bool _isReadable(File file) {
  RandomAccessFile? handle;
  try {
    handle = file.openSync();
    handle.readByteSync();
    return true;
  } on FileSystemException {
    return false;
  } finally {
    handle?.closeSync();
  }
}

extension on ScannedAudioFile {
  ScannedAudioFile copyWithLocation({
    required String documentUri,
    required String relativePath,
    required String parentFolder,
  }) => ScannedAudioFile(
    documentUri: documentUri,
    relativePath: relativePath,
    parentFolder: parentFolder,
    filename: filename,
    extension: extension,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    modifiedAt: modifiedAt,
    metadata: metadata,
    lyricsCandidates: lyricsCandidates,
  );
}
