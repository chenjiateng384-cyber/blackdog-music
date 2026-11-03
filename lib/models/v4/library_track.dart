import 'artwork.dart';
import 'library_entities.dart';
import 'listening_data.dart';
import 'media_file.dart';
import 'track.dart';

enum LibraryTrackSort {
  title,
  artist,
  album,
  recentlyAdded,
  recentlyPlayed,
  playCount,
}

class LibraryTrack {
  const LibraryTrack({
    required this.track,
    required this.preference,
    required this.stats,
    this.preferredFile,
    this.artwork,
    this.legacySongId,
  });

  final Track track;
  final MediaFile? preferredFile;
  final ArtworkReference? artwork;
  final TrackPreference preference;
  final TrackStats stats;
  final int? legacySongId;

  bool get isPlayable => playbackUri != null;

  String? get playbackUri {
    final uri = preferredFile?.documentUri ?? preferredFile?.contentUri;
    return uri == null || uri.isEmpty ? null : uri;
  }

  LibraryTrack copyWith({
    Track? track,
    MediaFile? preferredFile,
    ArtworkReference? artwork,
    TrackPreference? preference,
    TrackStats? stats,
    int? legacySongId,
  }) => LibraryTrack(
    track: track ?? this.track,
    preferredFile: preferredFile ?? this.preferredFile,
    artwork: artwork ?? this.artwork,
    preference: preference ?? this.preference,
    stats: stats ?? this.stats,
    legacySongId: legacySongId ?? this.legacySongId,
  );
}

class ArtistLibrarySummary {
  const ArtistLibrarySummary({
    required this.artist,
    required this.trackCount,
    required this.albumCount,
    this.sourceArtistIds = const [],
    this.playCount = 0,
    this.isCuratedFolder = false,
    this.artwork,
  });

  final Artist artist;
  final int trackCount;
  final int albumCount;

  /// Artist rows folded into this primary-artist display entry.
  final List<String> sourceArtistIds;
  final int playCount;
  final bool isCuratedFolder;
  final ArtworkReference? artwork;

  List<String> get allArtistIds =>
      sourceArtistIds.isEmpty ? <String>[artist.artistId] : sourceArtistIds;
}

class AlbumLibrarySummary {
  const AlbumLibrarySummary({
    required this.album,
    required this.trackCount,
    this.hasExplicitTrackNumber = false,
    this.onlyTrackTitleMatchesAlbum = false,
    this.artwork,
  });

  final Album album;
  final int trackCount;
  final bool hasExplicitTrackNumber;
  final bool onlyTrackTitleMatchesAlbum;
  final ArtworkReference? artwork;
}

class LibraryCounts {
  const LibraryCounts({
    required this.trackCount,
    required this.artistCount,
    required this.albumCount,
    required this.likedCount,
  });

  final int trackCount;
  final int artistCount;
  final int albumCount;
  final int likedCount;
}

class PlaylistLibrarySummary {
  const PlaylistLibrarySummary({
    required this.playlist,
    required this.trackCount,
  });

  final Playlist playlist;
  final int trackCount;
}
