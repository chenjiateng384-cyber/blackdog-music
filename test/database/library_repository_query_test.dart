import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/library_repository.dart';
import 'package:my_music_library/data/scan_repository.dart';
import 'package:my_music_library/models/v4/library_browsing.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/scan_models.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDirectory;
  late LibraryDatabase database;
  late LibraryRepository library;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('library-query-');
    database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${tempDirectory.path}/library.db',
    );
    library = LibraryRepository(database);
    await _seedLibrary(database);
  });
  tearDown(() async {
    await database.close();
    await tempDirectory.delete(recursive: true);
  });

  test('音乐库统计只计算有可播放文件的 Track、歌手、专辑和喜欢', () async {
    final counts = await library.counts();

    expect(counts.trackCount, 4);
    expect(counts.artistCount, 2);
    expect(counts.albumCount, 3);
    expect(counts.likedCount, 1);
  });

  test('可以查询歌手及其专辑数量和歌曲数量', () async {
    final artists = await library.artists(includeMinor: true);
    final jay = artists.singleWhere((item) => item.artist.displayName == '周杰伦');

    expect(jay.trackCount, 3);
    expect(jay.albumCount, 0);
    expect(
      artists
          .singleWhere((item) => item.artist.displayName == '邓紫棋')
          .trackCount,
      1,
    );
  });

  test('主要歌手合并合作署名，并隐藏无专辑无播放的单曲歌手', () async {
    final scanner = ScanRepository(database);
    final root = (await scanner.scanRoots()).single;
    const scanId = '00000000-0000-4000-8000-000000000399';
    final files = [
      _audio(
        '周杰伦/2004_七里香/03_借口.flac',
        artist: '周杰伦',
        album: '七里香',
        trackNumber: 3,
        addedDay: 3,
      ),
      _audio(
        '周杰伦/2004_七里香/01_我的地盘.flac',
        artist: '周杰伦',
        album: '七里香',
        trackNumber: 1,
        addedDay: 1,
      ),
      _audio(
        '周杰伦/2001_范特西/01_爱在西元前.flac',
        artist: '周杰伦',
        album: '范特西',
        trackNumber: 1,
        addedDay: 2,
      ),
      _audio(
        '周杰伦/EP与单曲/合作曲.mp3',
        artist: '周杰伦 & 杨瑞代',
        album: '合作曲',
        trackNumber: null,
        addedDay: 5,
      ),
      _audio(
        '英文歌/Only Song.mp3',
        artist: '一次性歌手',
        album: 'Only Song',
        trackNumber: null,
        addedDay: 6,
      ),
      for (var index = 0; index < 7; index++)
        _audio(
          '周杰伦/收藏/补充${index + 1}.mp3',
          artist: '周杰伦',
          album: '收藏',
          trackNumber: index + 1,
          addedDay: 10 + index,
        ),
      for (var index = 0; index < 10; index++)
        _audio(
          '十首歌手/单曲${index + 1}.mp3',
          artist: '十首歌手',
          album: '单曲收藏',
          trackNumber: index + 1,
          addedDay: 20 + index,
        ),
    ];
    await scanner.startScan(scanId: scanId, rootId: root.rootId);
    await scanner.ingestBatch(scanId: scanId, root: root, files: files);
    await scanner.finishScan(
      scanId: scanId,
      rootId: root.rootId,
      total: files.length,
    );

    final artists = await library.artists();
    final jay = artists.singleWhere((item) => item.artist.displayName == '周杰伦');

    expect(jay.trackCount, 11);
    // New scans bind collaboration credits directly to the canonical primary
    // artist while Track.artistDisplay keeps the full original credit.
    expect(jay.sourceArtistIds, hasLength(1));
    expect(artists.any((item) => item.artist.displayName == '一次性歌手'), isFalse);
    expect(artists.any((item) => item.artist.displayName == '十首歌手'), isFalse);
    expect(
      (await library.artists(includeMinor: true))
          .singleWhere((item) => item.artist.displayName == '一次性歌手')
          .trackCount,
      1,
    );
    expect(
      (await library.albums())
          .where((item) => item.album.title == 'Only Song')
          .single
          .isBrowsableCollection,
      isFalse,
    );
  });

  test('未知歌手保留在歌曲信息中，但不进入主要歌手列表', () async {
    final scanner = ScanRepository(database);
    final root = (await scanner.scanRoots()).single;
    const scanId = '00000000-0000-4000-8000-000000000398';
    final files = [
      _audio(
        '零散单曲/未知一.mp3',
        artist: '未知歌手',
        album: '未知一',
        trackNumber: null,
        addedDay: 7,
      ),
      _audio(
        '零散单曲/未知二.mp3',
        artist: '未知歌手',
        album: '未知二',
        trackNumber: null,
        addedDay: 8,
      ),
    ];
    await scanner.startScan(scanId: scanId, rootId: root.rootId);
    await scanner.ingestBatch(scanId: scanId, root: root, files: files);
    await scanner.finishScan(scanId: scanId, rootId: root.rootId, total: 2);

    final artists = await library.artists();
    final tracks = await library.allTracks();

    expect(artists.any((item) => item.artist.displayName == '未知歌手'), isFalse);
    expect(
      tracks.where((item) => item.track.artistDisplay == '未知歌手'),
      hasLength(2),
    );
  });

  test('文件夹浏览保留根目录零散歌曲', () async {
    final scanner = ScanRepository(database);
    final root = (await scanner.scanRoots()).single;
    const scanId = '00000000-0000-4000-8000-000000000397';
    await scanner.startScan(scanId: scanId, rootId: root.rootId);
    await scanner.ingestBatch(
      scanId: scanId,
      root: root,
      files: [
        _audio(
          '雨爱-杨丞琳.mp3',
          artist: '杨丞琳',
          album: '雨爱',
          trackNumber: null,
          addedDay: 9,
        ),
      ],
    );
    await scanner.finishScan(scanId: scanId, rootId: root.rootId, total: 1);

    final rootFolder = (await library.folders()).singleWhere(
      (item) => item.relativePath.isEmpty,
    );
    final rootTracks = await library.tracksForFolder(
      rootFolder.scanRootId,
      rootFolder.relativePath,
      recursive: false,
    );

    expect(rootFolder.name, '根目录歌曲');
    expect(rootFolder.directTrackCount, 1);
    expect(rootTracks.map((item) => item.track.title), ['雨爱-杨丞琳']);
  });

  test('周杰伦专辑可查询，七里香歌曲按 Disc 和 Track 排列', () async {
    final jay = (await library.artists(includeMinor: true))
        .singleWhere((item) => item.artist.displayName == '周杰伦');
    final albums = await library.albums(artistId: jay.artist.artistId);
    final qlx = albums.singleWhere((item) => item.album.title == '七里香');
    final tracks = await library.tracksForAlbum(qlx.album.albumId);

    expect(albums.map((item) => item.album.title), containsAll(['范特西', '七里香']));
    expect(qlx.trackCount, 2);
    expect(tracks.map((item) => item.track.title), ['我的地盘', '借口']);
    expect(tracks.map((item) => item.track.trackNumber), [1, 3]);
  });

  test('喜欢、最近添加和最近播放查询返回正确 Track 与首选文件', () async {
    final liked = await library.likedTracks();
    final recentlyAdded = await library.recentlyAddedTracks(limit: 2);
    final recentlyPlayed = await library.recentlyPlayedTracks();

    expect(liked.map((item) => item.track.title), ['借口']);
    expect(liked.single.preferredFile?.filename, '03_借口.flac');
    expect(recentlyAdded.map((item) => item.track.title), ['光年之外', '借口']);
    expect(recentlyPlayed.map((item) => item.track.title), ['爱在西元前']);
  });

  test('所有 Track 支持分页和排序，缺省不返回没有文件的逻辑记录', () async {
    final firstPage = await library.allTracks(
      sort: LibraryTrackSort.artist,
      limit: 2,
    );
    final secondPage = await library.allTracks(
      sort: LibraryTrackSort.artist,
      limit: 2,
      offset: 2,
    );

    expect(firstPage, hasLength(2));
    expect(secondPage, hasLength(2));
    expect(
      {...firstPage, ...secondPage}.map((item) => item.track.trackId).toSet(),
      hasLength(4),
    );
  });

  test('查询和播放接入始终解析 Track 手动指定的 Preferred MediaFile', () async {
    final original = (await library.allTracks()).singleWhere(
      (item) => item.track.title == '借口',
    );
    final now = DateTime(2026, 8, 20);
    const mp3FileId = '99999999-8888-4777-8666-555555555555';
    await library.saveMediaFile(
      MediaFile(
        fileId: mp3FileId,
        trackId: original.track.trackId,
        contentUri: 'content://music/jiekou-mp3',
        filename: '03_借口.mp3',
        normalizedFilename: '03_借口.mp3',
        extension: 'mp3',
        mimeType: 'audio/mpeg',
        sizeBytes: 8000000,
        durationMs: 240000,
        bitrate: 320000,
        hashState: 'ready',
        status: 'active',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await library.setPreferredMediaFile(original.track.trackId, mp3FileId);

    final selected = await library.libraryTrackById(original.track.trackId);

    expect(selected?.preferredFile?.fileId, mp3FileId);
    expect(selected?.playbackUri, 'content://music/jiekou-mp3');
    expect(selected?.track.preferredFileSource, 'manual');
  });
}

Future<void> _seedLibrary(LibraryDatabase database) async {
  final scanner = ScanRepository(database);
  final root = await scanner.savePickedRoot(
    const PickedScanRoot(
      treeUri: 'content://tree/real-library',
      displayName: '音乐文件',
      permissionPersisted: true,
    ),
  );
  const scanId = '00000000-0000-4000-8000-000000000301';
  await scanner.startScan(scanId: scanId, rootId: root.rootId);
  await scanner.ingestBatch(
    scanId: scanId,
    root: root,
    files: [
      _audio(
        '周杰伦/2004_七里香/03_借口.flac',
        artist: '周杰伦',
        album: '七里香',
        trackNumber: 3,
        addedDay: 3,
      ),
      _audio(
        '周杰伦/2004_七里香/01_我的地盘.flac',
        artist: '周杰伦',
        album: '七里香',
        trackNumber: 1,
        addedDay: 1,
      ),
      _audio(
        '周杰伦/2001_范特西/01_爱在西元前.flac',
        artist: '周杰伦',
        album: '范特西',
        trackNumber: 1,
        addedDay: 2,
      ),
      _audio(
        '邓紫棋/2016_新的心跳/01_光年之外.mp3',
        artist: '邓紫棋',
        album: '新的心跳',
        trackNumber: 1,
        addedDay: 4,
      ),
    ],
  );
  await scanner.finishScan(scanId: scanId, rootId: root.rootId, total: 4);

  final db = await database.database;
  final tracks = await db.query('tracks');
  String idFor(String title) =>
      tracks.singleWhere((row) => row['title'] == title)['track_id']! as String;
  final now = DateTime(2026, 8, 20).millisecondsSinceEpoch;
  await db.insert('track_preferences', {
    'track_id': idFor('借口'),
    'liked': 1,
    'liked_at': now,
    'recommendation_excluded': 0,
    'updated_at': now,
  });
  await db.insert('track_stats', {
    'track_id': idFor('爱在西元前'),
    'play_count': 5,
    'completed_count': 4,
    'skip_count': 1,
    'manually_selected_count': 2,
    'total_play_duration_ms': 600000,
    'last_played_at': now,
    'updated_at': now,
  });
}

ScannedAudioFile _audio(
  String relativePath, {
  required String artist,
  required String album,
  required int? trackNumber,
  required int addedDay,
}) {
  final filename = relativePath.split('/').last;
  final title = filename
      .replaceFirst(RegExp(r'^\d+[._ -]*'), '')
      .replaceFirst(RegExp(r'\.(flac|mp3)$'), '');
  return ScannedAudioFile(
    documentUri: 'content://document/$relativePath',
    relativePath: relativePath,
    parentFolder: relativePath.contains('/')
        ? relativePath.split('/').reversed.elementAt(1)
        : '',
    filename: filename,
    extension: filename.split('.').last,
    mimeType: filename.endsWith('.mp3') ? 'audio/mpeg' : 'audio/flac',
    sizeBytes: filename.endsWith('.mp3') ? 8000000 : 30000000,
    dateAdded: DateTime(2026, 8, addedDay),
    lyricsCandidates: const [],
    metadata: AudioTagSnapshot(
      title: title,
      artist: artist,
      albumArtist: artist,
      album: album,
      trackNumber: trackNumber,
      durationMs: 240000,
      bitrate: filename.endsWith('.mp3') ? 320000 : 900000,
      sampleRate: 44100,
      bitDepth: filename.endsWith('.mp3') ? null : 16,
      readStatus: 'complete',
      tagFormat: filename.endsWith('.mp3') ? 'ID3v2.3' : 'FLAC/VorbisComment',
    ),
  );
}
