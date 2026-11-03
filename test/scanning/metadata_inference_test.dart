import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/models/v4/scan_models.dart';
import 'package:my_music_library/services/lrc_matcher.dart';
import 'package:my_music_library/services/metadata_inference.dart';
import 'package:my_music_library/services/metadata_resolver.dart';

void main() {
  const inference = MetadataInference();
  const resolver = MetadataResolver();
  const matcher = LrcMatcher();

  test('周杰伦年份专辑目录和曲序被保守识别', () {
    final file = scanned(
      relativePath: '周杰伦/2004_七里香/03_借口.flac',
      filename: '03_借口.flac',
    );
    final result = inference.infer(file);
    expect(result.artist, '周杰伦');
    expect(result.album, '七里香');
    expect(result.year, 2004);
    expect(result.trackNumber, 3);
    expect(result.title, '借口');
    expect(result.albumType, 'studio');
  });

  test('邓紫棋中英文专辑、EP 与 Live 目录类型正确', () {
    final album = inference.infer(
      scanned(
        relativePath: '邓紫棋/专辑/2010_My Secret/01_One Button.flac',
        filename: '01_One Button.flac',
      ),
    );
    final single = inference.infer(
      scanned(relativePath: '邓紫棋/EP与单曲/新的心跳.flac', filename: '新的心跳.flac'),
    );
    final live = inference.infer(
      scanned(relativePath: '邓紫棋/演唱会Live/泡沫.flac', filename: '泡沫.flac'),
    );
    expect(album.album, 'My Secret');
    expect(album.year, 2010);
    expect(single.albumType, 'single');
    expect(live.albumType, 'live');
  });

  test('Raw Metadata 优先于目录和文件名，Override 优先于 Raw', () {
    final file = scanned(
      relativePath: '错误歌手/2004_错误专辑/03_错误歌名.flac',
      filename: '03_错误歌名.flac',
      metadata: const AudioTagSnapshot(
        title: '正确歌名',
        artist: '正确歌手',
        album: '正确专辑',
        albumArtist: '正确歌手',
        year: 2020,
        trackNumber: 8,
        durationMs: 1000,
        readStatus: 'complete',
      ),
    );
    final inferred = inference.infer(file);
    final raw = resolver.resolve(raw: file.metadata, inferred: inferred);
    final overridden = resolver.resolve(
      raw: file.metadata,
      inferred: inferred,
      override: const {'title': '人工歌名', 'artist': '人工歌手'},
    );
    expect(raw.title, '正确歌名');
    expect(raw.artist, '正确歌手');
    expect(raw.album, '正确专辑');
    expect(raw.trackNumber, 8);
    expect(raw.metadataState, 'complete');
    expect(overridden.title, '人工歌名');
    expect(overridden.artist, '人工歌手');
    expect(overridden.album, '正确专辑');
  });

  test('文件名双向歌手格式只在目录提供证据时反向识别', () {
    final artistFirst = inference.infer(
      scanned(
        relativePath: '周杰伦/EP与单曲/周杰伦 - 稻香.flac',
        filename: '周杰伦 - 稻香.flac',
      ),
    );
    final artistLast = inference.infer(
      scanned(
        relativePath: '周杰伦/EP与单曲/稻香 - 周杰伦.flac',
        filename: '稻香 - 周杰伦.flac',
      ),
    );
    expect(artistFirst.title, '稻香');
    expect(artistLast.title, '稻香');
    expect(artistFirst.artist, '周杰伦');
    expect(artistLast.artist, '周杰伦');
  });

  test('分类目录不冒充歌手，明确的歌曲名-合作歌手优先于目录', () {
    final wasted = inference.infer(
      scanned(
        relativePath: '英文歌/其他版本/Wasted(伴奏)-huken&Murkish&harmony haven.wav',
        filename: 'Wasted(伴奏)-huken&Murkish&harmony haven.wav',
      ),
    );
    final angel = inference.infer(
      scanned(
        relativePath: '英文歌/其他版本/Angel(伴奏)- DJ铁柱&DJ仔仔.wav',
        filename: 'Angel(伴奏)- DJ铁柱&DJ仔仔.wav',
      ),
    );

    expect(wasted.title, 'Wasted(伴奏)');
    expect(wasted.artist, 'huken&Murkish&harmony haven');
    expect(angel.title, 'Angel(伴奏)');
    expect(angel.artist, 'DJ铁柱&DJ仔仔');
    expect(wasted.album, isNull);
    expect(angel.album, isNull);
  });

  test('无效的分类 Artist 标签不会覆盖文件名解析结果', () {
    final file = scanned(
      relativePath: '英文歌/其他版本/Wasted(伴奏)-huken&Murkish&harmony haven.wav',
      filename: 'Wasted(伴奏)-huken&Murkish&harmony haven.wav',
      metadata: const AudioTagSnapshot(
        artist: '英文歌',
        durationMs: 1000,
        readStatus: 'partial',
      ),
    );
    final resolved = resolver.resolve(
      raw: file.metadata,
      inferred: inference.infer(file),
    );

    expect(resolved.title, 'Wasted(伴奏)');
    expect(resolved.artist, 'huken&Murkish&harmony haven');
  });

  test('LRC 按同名、去曲序、歌手加歌名三级匹配', () {
    final exactAudio = scanned(
      relativePath: '周杰伦/七里香/七里香.flac',
      filename: '七里香.flac',
      lyrics: [lyrics('七里香.lrc')],
    );
    final numberedAudio = scanned(
      relativePath: '周杰伦/七里香/03_七里香.flac',
      filename: '03_七里香.flac',
      lyrics: [lyrics('七里香.lrc')],
    );
    final artistAudio = scanned(
      relativePath: '周杰伦/七里香/周杰伦 - 七里香.flac',
      filename: '周杰伦 - 七里香.flac',
      lyrics: [lyrics('七里香.lrc')],
    );
    expect(
      matcher
          .match(audio: exactAudio, resolvedTitle: '七里香', resolvedArtist: '周杰伦')
          ?.method,
      'exactBasename',
    );
    expect(
      matcher
          .match(
            audio: numberedAudio,
            resolvedTitle: '七里香',
            resolvedArtist: '周杰伦',
          )
          ?.method,
      'normalizedWithoutTrack',
    );
    expect(
      matcher
          .match(
            audio: artistAudio,
            resolvedTitle: '七里香',
            resolvedArtist: '周杰伦',
          )
          ?.method,
      'artistAndTitleNormalized',
    );
  });

  test('多个同名 LRC 候选时不乱绑定', () {
    final audio = scanned(
      relativePath: '英文歌/Test Song.mp3',
      filename: 'Test Song.mp3',
      lyrics: [lyrics('Test Song.lrc', id: 1), lyrics('Test Song.LRC', id: 2)],
    );
    expect(
      matcher.match(
        audio: audio,
        resolvedTitle: 'Test Song',
        resolvedArtist: 'Artist',
      ),
      isNull,
    );
  });
}

ScannedAudioFile scanned({
  required String relativePath,
  required String filename,
  AudioTagSnapshot metadata = const AudioTagSnapshot(
    durationMs: 0,
    readStatus: 'failed',
  ),
  List<LyricsCandidate> lyrics = const [],
}) => ScannedAudioFile(
  documentUri: 'content://test/$relativePath',
  relativePath: relativePath,
  parentFolder: relativePath.split('/').reversed.elementAt(1),
  filename: filename,
  extension: filename.split('.').last,
  mimeType: 'audio/test',
  sizeBytes: 100,
  metadata: metadata,
  lyricsCandidates: lyrics,
);

LyricsCandidate lyrics(String filename, {int id = 1}) => LyricsCandidate(
  documentUri: 'content://lyrics/$id/$filename',
  relativePath: filename,
  filename: filename,
  sizeBytes: 10,
);
