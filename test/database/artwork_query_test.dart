import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/library_repository.dart';
import 'package:my_music_library/models/v4/library_entities.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/metadata_layers.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temp;
  late LibraryDatabase database;
  late LibraryRepository library;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('artwork-query-');
    database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    library = LibraryRepository(database);
    await _seed(library, database, temp);
  });
  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  test('人工封面优先于首选文件和其他文件的内嵌封面', () async {
    final track = await library.libraryTrackById(_trackId);
    final albums = await library.albums();

    expect(track!.artwork?.artworkId, _manualArtworkId);
    expect(track.artwork?.source, 'manual');
    expect(albums.single.artwork?.artworkId, _manualArtworkId);
  });

  test('没有人工封面时优先使用首选播放文件的内嵌封面', () async {
    final db = await database.database;
    await db.delete(
      'track_overrides',
      where: 'track_id = ?',
      whereArgs: [_trackId],
    );
    await db.delete(
      'artwork_assets',
      where: 'artwork_id = ?',
      whereArgs: [_manualArtworkId],
    );

    final track = await library.libraryTrackById(_trackId);

    expect(track!.artwork?.artworkId, _preferredArtworkId);
    expect(track.artwork?.fileId, _preferredFileId);
  });

  test('同专辑歌曲没有独立封面时复用专辑内已有封面', () async {
    await _createTrack(
      library,
      trackId: _sharedAlbumTrackId,
      fileId: _sharedAlbumFileId,
      albumId: _albumId,
      title: '七里香',
    );

    final track = await library.libraryTrackById(_sharedAlbumTrackId);

    expect(track!.artwork?.artworkId, _manualArtworkId);
    expect(track.artwork?.trackId, _trackId);
  });

  test('歌手聚合不再借用歌曲或专辑封面', () async {
    final artists = await library.artists(includeMinor: true);
    final selected = await library.artistsByIds([_artistId]);

    expect(artists.single.artwork, isNull);
    expect(selected.single.artwork, isNull);
  });

  test('歌手聚合只读取歌手目录中的专用封面', () async {
    final db = await database.database;
    await db.insert('artist_profiles', {
      'artist_id': _artistId,
      'relative_directory': '周杰伦',
      'artwork_cache_path': '${temp.path}/artist.jpg',
      'artwork_mime_type': 'image/jpeg',
      'artwork_sha256':
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'updated_at': DateTime(2026, 8, 20).millisecondsSinceEpoch,
    });

    final artists = await library.artists();
    final selected = await library.artistsByIds([_artistId]);

    expect(artists.single.isCuratedFolder, isTrue);
    expect(artists.single.artwork?.cachePath, '${temp.path}/artist.jpg');
    expect(selected.single.artwork?.cachePath, '${temp.path}/artist.jpg');
  });

  test('未确认的联网封面不会进入 V4 展示结果', () async {
    final db = await database.database;
    await _createTrack(
      library,
      trackId: _onlineOnlyTrackId,
      fileId: _onlineOnlyFileId,
      albumId: null,
      title: '联网候选',
    );
    await db.insert('artwork_assets', {
      'artwork_id': _onlineArtworkId,
      'track_id': _onlineOnlyTrackId,
      'file_id': _onlineOnlyFileId,
      'source': 'online',
      'cache_path': '${temp.path}/online.jpg',
      'confidence': 1.0,
      'created_at': DateTime(2026, 8, 20).millisecondsSinceEpoch,
    });

    final track = await library.libraryTrackById(_onlineOnlyTrackId);

    expect(track!.artwork, isNull);
  });

  test('已确认但低置信度的联网封面仍不会覆盖默认封面', () async {
    final db = await database.database;
    await _createTrack(
      library,
      trackId: _onlineOnlyTrackId,
      fileId: _onlineOnlyFileId,
      albumId: null,
      title: '低置信度候选',
    );
    await library.saveOnlineMetadata(
      OnlineMetadata(
        onlineMetadataId: _onlineMetadataId,
        trackId: _onlineOnlyTrackId,
        provider: 'test',
        confidence: 0.5,
        confirmed: true,
        rejected: false,
        fetchedAt: DateTime(2026, 8, 20),
      ),
    );
    await db.insert('artwork_assets', {
      'artwork_id': _onlineArtworkId,
      'track_id': _onlineOnlyTrackId,
      'file_id': _onlineOnlyFileId,
      'source': 'online',
      'cache_path': '${temp.path}/online-low-confidence.jpg',
      'confidence': 0.5,
      'created_at': DateTime(2026, 8, 20).millisecondsSinceEpoch,
    });

    expect(
      (await library.libraryTrackById(_onlineOnlyTrackId))!.artwork,
      isNull,
    );

    await db.update(
      'artwork_assets',
      {'confidence': 0.9},
      where: 'artwork_id = ?',
      whereArgs: [_onlineArtworkId],
    );
    expect(
      (await library.libraryTrackById(_onlineOnlyTrackId))!.artwork?.artworkId,
      _onlineArtworkId,
    );
  });
}

