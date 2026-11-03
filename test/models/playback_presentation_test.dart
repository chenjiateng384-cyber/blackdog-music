import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/models/v4/listening_preference.dart';
import 'package:my_music_library/models/v4/playback.dart';

void main() {
  test('只有首页快捷播放来源使用水晶播放页', () {
    expect(
      const PlaybackContext(type: 'home_quick_start').playerPageKind,
      PlayerPageKind.crystal,
    );
    expect(
      const PlaybackContext(type: 'home_random').playerPageKind,
      PlayerPageKind.crystal,
    );
    expect(
      const PlaybackContext(type: 'album').playerPageKind,
      PlayerPageKind.immersive,
    );
    expect(
      const PlaybackContext(type: 'playlist').playerPageKind,
      PlayerPageKind.immersive,
    );
    expect(
      const PlaybackContext(type: 'home_smart_play').playerPageKind,
      PlayerPageKind.immersive,
    );
  });

  test('听歌偏好可序列化且 30 天后自动失效', () {
    final savedAt = DateTime(2026, 8, 1, 12);
    final original = ListeningPreference(
      familiarity: FamiliarityPreference.familiar,
      mood: MoodPreference.upbeat,
      scenes: const {'training': ScenePreferenceLevel.frequent},
      savedAt: savedAt,
    );
    final restored = ListeningPreference.fromJson(original.toJson());

    expect(restored.familiarity, FamiliarityPreference.familiar);
    expect(restored.mood, MoodPreference.upbeat);
    expect(restored.sceneLevel('training'), ScenePreferenceLevel.frequent);
    expect(restored.isActiveAt(savedAt.add(const Duration(days: 29))), isTrue);
    expect(restored.isActiveAt(savedAt.add(const Duration(days: 30))), isFalse);
  });
}
