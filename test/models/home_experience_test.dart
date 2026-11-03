import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/models/v4/home_experience.dart';
import 'package:my_music_library/models/v4/library_entities.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/listening_data.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/track.dart';

void main() {
  test('首页音乐只组合现有数据、去重，并排除不可播放和不参与推荐歌曲', () {
    final frequent = _track('frequent', artist: '周杰伦', playCount: 8);
    final liked = _track('liked', artist: '邓紫棋', liked: true);
    final recent = _track('recent', artist: '周杰伦', recentlyPlayed: true);
    final added = _track('added', artist: 'Adele');
    final excluded = _track('excluded', excluded: true, playCount: 9);
    final unavailable = _track('unavailable', playable: false);

    final experience = HomeExperience.compose(
      liked: [liked, frequent],
      mostPlayed: [excluded, frequent],
      recentlyPlayed: [recent, unavailable],
      recentlyAdded: [added],
      artists: const [],
    );

    expect(experience.quickStartTracks.map((item) => item.track.trackId), [
      'liked',
      'recent',
      'added',
      'frequent',
    ]);
    expect(experience.todayTracks.map((item) => item.track.trackId), [
      'recent',
      'liked',
      'added',
      'frequent',
    ]);
  });

  test('常听歌手严格按照已有播放顺序生成，没有记录时不伪造歌手', () {
    final artists = [
      _artist('jay', '周杰伦'),
      _artist('gem', '邓紫棋'),
      _artist('adele', 'Adele'),
    ];
    final experience = HomeExperience.compose(
      liked: const [],
      mostPlayed: [
        _track('gem-track', artist: '邓紫棋', playCount: 12),
        _track('jay-track', artist: '周杰伦', playCount: 9),
      ],
      recentlyPlayed: [
        _track('adele-track', artist: 'Adele', recentlyPlayed: true),
      ],
      recentlyAdded: const [],
      artists: artists,
    );

    expect(experience.frequentArtists.map((item) => item.artist.displayName), [
      '邓紫棋',
      '周杰伦',
      'Adele',
    ]);

    final empty = HomeExperience.compose(
      liked: const [],
      mostPlayed: const [],
      recentlyPlayed: const [],
      recentlyAdded: [_track('only-added', artist: '周杰伦')],
      artists: artists,
    );
    expect(empty.frequentArtists, isEmpty);
  });

  test('今日音乐同一天保持固定，且不受行为列表顺序变化影响', () {
    final library = List.generate(40, (index) => _track('track-$index'));
    final first = HomeExperience.compose(
      liked: [library[1], library[2]],
      mostPlayed: [library[3], library[4]],
      recentlyPlayed: [library[5], library[6]],
      recentlyAdded: [library[7], library[8]],
      artists: const [],
      allTracks: library,
      day: DateTime(2026, 8, 24, 8),
    );
    final afterPlayback = HomeExperience.compose(
      liked: [library[2], library[1]],
      mostPlayed: [library[4], library[3]],
      recentlyPlayed: [library[9], library[5]],
      recentlyAdded: [library[8], library[7]],
      artists: const [],
      allTracks: library.reversed.toList(),
      day: DateTime(2026, 8, 24, 22),
    );

    expect(
      afterPlayback.todayTracks.map((item) => item.track.trackId),
      first.todayTracks.map((item) => item.track.trackId),
    );
    expect(first.todayTracks, hasLength(30));
  });

  test('今日音乐次日自然更新，并排除不可播放和不参与推荐歌曲', () {
    final library = [
      ...List.generate(10, (index) => _track('track-$index')),
      _track('excluded', excluded: true),
      _track('unavailable', playable: false),
    ];
    final firstDay = HomeExperience.compose(
      liked: const [],
      mostPlayed: const [],
      recentlyPlayed: const [],
      recentlyAdded: const [],
      artists: const [],
      allTracks: library,
      day: DateTime(2026, 8, 24),
    );
    final nextDay = HomeExperience.compose(
      liked: const [],
      mostPlayed: const [],
      recentlyPlayed: const [],
      recentlyAdded: const [],
      artists: const [],
      allTracks: library,
      day: DateTime(2026, 8, 25),
    );

    expect(
      firstDay.todayTracks.map((item) => item.track.trackId),
      isNot(nextDay.todayTracks.map((item) => item.track.trackId)),
    );
    expect(
      firstDay.todayTracks.map((item) => item.track.trackId),
      isNot(contains('excluded')),
    );
    expect(
      firstDay.todayTracks.map((item) => item.track.trackId),
      isNot(contains('unavailable')),
    );
  });
}

final _now = DateTime(2026, 8, 21);

LibraryTrack _track(
  String id, {
  String artist = '歌手',
  bool liked = false,
  bool excluded = false,
  bool playable = true,
  bool recentlyPlayed = false,
  int playCount = 0,
}) => LibraryTrack(
  track: Track(
    trackId: id,
    title: id,
    artistDisplay: artist,
    albumArtistDisplay: artist,
    albumDisplay: '专辑',
    durationMs: 180000,
    metadataState: 'complete',
    addedAt: _now,
    updatedAt: _now,
  ),
  preferredFile: playable
      ? MediaFile(
          fileId: '$id-file',
          trackId: id,
          documentUri: 'content://music/$id',
          filename: '$id.flac',
          normalizedFilename: '$id.flac',
          extension: 'flac',
          mimeType: 'audio/flac',
          sizeBytes: 100,
          durationMs: 180000,
          hashState: 'pending',
          status: 'active',
          createdAt: _now,
          updatedAt: _now,
        )
      : null,
  preference: TrackPreference(
    trackId: id,
    liked: liked,
    recommendationExcluded: excluded,
    updatedAt: _now,
  ),
  stats: TrackStats(
    trackId: id,
    playCount: playCount,
    completedCount: playCount,
    skipCount: 0,
    manuallySelectedCount: playCount,
    totalPlayDurationMs: playCount * 180000,
    lastPlayedAt: recentlyPlayed || playCount > 0 ? _now : null,
    updatedAt: _now,
  ),
);

ArtistLibrarySummary _artist(String id, String name) => ArtistLibrarySummary(
  artist: Artist(
    artistId: id,
    displayName: name,
    normalizedName: name.toLowerCase(),
  ),
  trackCount: 10,
  albumCount: 2,
);
