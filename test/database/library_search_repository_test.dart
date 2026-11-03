import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/library_repository.dart';
import 'package:my_music_library/data/library_search_repository.dart';
import 'package:my_music_library/data/scan_repository.dart';
import 'package:my_music_library/models/v4/library_search.dart';
import 'package:my_music_library/models/v4/scan_models.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temp;
  late LibraryDatabase database;
  late LibraryRepository library;
  late LibrarySearchRepository search;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('library-search-');
    database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    library = LibraryRepository(database);
    search = LibrarySearchRepository(database, library);
    await _seed(database);
  });
  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  test('精确歌曲排在同名专辑前，专辑排在歌曲模糊匹配前', () async {
    final exact = await search.search('七里香');

    expect(exact.tracks.first.track.title, '七里香');
    expect(
      exact.tracks.map((item) => item.track.title),
      containsAll(['七里香', '借口']),
    );
    expect(exact.albums.single.album.title, '七里香');
    expect(exact.ordered.first.type, LibrarySearchResultType.track);
    expect(exact.ordered.first.score, 0);
    expect(
      exact.ordered
          .firstWhere((item) => item.type == LibrarySearchResultType.album)
          .score,
      200,
    );

    final fuzzy = await search.search('里香');
    expect(fuzzy.ordered.first.type, LibrarySearchResultType.album);
    expect(fuzzy.ordered.last.type, LibrarySearchResultType.track);
  });

  test('歌手精确匹配排在真实歌手目录前', () async {
    final results = await search.search('周杰伦');

    expect(results.artists.single.artist.displayName, '周杰伦');
    expect(results.artists.single.trackCount, 11);
    expect(results.artists.single.sourceArtistIds, hasLength(1));
    final mergedTracks = await library.tracksForArtists(
      results.artists.single.allArtistIds,
    );
    expect(
      mergedTracks.map((item) => item.track.title),
      containsAll(['七里香', '借口', '等你下课']),
    );
    expect(
      mergedTracks
          .singleWhere((item) => item.track.title == '等你下课')
          .track
          .artistDisplay,
      '周杰伦 & 杨瑞代',
    );
    expect(results.folders.first.name, '周杰伦');
    expect(results.ordered.first.type, LibrarySearchResultType.artist);
    expect(results.ordered.first.score, 100);
  });

  test('中文、英文大小写和文件夹路径都能搜索', () async {
    final english = await search.search('ADELE');
    final album = await search.search('25');
    final folder = await search.search('英文歌');

    expect(english.artists, isEmpty);
    expect(english.tracks.single.track.title, 'Hello');
    expect(album.albums, isEmpty);
    expect(album.tracks.single.track.title, 'Hello');
    expect(folder.folders.any((item) => item.name == '英文歌'), isTrue);
  });

  test('零散单曲的 Album 标签仍可搜到歌曲，但不生成无意义专辑结果', () async {
    final results = await search.search('光年之外');

    expect(results.tracks.single.track.title, '光年之外');
    expect(results.albums, isEmpty);
  });

  test('LIKE 通配符会转义，不会把百分号当成任意字符', () async {
    final results = await search.search('%');

    expect(results.ordered, isEmpty);
  });

  test('文件夹查询保留真实层级，并能区分直接和递归歌曲', () async {
    final roots = await library.folders();
    final jay = roots.singleWhere((folder) => folder.name == '周杰伦');
    final jayChildren = await library.folders(
      scanRootId: jay.scanRootId,
      parentPath: jay.relativePath,
    );
    final album = jayChildren.singleWhere(
      (folder) => folder.name == '2004_七里香',
    );
    final recursiveTracks = await library.tracksForFolder(
      jay.scanRootId,
      jay.relativePath,
    );
    final directTracks = await library.tracksForFolder(
      jay.scanRootId,
      jay.relativePath,
      recursive: false,
    );

    expect(jay.descendantTrackCount, 11);
    expect(jay.directTrackCount, 0);
    expect(album.directTrackCount, 3);
    expect(recursiveTracks, hasLength(11));
    expect(directTracks, isEmpty);
  });

  test('播放次数查询优先返回播放更多的 Track', () async {
    final db = await database.database;
    final tracks = await db.query('tracks');
    String id(String title) =>
        tracks.singleWhere((row) => row['title'] == title)['track_id']!
            as String;
    final now = DateTime(2026, 8, 20).millisecondsSinceEpoch;
    for (final entry in {'七里香': 3, '光年之外': 9}.entries) {
      await db.insert('track_stats', {
        'track_id': id(entry.key),
        'play_count': entry.value,
        'completed_count': 0,
        'skip_count': 0,
        'manually_selected_count': 0,
        'total_play_duration_ms': entry.value * 1000,
        'updated_at': now,
      });
    }

    final results = await library.mostPlayedTracks();
    expect(results.map((item) => item.track.title), ['光年之外', '七里香']);
  });
}

Future<void> _seed(LibraryDatabase database) async {
  final scanner = ScanRepository(database);
  final root = await scanner.savePickedRoot(
    const PickedScanRoot(
      treeUri: 'content://tree/music-library',
      displayName: '音乐文件',
      permissionPersisted: true,
    ),
  );
  const scanId = '00000000-0000-4000-8000-000000000701';
  await scanner.startScan(scanId: scanId, rootId: root.rootId);
  await scanner.ingestBatch(
    scanId: scanId,
    root: root,
    files: [
      _audio('周杰伦/2004_七里香/01_七里香.flac', '七里香', '周杰伦', '七里香'),
      _audio('周杰伦/2004_七里香/02_借口.flac', '借口', '周杰伦', '七里香'),
      _audio('周杰伦/2004_七里香/03_搁浅.flac', '搁浅', '周杰伦', '七里香'),
      _audio('周杰伦/EP与单曲/01_等你下课.flac', '等你下课', '周杰伦 & 杨瑞代', '等你下课'),
      for (var index = 0; index < 7; index++)
        _audio(
          '周杰伦/收藏/${index + 1}_补充歌曲.flac',
          '补充歌曲${index + 1}',
          '周杰伦',
          '收藏',
        ),
      _audio('邓紫棋/2016_新的心跳/01_光年之外.mp3', '光年之外', '邓紫棋', '新的心跳'),
      _audio(
        '英文歌/Adele/25/01_Hello.flac',
        'Hello',
        'Adele',
        '25',
        trackNumber: 1,
      ),
    ],
  );
  await scanner.finishScan(scanId: scanId, rootId: root.rootId, total: 13);
}

ScannedAudioFile _audio(
  String relativePath,
  String title,
  String artist,
  String album, {
  int? trackNumber,
}) => ScannedAudioFile(
  documentUri: 'content://document/$relativePath',
  relativePath: relativePath,
  parentFolder: relativePath.split('/').reversed.elementAt(1),
  filename: relativePath.split('/').last,
  extension: relativePath.endsWith('.mp3') ? 'mp3' : 'flac',
  mimeType: relativePath.endsWith('.mp3') ? 'audio/mpeg' : 'audio/flac',
  sizeBytes: 1000,
  metadata: AudioTagSnapshot(
    title: title,
    artist: artist,
    albumArtist: artist,
    album: album,
    trackNumber: trackNumber,
    durationMs: 200000,
    readStatus: 'complete',
  ),
  lyricsCandidates: const [],
);
