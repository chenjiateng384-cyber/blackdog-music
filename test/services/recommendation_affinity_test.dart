import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/models/v4/library_track.dart';
import 'package:my_music_library/models/v4/listening_data.dart';
import 'package:my_music_library/models/v4/media_file.dart';
import 'package:my_music_library/models/v4/recommendation_behavior.dart';
import 'package:my_music_library/models/v4/track.dart';
import 'package:my_music_library/services/recommendation_affinity.dart';

void main() {
  test('合作歌曲反馈归入主要歌手并提升其未听歌曲', () {
    final accepted = _track('accepted', artist: '周杰伦 & 杨瑞代');
    final unseen = _track('unseen', artist: '周杰伦');
    final unrelated = _track('unrelated', artist: '其他歌手');
    final profile = RecommendationAffinityProfile.fromLibrary(
      [accepted, unseen, unrelated],
      {
        accepted.track.trackId: RecommendationBehaviorSignal(
          trackId: accepted.track.trackId,
          acceptedCount: 10,
          rejectedCount: 0,
          directAcceptedCount: 4,
          recentExposureCount: 0,
          matchingTimeAcceptedCount: 2,
          lastAcceptedAt: DateTime(2026, 9, 1),
        ),
      },
    );

    expect(profile.multiplierFor(unseen), greaterThan(1.4));
    expect(
      profile.multiplierFor(unseen),
      greaterThan(profile.multiplierFor(unrelated)),
    );
  });

  test('没有事件证据时旧手动计数不会扩散成歌手偏好', () {
    final polluted = _track(
      'polluted',
      artist: '旧自动播放歌手',
      manuallySelectedCount: 20,
    );
    final unseen = _track('unseen', artist: '旧自动播放歌手');
    final profile = RecommendationAffinityProfile.fromLibrary([
      polluted,
      unseen,
    ], const {});

    expect(profile.multiplierFor(unseen), 1);
  });
}

LibraryTrack _track(
  String id, {
  required String artist,
  int manuallySelectedCount = 0,
}) {
  final now = DateTime(2026, 9, 1);
  return LibraryTrack(
    track: Track(
      trackId: id,
      title: id,
      artistDisplay: artist,
      albumArtistDisplay: artist,
      albumDisplay: '单曲',
      durationMs: 180000,
      metadataState: 'complete',
      addedAt: now,
      updatedAt: now,
    ),
    preferredFile: MediaFile(
      fileId: '$id-file',
      trackId: id,
      documentUri: 'content://music/$id',
      filename: '$id.flac',
      normalizedFilename: '$id.flac',
      extension: 'flac',
      mimeType: 'audio/flac',
      sizeBytes: 100,
      durationMs: 180000,
      hashState: 'ready',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    ),
    preference: TrackPreference.empty(id, now),
    stats: TrackStats(
      trackId: id,
      playCount: manuallySelectedCount,
      completedCount: 0,
      skipCount: 0,
      manuallySelectedCount: manuallySelectedCount,
      totalPlayDurationMs: 0,
      updatedAt: now,
    ),
  );
}
