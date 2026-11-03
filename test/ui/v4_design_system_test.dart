import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/ui/app_theme.dart';
import 'package:my_music_library/ui/v4_design_system.dart';

void main() {
  test('V4 light 与 dark 主题共用克制的中性色和单一主题色', () {
    final light = AppTheme.light();
    final dark = AppTheme.dark();

    expect(light.scaffoldBackgroundColor, const Color(0xFFFAF9F7));
    expect(dark.scaffoldBackgroundColor, const Color(0xFF0D0D0F));
    expect(light.colorScheme.primary, V4Colors.accent);
    expect(dark.colorScheme.primary, V4Colors.accentDark);
    expect(light.navigationBarTheme.height, V4Size.navigationBar);
    expect(dark.navigationBarTheme.height, V4Size.navigationBar);
  });

  test('V4 字体层级保持标题、正文和辅助信息的稳定顺序', () {
    final text = AppTheme.light().textTheme;

    expect(
      text.displaySmall!.fontSize,
      greaterThan(text.headlineMedium!.fontSize!),
    );
    expect(
      text.headlineMedium!.fontSize,
      greaterThan(text.titleLarge!.fontSize!),
    );
    expect(text.titleLarge!.fontSize, greaterThan(text.bodyLarge!.fontSize!));
    expect(text.bodyLarge!.fontSize, greaterThan(text.bodySmall!.fontSize!));
    expect(text.displaySmall!.fontWeight, FontWeight.w800);
    expect(text.bodyMedium!.height, greaterThan(1.3));
  });

  test('V4 控件统一使用固定点击高度和圆角体系', () {
    final theme = AppTheme.light();
    final buttonStyle = theme.filledButtonTheme.style!;
    final minimumSize = buttonStyle.minimumSize!.resolve(<WidgetState>{});
    final shape = buttonStyle.shape!.resolve(<WidgetState>{});

    expect(minimumSize!.height, V4Size.tapTarget);
    expect(shape, isA<RoundedRectangleBorder>());
    expect(
      (shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(V4Radius.control),
    );
    expect(V4Radius.artwork, greaterThan(V4Radius.control));
    expect(V4Radius.card, greaterThan(V4Radius.artwork));
  });
}
