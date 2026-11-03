import '../song.dart';
import 'library_track.dart';
import 'listening_data.dart';
import 'media_file.dart';
import 'track.dart';

class LegacySongCompatibility {
  const LegacySongCompatibility._();

  static Track draftTrackFromSong(
    Song song, {
    required String trackId,
    required DateTime now,
  }) {
    return Track(
      trackId: trackId,
      title: song.title,
      artistDisplay: song.artist,
      albumArtistDisplay: song.artist,
      albumDisplay: song.album,
      durationMs: song.duration.inMilliseconds,
      metadataState: song.metadataMatched ? 'complete' : 'needsReview',
      addedAt: song.dateAdded,
      updatedAt: now,
    );
  }

  static MediaFile draftMediaFileFromSong(
    Song song, {
    required String fileId,
    required String trackId,
    required DateTime now,
  }) {
    return MediaFile(
      fileId: fileId,
      trackId: trackId,
      mediaStoreId: song.id,
      contentUri: song.uri,
      filename: song.displayName,
      normalizedFilename: song.displayName.toLowerCase(),
      extension: song.extension,
      mimeType: song.mimeType,
      sizeBytes: song.sizeBytes,
      durationMs: song.duration.inMilliseconds,
      bitrate: song.bitrate,
      sampleRate: song.sampleRate,
      bitDepth: song.bitsPerSample,
      hashState: 'pending',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    );
  }

  static Song toLegacySong({
    required Track track,
    required MediaFile preferredFile,
    required int legacyNumericId,
  }) {
    return Song(
      id: legacyNumericId,
      uri: preferredFile.contentUri ?? preferredFile.documentUri ?? '',
      title: track.title,
      artist: track.artistDisplay,
      album: track.albumDisplay,
      duration: Duration(milliseconds: preferredFile.durationMs),
      dateAdded: track.addedAt,
      displayName: preferredFile.filename,
      mimeType: preferredFile.mimeType,
      sizeBytes: preferredFile.sizeBytes,
      bitrate: preferredFile.bitrate ?? 0,
      sampleRate: preferredFile.sampleRate ?? 0,
      bitsPerSample: preferredFile.bitDepth ?? 0,
    );
  }

  static Song libraryTrackToLegacySong(
    LibraryTrack item, {
    int? legacyNumericId,
  }) {
    final file = item.preferredFile;
    if (file == null) {
      throw StateError(
        'Track ${item.track.trackId} does not have a playable file',
      );
    }
    return toLegacySong(
      track: item.track,
      preferredFile: file,
      legacyNumericId:
          legacyNumericId ??
          item.legacySongId ??
          file.mediaStoreId ??
          stableLegacyId(item.track.trackId),
    );
  }

  static LibraryTrack libraryTrackFromLegacySong(Song song) {
    final now = DateTime.now();
    final trackId = 'legacy-track-${song.id}';
    return LibraryTrack(
      track: draftTrackFromSong(song, trackId: trackId, now: now),
      preferredFile: draftMediaFileFromSong(
        song,
        fileId: 'legacy-file-${song.id}',
        trackId: trackId,
        now: now,
      ),
      preference: TrackPreference.empty(trackId, now),
      stats: TrackStats.empty(trackId, now),
      legacySongId: song.id,
    );
  }

  static int stableLegacyId(String trackId) {
    var hash = 0x811c9dc5;
    for (final codeUnit in trackId.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }
}
