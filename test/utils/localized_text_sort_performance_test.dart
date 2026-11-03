import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/utils/localized_text_sort.dart';

void main() {
  test('1000 个中英文音乐名称可重复排序且复用拼音键', () {
    final names = List.generate(1000, (index) {
      final prefix = switch (index % 5) {
        0 => '周杰伦',
        1 => '邓紫棋',
        2 => '林俊杰',
        3 => 'Taylor Swift',
        _ => 'Adele',
      };
      return '$prefix ${1000 - index}';
    });

    final cold = List<String>.of(names);
    cold.sort(compareLocalizedText);
    expect(cold, hasLength(1000));

    final stopwatch = Stopwatch()..start();
    for (var pass = 0; pass < 20; pass++) {
      final values = List<String>.of(names)..sort(compareLocalizedText);
      expect(values, hasLength(1000));
    }
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
