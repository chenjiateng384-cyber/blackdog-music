import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/models/v4/library_browsing.dart';
import 'package:my_music_library/models/v4/library_entities.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/listening_data.dart';
import 'package:my_music_library/models/v4/track.dart';

void main() {
  test('专辑墙只保留至少三首歌曲的真实收藏', () {
    final albums = [
      _album('studio-one', type: 'studio', tracks: 1),
      _album('numbered-one', type: 'studio', tracks: 1, numbered: true),
      _album(
        'same-title',
        type: 'studio',
        tracks: 1,
        numbered: true,
        titleMatches: true,
      ),
      _album('single-many', type: 'single', tracks: 3),
      _album('unknown-one', type: 'unknown', tracks: 1),
      _album('unknown-many', type: 'unknown', tracks: 2),
      _album('unknown-three', type: 'unknown', tracks: 3),
      _album('placeholder', type: 'single', tracks: 20, title: '单曲'),
    ];

    expect(browsableAlbums(albums).map((item) => item.album.albumId), [
      'single-many',
      'unknown-three',
    ]);
  });

  test('合作歌手只取第一个作为主要歌手，同时不会误拆 AC/DC', () {
    expect(primaryArtistName('周杰伦 & 杨瑞代'), '周杰伦');
    expect(primaryArtistName('周杰伦 feat. Lara'), '周杰伦');
    expect(primaryArtistName('周杰伦/杨瑞代'), '周杰伦');
    expect(primaryArtistName('AC/DC'), 'AC/DC');
  });

  test('歌手页把未进入专辑收藏的歌曲归入单曲与其他', () {
    final album = _album('jay', type: 'studio', tracks: 3);
    final tracks = [
      _track('album-song', albumId: 'jay'),
      _track('loose-song'),
      _track('weak-album-song', albumId: 'metadata-only'),
    ];

    expect(
      standaloneTracks(tracks, [album]).map((item) => item.track.trackId),
      ['loose-song', 'weak-album-song'],
    );
  });

  test('专辑曲目始终按照 Disc、Track、标题排序', () {
    final tracks = [
      _track('d2t1', disc: 2, number: 1, title: '第二碟'),
      _track('d1t2', disc: 1, number: 2, title: '第二首'),
      _track('d1t1', disc: 1, number: 1, title: '第一首'),
      _track('unknown', title: '无编号'),
    ];

    expect(sortAlbumTracks(tracks).map((item) => item.track.trackId), [
      'd1t1',
      'd1t2',
      'd2t1',
      'unknown',
    ]);
  });

  test('全部歌曲支持按专辑曲序和最近添加排序', () {
    final early = _track(
      'early',
      albumId: 'b',
      album: 'B',
      number: 2,
      addedDay: 1,
    );
    final late = _track(
      'late',
      albumId: 'a',
      album: 'A',
      number: 1,
      addedDay: 2,
    );

    expect(
      sortLibraryTracks([
        early,
        late,
      ], LibraryBrowseSort.album).first.track.trackId,
      'late',
    );
    expect(
      sortLibraryTracks([
        early,
        late,
      ], LibraryBrowseSort.recentlyAdded).first.track.trackId,
      'late',
    );
  });

  test('常听程度综合喜欢、主动选择和完整播放而非原始播放次数', () {
    final rawCountOnly = _track('raw-count', playCount: 100);
    final activelyLoved = _track(
      'actively-loved',
      liked: true,
      completedCount: 4,
      manuallySelectedCount: 3,
    );

    expect(
      sortLibraryTracks([
        rawCountOnly,
        activelyLoved,
      ], LibraryBrowseSort.frequent).first.track.trackId,
      'actively-loved',
    );
  });

  test('专辑墙常听排序按专辑中真实收听质量聚合', () {
    final quiet = _album('quiet', type: 'studio', tracks: 3);
    final favorite = _album('favorite', type: 'studio', tracks: 3);
    final tracks = [
      _track('quiet-1', albumId: 'quiet', playCount: 40),
      _track(
        'favorite-1',
        albumId: 'favorite',
        liked: true,
        completedCount: 3,
        manuallySelectedCount: 2,
      ),
    ];

    expect(
      sortLibraryAlbumsByListening([
        quiet,
        favorite,
      ], tracks).first.album.albumId,
      'favorite',
    );
  });

  test('年份排序从旧到新，未知年份排在最后', () {
    final old = _track('old', year: 2000);
    final newTrack = _track('new', year: 2025);
    final unknown = _track('unknown-year');

    expect(
      sortLibraryTracks([
        unknown,
        newTrack,
        old,
      ], LibraryBrowseSort.year).map((item) => item.track.trackId),
      ['old', 'new', 'unknown-year'],
    );
  });

  test('中文歌曲标题按照拼音排列，数字使用自然顺序', () {
    final tracks = [
      _track('zhou', title: '周杰伦'),
      _track('eleven', title: '11月'),
      _track('deng', title: '邓紫棋'),
      _track('adele', title: 'Adele'),
      _track('two', title: '2月'),
      _track('chen', title: '陈奕迅'),
    ];

    expect(
      sortLibraryTracks(
        tracks,
        LibraryBrowseSort.title,
      ).map((item) => item.track.trackId),
      ['two', 'eleven', 'adele', 'chen', 'deng', 'zhou'],
    );
  });

  test('歌手和专辑聚合列表使用相同的拼音排序规则', () {
    final artists = [
      _artist('zhou', '周杰伦'),
      _artist('adele', 'Adele'),
      _artist('deng', '邓紫棋'),
      _artist('chen', '陈奕迅'),
    ];
    final albums = [
      _album('fantasy', type: 'studio', tracks: 2, title: '范特西'),
      _album('jay', type: 'studio', tracks: 2, title: 'Jay'),
      _album('qilixiang', type: 'studio', tracks: 2, title: '七里香'),
    ];

    expect(sortLibraryArtists(artists).map((item) => item.artist.artistId), [
      'adele',
      'chen',
      'deng',
      'zhou',
    ]);
    expect(sortLibraryAlbums(albums).map((item) => item.album.albumId), [
      'fantasy',
      'jay',
      'qilixiang',
    ]);
  });
}

