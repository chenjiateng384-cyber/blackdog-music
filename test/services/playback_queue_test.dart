import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/listening_data.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/playback.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/services/playback_queue.dart';

void main() {
  final a = _track('track-a');
  final b = _track('track-b');
  final c = _track('track-c');
  final d = _track('track-d');

  test('顺序播放在队列边界停止', () {
    final queue = PlaybackQueue()..setTracks([a, b, c]);

    queue.select(a);
    expect(queue.next(automatic: true)?.track.trackId, 'track-b');
    expect(queue.next(automatic: true)?.track.trackId, 'track-c');
    expect(queue.next(automatic: true), isNull);
    expect(queue.previous()?.track.trackId, 'track-b');
  });

  test('列表循环在队尾回到第一首', () {
    final queue = PlaybackQueue()
      ..setTracks([a, b, c])
      ..setMode(PlaybackMode.repeatAll)
      ..select(c);

    expect(queue.next(automatic: true)?.track.trackId, 'track-a');
    expect(queue.previous()?.track.trackId, 'track-c');
  });

  test('单曲循环仅自动完成时重复，用户手动下一首仍前进', () {
    final queue = PlaybackQueue()
      ..setTracks([a, b, c])
      ..setMode(PlaybackMode.repeatOne)
      ..select(b);

    expect(queue.next(automatic: true)?.track.trackId, 'track-b');
    expect(queue.next(automatic: false)?.track.trackId, 'track-c');
  });

  test('次数循环会有限重复当前歌曲并在完成后回到顺序播放', () {
    final queue = PlaybackQueue()
      ..setTracks([a, b, c])
      ..select(b)
      ..setRepeatCount(3);

    expect(queue.snapshot(PlaybackContext.library).repeatLeft, 3);
    expect(queue.next(automatic: true)?.track.trackId, 'track-b');
    expect(queue.repeatLeft, 2);
    expect(queue.next(automatic: true)?.track.trackId, 'track-b');
    expect(queue.repeatLeft, 1);
    expect(queue.next(automatic: true)?.track.trackId, 'track-c');
    expect(queue.mode, PlaybackMode.sequential);
    expect(queue.repeatCount, isNull);
  });

  test('次数循环下手动切歌保留模式并重置新歌曲次数', () {
    final queue = PlaybackQueue()
      ..setTracks([a, b, c])
      ..select(a)
      ..setRepeatCount(4);

    expect(queue.next(automatic: true)?.track.trackId, 'track-a');
    expect(queue.repeatLeft, 3);
    expect(queue.next(automatic: false)?.track.trackId, 'track-b');
    expect(queue.mode, PlaybackMode.repeatCount);
    expect(queue.repeatLeft, 4);
  });

  test('次数循环只接受 2 到 5 次', () {
    final queue = PlaybackQueue()..setTracks([a]);

    expect(() => queue.setRepeatCount(1), throwsRangeError);
    expect(() => queue.setRepeatCount(6), throwsRangeError);
  });

  test('普通随机每轮不重复，并避免轮次边界立即播放同一首', () {
    final queue = PlaybackQueue(random: Random(7))
      ..setTracks([a, b, c])
      ..setMode(PlaybackMode.shuffle);
    final firstCycle = <String>[];
    for (var index = 0; index < 3; index++) {
      firstCycle.add(queue.next(automatic: true)!.track.trackId);
    }
    final nextCycleFirst = queue.next(automatic: true)!.track.trackId;

    expect(firstCycle.toSet(), {'track-a', 'track-b', 'track-c'});
    expect(nextCycleFirst, isNot(firstCycle.last));
  });

  test('智能随机使用可替换排序策略，本阶段不内置推荐权重', () {
    final strategy = _ReverseSmartOrder();
    final queue = PlaybackQueue(smartOrder: strategy)
      ..setTracks([a, b, c])
      ..select(a)
      ..setMode(PlaybackMode.smartShuffle);

    expect(queue.trackIds, ['track-a', 'track-c', 'track-b']);
    expect(strategy.calls, 1);
    expect(queue.next(automatic: true)?.track.trackId, 'track-c');
  });

  test('没有真实文件的 Track 不进入播放队列', () {
    final queue = PlaybackQueue()..setTracks([a, _track('unavailable', false)]);

    expect(queue.trackIds, ['track-a']);
  });

  test('插播、追加和清空只改变待播部分', () {
    final queue = PlaybackQueue()
      ..setTracks([a, b, c])
      ..select(a);

    queue.insertNext(d);
    queue.appendAll([a]);
    expect(queue.trackIds, [
      'track-a',
      'track-d',
      'track-b',
      'track-c',
      'track-a',
    ]);

    expect(queue.clearUpcoming(), 4);
    expect(queue.trackIds, ['track-a']);
    expect(queue.current?.track.trackId, 'track-a');
  });

  test('同一 Track 可重复入队并通过 entryId 精确操作', () {
    final queue = PlaybackQueue()
      ..setTracks([a, b])
      ..select(a);
    final duplicate = queue.appendAll([a]).single;

    expect(queue.entries.map((entry) => entry.entryId).toSet().length, 3);
    expect(
      queue.selectEntry(duplicate.entryId)?.track.track.trackId,
      'track-a',
    );
    expect(queue.currentEntry?.entryId, duplicate.entryId);
  });

  test('待播队列可重排、删除，当前歌曲不可误删', () {
    final queue = PlaybackQueue()
      ..setTracks([a, b, c, d])
      ..select(a);

    expect(queue.moveUpcoming(2, 0), isTrue);
    expect(queue.trackIds, ['track-a', 'track-d', 'track-b', 'track-c']);
    final dEntry = queue.entries[1];
    expect(queue.removeEntry(dEntry.entryId), isTrue);
    expect(queue.trackIds, ['track-a', 'track-b', 'track-c']);
    expect(queue.removeEntry(queue.currentEntry!.entryId), isFalse);
  });

  test('1000 首队列切换当前歌曲不会复制或重建整条队列', () {
    final tracks = List.generate(1000, (index) => _track('track-$index'));
    final queue = PlaybackQueue()..setTracks(tracks);
    final stableEntries = queue.entries;
    final stopwatch = Stopwatch()..start();

    for (var index = 0; index < 250; index++) {
      queue.select(tracks[index * 3]);
      final snapshot = queue.snapshot(PlaybackContext.library);
      expect(snapshot.entries, same(stableEntries));
    }
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });
}

class _ReverseSmartOrder implements SmartPlaybackOrder {
  int calls = 0;

  @override
  List<LibraryTrack> buildOrder(
    List<LibraryTrack> tracks, {
    LibraryTrack? current,
  }) {
    calls++;
    return tracks.reversed.toList(growable: false);
  }
}

LibraryTrack _track(String id, [bool playable = true]) {
  final now = DateTime(2026, 8, 20);
  return LibraryTrack(
    track: Track(
      trackId: id,
      title: id,
      artistDisplay: '歌手',
      albumArtistDisplay: '歌手',
      albumDisplay: '专辑',
      durationMs: 180000,
      metadataState: 'complete',
      addedAt: now,
      updatedAt: now,
    ),
    preferredFile: playable
        ? MediaFile(
            fileId: 'file-$id',
            trackId: id,
            contentUri: 'content://music/$id',
            filename: '$id.flac',
            normalizedFilename: '$id.flac',
            extension: 'flac',
            mimeType: 'audio/flac',
            sizeBytes: 1000,
            durationMs: 180000,
            hashState: 'ready',
            status: 'active',
            createdAt: now,
            updatedAt: now,
          )
        : null,
    preference: TrackPreference.empty(id, now),
    stats: TrackStats.empty(id, now),
  );
}
