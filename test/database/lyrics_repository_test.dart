import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/data/library_repository.dart';
import 'package:my_music_library/data/lyrics_repository.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/services/library_database.dart';
import 'package:my_music_library/services/lyrics_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temp;
  late LibraryDatabase database;
  late LyricsRepository lyrics;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lyrics-repository-');
    database = LibraryDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/library.db',
    );
    lyrics = LyricsRepository(database);
    await _seed(database);
  });
  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  test('Track 能读取选中的 LRC，并合并文件和用户偏移', () async {
    final service = LyricsService(
      repository: lyrics,
      contentSource: const _MemoryLyricsSource({
        'content://lyrics/sidecar':
            '[offset:100]\n[00:01.00]<00:01.00>第一<00:01.40>句',
      }),
    );

    final result = await service.loadForTrack(_trackId);

    expect(result, isNotNull);
    expect(result!.reference.lyricsId, _sidecarLyricsId);
    expect(result.totalOffsetMs, 350);
    expect(result.lines.single.timestamp.inMilliseconds, 1350);
    expect(result.lines.single.text, '第一句');
    expect(
      result.lines.single.words.map((word) => word.timestamp.inMilliseconds),
      [1350, 1750],
    );
    expect(result.lines.single.words.first.endTimestamp?.inMilliseconds, 1750);
  });

  test('可以切换歌词来源并读取音频内嵌歌词', () async {
    await lyrics.setSelected(_trackId, _embeddedLyricsId);
    final service = LyricsService(
      repository: lyrics,
      contentSource: const _MemoryLyricsSource({}),
    );

    final result = await service.loadForTrack(_trackId);

    expect(result!.reference.source, 'embedded');
    expect(result.lines.single.text, '内嵌歌词');
  });

  test('歌词只能在所属 Track 内选择，偏移修改会持久化', () async {
    await expectLater(
      lyrics.setSelected(
        '99999999-8888-4777-8666-555555555555',
        _sidecarLyricsId,
      ),
      throwsStateError,
    );
    await lyrics.setOffset(_sidecarLyricsId, -120);

    expect((await lyrics.selectedForTrack(_trackId))!.offsetMs, -120);
  });
}

const _trackId = '11111111-2222-4333-8444-555555555555';
const _fileId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const _sidecarLyricsId = '10000000-0000-4000-8000-000000000001';
const _embeddedLyricsId = '10000000-0000-4000-8000-000000000002';

Future<void> _seed(LibraryDatabase database) async {
  final library = LibraryRepository(database);
  final now = DateTime(2026, 8, 20);
  await library.createTrack(
    Track(
      trackId: _trackId,
      title: '七里香',
      artistDisplay: '周杰伦',
      albumArtistDisplay: '周杰伦',
      albumDisplay: '七里香',
      durationMs: 200000,
      metadataState: 'complete',
      addedAt: now,
      updatedAt: now,
    ),
  );
  await library.saveMediaFile(
    MediaFile(
      fileId: _fileId,
      trackId: _trackId,
      contentUri: 'content://music/seven-miles',
      filename: '七里香.flac',
      normalizedFilename: '七里香.flac',
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
  final db = await database.database;
  await db.insert('file_metadata_raw', {
    'file_id': _fileId,
    'embedded_lyrics': '[00:02.00]内嵌歌词',
    'read_status': 'complete',
    'read_at': now.millisecondsSinceEpoch,
  });
  await db.insert('lyrics', {
    'lyrics_id': _sidecarLyricsId,
    'track_id': _trackId,
    'media_file_id': _fileId,
    'document_uri': 'content://lyrics/sidecar',
    'relative_path': '周杰伦/七里香.lrc',
    'filename': '七里香.lrc',
    'source': 'sidecarLrc',
    'match_method': 'exactBasename',
    'matched': 1,
    'confidence': 1.0,
    'offset_ms': 250,
    'is_selected': 1,
    'created_at': now.millisecondsSinceEpoch,
  });
  await db.insert('lyrics', {
    'lyrics_id': _embeddedLyricsId,
    'track_id': _trackId,
    'media_file_id': _fileId,
    'source': 'embedded',
    'match_method': 'embeddedTag',
    'matched': 1,
    'confidence': 1.0,
    'offset_ms': 0,
    'is_selected': 0,
    'created_at': now.millisecondsSinceEpoch,
  });
}

class _MemoryLyricsSource implements LyricsContentSource {
  const _MemoryLyricsSource(this.contents);

  final Map<String, String> contents;

  @override
  Future<String> read(String uri) async => contents[uri]!;
}
