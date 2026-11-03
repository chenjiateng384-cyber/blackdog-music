import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/library_repository.dart';
import 'package:my_music_library/data/playlist_repository.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temp;
  late LibraryDatabase database;
  late LibraryRepository library;
  late PlaylistRepository playlists;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('playlist-migration-');
    database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    library = LibraryRepository(database);
    playlists = PlaylistRepository(
      database,
      supportDirectory: () async => temp,
    );
    await _seedTracks(library);
  });
  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  test('自选封面保存独立副本，重启可读，删除歌单不删除原图', () async {
    final source = File('${temp.path}/source.jpg');
    await source.writeAsBytes([1, 2, 3, 4]);
    final playlist = await playlists.create('我的收藏', coverPath: source.path);
    final cover = (await playlists.covers())[playlist.playlistId]!;
    expect(cover.cachePath, isNot(source.path));
    expect(await File(cover.cachePath!).readAsBytes(), [1, 2, 3, 4]);
    final reopened = PlaylistRepository(
      database,
      supportDirectory: () async => temp,
    );
    expect(
      (await reopened.covers())[playlist.playlistId]!.cachePath,
      cover.cachePath,
    );
    await reopened.delete(playlist.playlistId);
    expect(await reopened.covers(), isEmpty);
    expect(await File(cover.cachePath!).exists(), isFalse);
    expect(await source.exists(), isTrue);
  });

  test('默认封面不生成资源，封面复制失败不留下半个歌单', () async {
    await playlists.create('默认');
    expect(await playlists.covers(), isEmpty);
    await expectLater(
      playlists.create('失败', coverPath: '${temp.path}/absent.jpg'),
      throwsA(isA<FileSystemException>()),
    );
    expect((await playlists.playlists()).map((p) => p.playlist.name), ['默认']);
  });

  test('旧 Category 与成员安全迁移为 Playlist，重复同步保持幂等', () async {
    final db = await database.database;
    await database.createCategory('健身');
    final categoryId = (await database.categories()).single.id;
    await database.setSongInCategory(categoryId, 101, true);
    await database.setSongInCategory(categoryId, 102, true);
    await _mapLegacy(db, 101, _trackA);
    await _mapLegacy(db, 102, _trackB);

    await playlists.synchronizeLegacyCategories();
    await playlists.synchronizeLegacyCategories();

    final summaries = await playlists.playlists();
    final migrated = summaries.singleWhere(
      (item) => item.playlist.legacyCategoryId == categoryId,
    );
    final members = await library.tracksForPlaylist(
      migrated.playlist.playlistId,
    );
    expect(migrated.playlist.name, '健身');
    expect(migrated.trackCount, 2);
    expect(members.map((item) => item.track.trackId), [_trackA, _trackB]);
    expect(await database.categorySongIds(categoryId), {101, 102});
    expect(await db.query('category_songs'), hasLength(2));
  });

  test('无法匹配稳定 Track 的旧成员留在旧表，绝不强行猜测或丢弃', () async {
    await database.createCategory('待整理');
    final categoryId = (await database.categories()).single.id;
    await database.setSongInCategory(categoryId, 999, true);

    await playlists.synchronizeLegacyCategories();

    final migrated = await playlists.playlistForLegacyCategory(categoryId);
    expect(migrated, isNotNull);
    expect(await library.tracksForPlaylist(migrated!.playlistId), isEmpty);
    expect(await database.categorySongIds(categoryId), {999});
  });

  test('迁移后用户调整的播放顺序不会被再次同步覆盖', () async {
    final db = await database.database;
    await database.createCategory('学习');
    final categoryId = (await database.categories()).single.id;
    await database.setSongInCategory(categoryId, 101, true);
    await database.setSongInCategory(categoryId, 102, true);
    await _mapLegacy(db, 101, _trackA);
    await _mapLegacy(db, 102, _trackB);
    await playlists.synchronizeLegacyCategories();
    final playlist = (await playlists.playlistForLegacyCategory(categoryId))!;

    await playlists.reorder(playlist.playlistId, [_trackB, _trackA]);
    await playlists.synchronizeLegacyCategories();

    final members = await library.tracksForPlaylist(playlist.playlistId);
    expect(members.map((item) => item.track.trackId), [_trackB, _trackA]);
  });

  test('删除由旧 Category 迁移的歌单后不会在下次同步重新出现', () async {
    await database.createCategory('旧分类');
    final categoryId = (await database.categories()).single.id;
    await playlists.synchronizeLegacyCategories();
    final migrated = await playlists.playlistForLegacyCategory(categoryId);
    expect(migrated, isNotNull);

    await playlists.delete(migrated!.playlistId);
    await playlists.synchronizeLegacyCategories();

    expect(await playlists.playlistForLegacyCategory(categoryId), isNull);
    expect(await database.categories(), isEmpty);
  });

  test('新建 V4 Playlist 支持添加、去重、排序和删除成员', () async {
    final playlist = await playlists.create('骑行');
    await playlists.setTrack(playlist.playlistId, _trackA, true);
    await playlists.setTrack(playlist.playlistId, _trackA, true);
    await playlists.setTrack(playlist.playlistId, _trackB, true);
    expect(await playlists.playlistIdsForTrack(_trackA), {playlist.playlistId});
    await playlists.reorder(playlist.playlistId, [_trackB, _trackA]);

    expect(
      (await library.tracksForPlaylist(playlist.playlistId))
          .map((item) => item.track.trackId),
      [_trackB, _trackA],
    );
    await playlists.setTrack(playlist.playlistId, _trackB, false);
    expect(await playlists.playlistIdsForTrack(_trackB), isEmpty);
    expect(
      (await library.tracksForPlaylist(playlist.playlistId))
          .map((item) => item.track.trackId),
      [_trackA],
    );

    await playlists.delete(playlist.playlistId);
    expect(await playlists.playlistById(playlist.playlistId), isNull);
    expect(await library.tracksForPlaylist(playlist.playlistId), isEmpty);
  });

  test('Playlist 支持改名、批量增删，并在删除后压紧顺序', () async {
    final playlist = await playlists.create('旧名字');
    await playlists.rename(playlist.playlistId, '夜间骑行');
    await playlists.addTracks(playlist.playlistId, [_trackA, _trackB, _trackA]);

    expect((await playlists.playlistById(playlist.playlistId))!.name, '夜间骑行');
    expect(
      (await library.tracksForPlaylist(playlist.playlistId))
          .map((item) => item.track.trackId),
      [_trackA, _trackB],
    );

    await playlists.removeTracks(playlist.playlistId, [_trackA]);
    final db = await database.database;
    final rows = await db.query(
      'playlist_tracks',
      where: 'playlist_id = ?',
      whereArgs: [playlist.playlistId],
      orderBy: 'position',
    );
    expect(rows.single['track_id'], _trackB);
    expect(rows.single['position'], 0);
  });

  test('Playlist 排序必须提供完整且不重复的成员，失败不改变原顺序', () async {
    final playlist = await playlists.create('稳定顺序');
    await playlists.addTracks(playlist.playlistId, [_trackA, _trackB]);

    await expectLater(
      playlists.reorder(playlist.playlistId, [_trackA]),
      throwsStateError,
    );
    await expectLater(
      playlists.reorder(playlist.playlistId, [_trackA, _trackA]),
      throwsArgumentError,
    );
    expect(
      (await library.tracksForPlaylist(playlist.playlistId))
          .map((item) => item.track.trackId),
      [_trackA, _trackB],
    );
  });

  test('仅手动播放使用稳定系统歌单，重启后仍保持且不能删除或改名', () async {
    await playlists.ensureManualOnlyPlaylist();
    await playlists.setManualOnly(_trackA, true);

    final summary = (await playlists.playlists()).singleWhere(
      (item) =>
          item.playlist.playlistId == PlaylistRepository.manualOnlyPlaylistId,
    );
    expect(summary.playlist.name, PlaylistRepository.manualOnlyPlaylistName);
    expect(summary.playlist.type, 'system');
    expect(summary.trackCount, 1);
    expect(
      (await library.allTracks())
          .singleWhere((item) => item.track.trackId == _trackA)
          .preference
          .recommendationExcluded,
      isTrue,
    );

    final reopened = PlaylistRepository(database);
    await reopened.ensureManualOnlyPlaylist();
    expect(
      await reopened.playlistIdsForTrack(_trackA),
      contains(PlaylistRepository.manualOnlyPlaylistId),
    );
    await expectLater(
      reopened.delete(PlaylistRepository.manualOnlyPlaylistId),
      throwsStateError,
    );
    await expectLater(
      reopened.rename(PlaylistRepository.manualOnlyPlaylistId, '其它名字'),
      throwsStateError,
    );
  });

  test('仅手动播放与我喜欢和普通歌单共存，移除后恢复推荐资格', () async {
    final userPlaylist = await playlists.create('夜晚');
    await playlists.addTracks(userPlaylist.playlistId, [_trackA]);
    await library.setLiked(_trackA, true);
    await playlists.setManualOnly(_trackA, true);

    var track = (await library.allTracks()).singleWhere(
      (item) => item.track.trackId == _trackA,
    );
    expect(track.preference.liked, isTrue);
    expect(track.preference.recommendationExcluded, isTrue);
    expect(await playlists.playlistIdsForTrack(_trackA), {
      userPlaylist.playlistId,
      PlaylistRepository.manualOnlyPlaylistId,
    });

    await playlists.setManualOnly(_trackA, false);
    track = (await library.allTracks()).singleWhere(
      (item) => item.track.trackId == _trackA,
    );
    expect(track.preference.liked, isTrue);
    expect(track.preference.recommendationExcluded, isFalse);
    expect(await playlists.playlistIdsForTrack(_trackA), {
      userPlaylist.playlistId,
    });
    expect(
      (await library.tracksForPlaylist(userPlaylist.playlistId))
          .map((item) => item.track.trackId),
      [_trackA],
    );
  });
}