const _trackId = '11111111-2222-4333-8444-555555555555';
const _preferredFileId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const _otherFileId = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff';
const _albumId = '10000000-0000-4000-8000-000000000001';
const _artistId = '20000000-0000-4000-8000-000000000001';
const _preferredArtworkId = '30000000-0000-4000-8000-000000000001';
const _otherArtworkId = '30000000-0000-4000-8000-000000000002';
const _manualArtworkId = '30000000-0000-4000-8000-000000000003';
const _onlineOnlyTrackId = '40000000-0000-4000-8000-000000000001';
const _onlineOnlyFileId = '50000000-0000-4000-8000-000000000001';
const _onlineArtworkId = '60000000-0000-4000-8000-000000000001';
const _onlineMetadataId = '70000000-0000-4000-8000-000000000001';
const _sharedAlbumTrackId = '80000000-0000-4000-8000-000000000001';
const _sharedAlbumFileId = '90000000-0000-4000-8000-000000000001';

Future<void> _seed(
  LibraryRepository library,
  LibraryDatabase database,
  Directory temp,
) async {
  final now = DateTime(2026, 8, 20);
  await library.saveArtist(
    const Artist(
      artistId: _artistId,
      displayName: '周杰伦',
      normalizedName: '周杰伦',
    ),
    now: now,
  );
  await library.saveAlbum(
    const Album(
      albumId: _albumId,
      title: '七里香',
      normalizedTitle: '七里香',
      albumArtistId: _artistId,
      year: 2004,
      albumType: 'studio',
    ),
    now: now,
  );
  await _createTrack(
    library,
    trackId: _trackId,
    fileId: _preferredFileId,
    albumId: _albumId,
    title: '借口',
  );
  final db = await database.database;
  await db.insert('track_artists', {
    'track_id': _trackId,
    'artist_id': _artistId,
    'role': 'primary',
    'position': 0,
  });
  await library.saveMediaFile(
    MediaFile(
      fileId: _otherFileId,
      trackId: _trackId,
      documentUri: 'content://music/other',
      filename: '借口.mp3',
      normalizedFilename: '借口.mp3',
      extension: 'mp3',
      mimeType: 'audio/mpeg',
      sizeBytes: 8000,
      durationMs: 200000,
      hashState: 'ready',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    ),
  );
  for (final values in [
    {
      'artwork_id': _preferredArtworkId,
      'file_id': _preferredFileId,
      'source': 'embedded',
      'cache_path': '${temp.path}/preferred.jpg',
    },
    {
      'artwork_id': _otherArtworkId,
      'file_id': _otherFileId,
      'source': 'embedded',
      'cache_path': '${temp.path}/other.jpg',
    },
    {
      'artwork_id': _manualArtworkId,
      'file_id': _preferredFileId,
      'source': 'manual',
      'cache_path': '${temp.path}/manual.jpg',
    },
  ]) {
    await db.insert('artwork_assets', {
      ...values,
      'track_id': _trackId,
      'confidence': 1.0,
      'created_at': now.millisecondsSinceEpoch,
    });
  }
  await db.insert('track_overrides', {
    'track_id': _trackId,
    'custom_artwork_id': _manualArtworkId,
    'updated_at': now.millisecondsSinceEpoch,
  });
}

Future<void> _createTrack(
  LibraryRepository library, {
  required String trackId,
  required String fileId,
  required String? albumId,
  required String title,
}) async {
  final now = DateTime(2026, 8, 20);
  await library.createTrack(
    Track(
      trackId: trackId,
      title: title,
      artistDisplay: '周杰伦',
      albumArtistDisplay: '周杰伦',
      albumDisplay: albumId == null ? '单曲' : '七里香',
      albumId: albumId,
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
      documentUri: 'content://music/$fileId',
      filename: '$title.flac',
      normalizedFilename: '$title.flac',
      extension: 'flac',
      mimeType: 'audio/flac',
      sizeBytes: 12000,
      durationMs: 200000,
      hashState: 'ready',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await library.setPreferredMediaFile(trackId, fileId);
}
