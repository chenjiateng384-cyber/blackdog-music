import 'package:flutter/material.dart';

import 'v4_design_system.dart';

class AppTheme {
  static const primary = V4Colors.accent;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = brightness == Brightness.dark
        ? V4Colors.darkScheme()
        : V4Colors.lightScheme();
    final textTheme = v4TextTheme(scheme);
    final controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(V4Radius.control),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        titleTextStyle: textTheme.titleLarge,
        iconTheme: IconThemeData(color: scheme.onSurface, size: 24),
      ),
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V4Radius.card),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: V4Size.navigationBar,
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V4Radius.control),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 25,
            color: states.contains(WidgetState.selected)
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => textTheme.labelMedium?.copyWith(
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        dividerColor: scheme.outlineVariant.withValues(alpha: 0.55),
        dividerHeight: V4Size.divider,
        indicatorColor: scheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        labelColor: scheme.onSurface,
        unselectedLabelColor: scheme.onSurfaceVariant,
        labelStyle: textTheme.titleSmall,
        unselectedLabelStyle: textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        overlayColor: WidgetStatePropertyAll(
          scheme.primary.withValues(alpha: 0.07),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.55),
        thickness: V4Size.divider,
        space: V4Size.divider,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: V4Space.page,
          vertical: V4Space.xxs,
        ),
        minTileHeight: 64,
        minLeadingWidth: V4Size.listArtwork,
        titleTextStyle: textTheme.titleMedium,
        subtitleTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V4Radius.control),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        hintStyle: textTheme.bodyLarge?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        prefixIconColor: scheme.onSurfaceVariant,
        suffixIconColor: scheme.onSurfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V4Radius.control),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V4Radius.control),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V4Radius.control),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: V4Space.md,
          vertical: V4Space.md,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, V4Size.tapTarget),
          shape: controlShape,
          padding: const EdgeInsets.symmetric(
            horizontal: V4Space.page,
            vertical: V4Space.sm,
          ),
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, V4Size.tapTarget),
          shape: controlShape,
          side: BorderSide(color: scheme.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: V4Space.page),
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(V4Size.tapTarget, V4Size.tapTarget),
          shape: controlShape,
          padding: const EdgeInsets.symmetric(horizontal: V4Space.sm),
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(V4Size.tapTarget, V4Size.tapTarget),
          shape: controlShape,
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V4Radius.control),
        ),
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: textTheme.labelMedium,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V4Radius.card),
        ),
        titleTextStyle: textTheme.titleLarge,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V4Radius.control),
        ),
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(V4Radius.sheet),
          ),
        ),
      ),
    );
  }
}