const _trackA = '11111111-2222-4333-8444-555555555555';
const _trackB = '66666666-7777-4888-8999-aaaaaaaaaaaa';

Future<void> _seedTracks(LibraryRepository library) async {
  await _seedTrack(library, _trackA, '晴天');
  await _seedTrack(library, _trackB, '七里香');
}

Future<void> _seedTrack(
  LibraryRepository library,
  String trackId,
  String title,
) async {
  final now = DateTime(2026, 8, 20);
  final fileId = trackId == _trackA
      ? 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
      : 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff';
  await library.createTrack(
    Track(
      trackId: trackId,
      title: title,
      artistDisplay: '周杰伦',
      albumArtistDisplay: '周杰伦',
      albumDisplay: '专辑',
      durationMs: 200000,
      metadataState: 'complete',
      addedAt: now,
      updatedAt: now,
    ),
  );
  await library.saveMediaFile(
    MediaFile(
      fileId: fileId,
      trackId: trackId,
      contentUri: 'content://music/$trackId',
      filename: '$title.flac',
      normalizedFilename: '$title.flac',
      extension: 'flac',
      mimeType: 'audio/flac',
      sizeBytes: 1000,
      durationMs: 200000,
      hashState: 'ready',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await library.setPreferredMediaFile(trackId, fileId);
}

Future<void> _mapLegacy(Database db, int legacySongId, String trackId) async {
  await db.insert('legacy_song_map', {
    'legacy_song_id': legacySongId,
    'track_id': trackId,
    'match_status': 'matched',
    'matched_at': DateTime(2026, 8, 20).millisecondsSinceEpoch,
  });
}
