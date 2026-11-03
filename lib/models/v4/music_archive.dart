import 'library_track.dart';

class MusicArchiveSnapshot {
  const MusicArchiveSnapshot({
    required this.year,
    required this.validEventCount,
    required this.distinctTrackCount,
    required this.listenedDurationMs,
    required this.likedCount,
    required this.playlistCount,
    this.topTrack,
    this.topArtist,
    this.topAlbum,
    this.listeningPeriod,
    this.recordStartedAt,
  });

  final int year;
  final int validEventCount;
  final int distinctTrackCount;
  final int listenedDurationMs;
  final int likedCount;
  final int playlistCount;
  final LibraryTrack? topTrack;
  final String? topArtist;
  final String? topAlbum;
  final String? listeningPeriod;
  final DateTime? recordStartedAt;

  bool get hasListeningData => validEventCount > 0;

  factory MusicArchiveSnapshot.empty(int year) => MusicArchiveSnapshot(
    year: year,
    validEventCount: 0,
    distinctTrackCount: 0,
    listenedDurationMs: 0,
    likedCount: 0,
    playlistCount: 0,
  );
}
