import 'package:pinyin/pinyin.dart';

const _maximumSortKeyCacheEntries = 4096;
final Map<String, String> _sortKeyCache = <String, String>{};

/// Builds a stable user-facing sort order for mixed Chinese, English and
/// numeric music names. Chinese text is compared by tone-free pinyin while
/// the original text remains untouched for display and search.
int compareLocalizedText(String left, String right) {
  final leftKey = localizedTextSortKey(left);
  final rightKey = localizedTextSortKey(right);
  final byKey = _naturalCompare(leftKey, rightKey);
  if (byKey != 0) return byKey;
  return left.toLowerCase().compareTo(right.toLowerCase());
}

String localizedTextSortKey(String value) {
  final normalized = value.trim().toLowerCase();
  final cached = _sortKeyCache[normalized];
  if (cached != null) return cached;
  if (normalized.isEmpty) return '3|';
  final converted = PinyinHelper.getPinyinE(
    normalized,
    separator: '',
    defPinyin: '#',
    format: PinyinFormat.WITHOUT_TONE,
  ).toLowerCase();
  final compact = converted.replaceAll(RegExp(r'\s+'), '');
  final first = compact.isEmpty ? 0 : compact.codeUnitAt(0);
  final group = first >= 0x30 && first <= 0x39
      ? '0'
      : first >= 0x61 && first <= 0x7A
      ? '1'
      : '2';
  final key = '$group|$compact';
  // Song, artist and album names repeat across many views. Converting them to
  // pinyin inside every comparator made each rebuild unnecessarily expensive.
  if (_sortKeyCache.length >= _maximumSortKeyCacheEntries) {
    _sortKeyCache.clear();
  }
  _sortKeyCache[normalized] = key;
  return key;
}

int _naturalCompare(String left, String right) {
  final token = RegExp(r'\d+|\D+');
  final leftParts = token
      .allMatches(left)
      .map((match) => match.group(0)!)
      .toList();
  final rightParts = token
      .allMatches(right)
      .map((match) => match.group(0)!)
      .toList();
  final count = leftParts.length < rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (var index = 0; index < count; index++) {
    final leftPart = leftParts[index];
    final rightPart = rightParts[index];
    final leftNumber = int.tryParse(leftPart);
    final rightNumber = int.tryParse(rightPart);
    final comparison = leftNumber != null && rightNumber != null
        ? leftNumber.compareTo(rightNumber)
        : leftPart.compareTo(rightPart);
    if (comparison != 0) return comparison;
  }
  return leftParts.length.compareTo(rightParts.length);
}
