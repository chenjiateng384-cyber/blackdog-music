enum FamiliarityPreference { explore, balanced, familiar }

enum MoodPreference { melancholic, balanced, upbeat }

enum ScenePreferenceLevel { balanced, frequent, random }

const harmonyListeningScenes = <String>[
  'training',
  'cycling',
  'home',
  'focus',
  'night',
  'energy',
];

class ListeningPreference {
  const ListeningPreference({
    this.familiarity = FamiliarityPreference.balanced,
    this.mood = MoodPreference.balanced,
    this.scenes = const {},
    this.savedAt,
  });

  final FamiliarityPreference familiarity;
  final MoodPreference mood;
  final Map<String, ScenePreferenceLevel> scenes;
  final DateTime? savedAt;

  bool isActiveAt(DateTime now) =>
      savedAt != null && now.difference(savedAt!).inDays < 30;

  ScenePreferenceLevel sceneLevel(String scene) =>
      scenes[scene] ?? ScenePreferenceLevel.balanced;

  ListeningPreference copyWith({
    FamiliarityPreference? familiarity,
    MoodPreference? mood,
    Map<String, ScenePreferenceLevel>? scenes,
    DateTime? savedAt,
    bool clearSavedAt = false,
  }) => ListeningPreference(
    familiarity: familiarity ?? this.familiarity,
    mood: mood ?? this.mood,
    scenes: Map.unmodifiable(scenes ?? this.scenes),
    savedAt: clearSavedAt ? null : savedAt ?? this.savedAt,
  );

  Map<String, Object?> toJson() => {
    'familiarity': familiarity.name,
    'mood': mood.name,
    'scenes': {for (final entry in scenes.entries) entry.key: entry.value.name},
    'savedAt': savedAt?.toIso8601String(),
  };

  factory ListeningPreference.fromJson(Map<String, Object?> json) {
    T enumValue<T extends Enum>(List<T> values, Object? name, T fallback) {
      for (final value in values) {
        if (value.name == name) return value;
      }
      return fallback;
    }

    final sceneJson = json['scenes'];
    final scenes = <String, ScenePreferenceLevel>{};
    if (sceneJson is Map) {
      for (final entry in sceneJson.entries) {
        final key = '${entry.key}';
        if (!harmonyListeningScenes.contains(key)) continue;
        scenes[key] = enumValue(
          ScenePreferenceLevel.values,
          entry.value,
          ScenePreferenceLevel.balanced,
        );
      }
    }
    return ListeningPreference(
      familiarity: enumValue(
        FamiliarityPreference.values,
        json['familiarity'],
        FamiliarityPreference.balanced,
      ),
      mood: enumValue(
        MoodPreference.values,
        json['mood'],
        MoodPreference.balanced,
      ),
      scenes: Map.unmodifiable(scenes),
      savedAt: DateTime.tryParse('${json['savedAt'] ?? ''}'),
    );
  }
}
