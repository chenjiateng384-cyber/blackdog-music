import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/models/song.dart';

void main() {
  test('歌曲时长按 分:秒 显示', () {
    expect(formatDuration(const Duration(seconds: 65)), '1:05');
  });

  test('缺少歌曲信息时使用中文占位名称', () {
    final song = Song.fromMap({
      'id': 1,
      'uri': 'content://music/1',
      'title': '',
      'artist': '<unknown>',
      'album': '',
      'duration': 1000,
      'dateAdded': 0,
    });

    expect(song.title, '未知歌曲');
    expect(song.artist, '未知歌手');
    expect(song.album, '未知专辑');
  });

  test('从 歌手 - 歌名 文件名自动识别信息', () {
    final song = Song.fromMap({
      'id': 2,
      'uri': 'content://music/2',
      'title': '周杰伦 - 晴天.mp3',
      'artist': '<unknown>',
      'album': '',
      'displayName': '周杰伦 - 晴天.mp3',
      'mimeType': 'audio/mpeg',
      'size': 10000000,
      'duration': 240000,
      'bitrate': 320000,
      'dateAdded': 0,
    });

    expect(song.artist, '周杰伦');
    expect(song.title, '晴天');
  });

  test('高码率 MP3 不提示升级，低码率 MP3 提示升级', () {
    Song mp3(int id, int bitrate) => Song.fromMap({
          'id': id,
          'uri': 'content://music/$id',
          'title': '测试歌曲',
          'artist': '测试歌手',
          'album': '测试专辑',
          'displayName': '测试歌曲.mp3',
          'mimeType': 'audio/mpeg',
          'size': 8000000,
          'duration': 240000,
          'bitrate': bitrate,
          'dateAdded': 0,
        });

    expect(mp3(3, 320000).needsUpgrade, isFalse);
    expect(mp3(4, 128000).needsUpgrade, isTrue);
  });

  test('时长或大小异常时标记可疑文件', () {
    final song = Song.fromMap({
      'id': 5,
      'uri': 'content://music/5',
      'title': '损坏文件',
      'artist': '未知歌手',
      'album': '',
      'displayName': '损坏文件.flac',
      'mimeType': 'audio/flac',
      'size': 0,
      'duration': 0,
      'dateAdded': 0,
    });

    expect(song.isSuspicious, isTrue);
  });

  test('内部哈希值不会显示成歌手名', () {
    final song = Song.fromMap({
      'id': 6,
      'uri': 'content://music/6',
      'title': '晴天',
      'artist': 'd9b036cc9a22ddb1f13b7a433b8d993a',
      'album': '',
      'displayName': '晴天.mp3',
      'mimeType': 'audio/mpeg',
      'size': 8000000,
      'duration': 240000,
      'bitrate': 256000,
      'dateAdded': 0,
    });

    expect(song.artist, '未知歌手');
  });
}
