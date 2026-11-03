import 'library_track.dart';

class LibraryFolder {
  const LibraryFolder({
    required this.scanRootId,
    required this.relativePath,
    required this.name,
    required this.parentPath,
    required this.depth,
    required this.directTrackCount,
    required this.descendantTrackCount,
  });

  final String scanRootId;
  final String relativePath;
  final String name;
  final String? parentPath;
  final int depth;
  final int directTrackCount;
  final int descendantTrackCount;
}

enum LibrarySearchResultType { track, artist, album, folder }

class RankedLibrarySearchResult {
  const RankedLibrarySearchResult({
    required this.type,
    required this.score,
    required this.label,
    required this.stableKey,
    this.track,
    this.artist,
    this.album,
    this.folder,
  });

  final LibrarySearchResultType type;
  final int score;
  final String label;
  final String stableKey;
  final LibraryTrack? track;
  final ArtistLibrarySummary? artist;
  final AlbumLibrarySummary? album;
  final LibraryFolder? folder;
}

class LibrarySearchResults {
  const LibrarySearchResults({
    required this.query,
    required this.tracks,
    required this.artists,
    required this.albums,
    required this.folders,
    required this.ordered,
  });

  factory LibrarySearchResults.empty(String query) => LibrarySearchResults(
    query: query,
    tracks: const [],
    artists: const [],
    albums: const [],
    folders: const [],
    ordered: const [],
  );

  final String query;
  final List<LibraryTrack> tracks;
  final List<ArtistLibrarySummary> artists;
  final List<AlbumLibrarySummary> albums;
  final List<LibraryFolder> folders;
  final List<RankedLibrarySearchResult> ordered;
}