AlbumLibrarySummary _album(
  String id, {
  required String type,
  required int tracks,
  bool numbered = false,
  bool titleMatches = false,
  String? title,
}) => AlbumLibrarySummary(
  album: Album(
    albumId: id,
    title: title ?? id,
    normalizedTitle: (title ?? id).toLowerCase(),
    albumArtistId: 'artist',
    albumType: type,
  ),
  trackCount: tracks,
  hasExplicitTrackNumber: numbered,
  onlyTrackTitleMatchesAlbum: titleMatches,
);

ArtistLibrarySummary _artist(String id, String name) => ArtistLibrarySummary(
  artist: Artist(
    artistId: id,
    displayName: name,
    normalizedName: name.toLowerCase(),
  ),
  trackCount: 2,
  albumCount: 1,
);

LibraryTrack _track(
  String id, {
  String? albumId,
  String album = '',
  int? disc,
  int? number,
  String? title,
  int addedDay = 1,
  int? year,
  int playCount = 0,
  int completedCount = 0,
  int manuallySelectedCount = 0,
  bool liked = false,
}) {
  final now = DateTime(2026, 8, addedDay);
  return LibraryTrack(
    track: Track(
      trackId: id,
      title: title ?? id,
      artistDisplay: '歌手',
      albumArtistDisplay: '歌手',
      albumDisplay: album,
      albumId: albumId,
      year: year,
      discNumber: disc,
      trackNumber: number,
      durationMs: 1000,
      metadataState: 'complete',
      addedAt: now,
      updatedAt: now,
    ),
    preference: TrackPreference(
      trackId: id,
      liked: liked,
      recommendationExcluded: false,
      updatedAt: now,
    ),
    stats: TrackStats(
      trackId: id,
      playCount: playCount,
      completedCount: completedCount,
      skipCount: 0,
      manuallySelectedCount: manuallySelectedCount,
      totalPlayDurationMs: completedCount * 1000,
      updatedAt: now,
    ),
  );
}
