import 'package:flutter/material.dart';

import '../v4_design_system.dart';

class V4AppScaffold extends StatelessWidget {
  const V4AppScaffold({
    required this.body,
    this.appBar,
    this.bottomNavigationBar,
    super.key,
  });

  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? bottomNavigationBar;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: appBar,
    body: body,
    bottomNavigationBar: bottomNavigationBar,
  );
}

class V4PageHeader extends StatelessWidget {
  const V4PageHeader({
    required this.title,
    required this.subtitle,
    this.leading,
    this.action,
    this.compact = false,
    super.key,
  });

  final String title;
  final String subtitle;
  final Widget? leading;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      V4Space.page,
      compact ? V4Space.md : V4Space.lg,
      V4Space.page,
      compact ? V4Space.sm : V4Space.md,
    ),
    child: Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: V4Space.xs)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: V4Space.xxs),
              Text(
                subtitle,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        action ?? const SizedBox.shrink(),
      ],
    ),
  );
}

class V4SectionHeader extends StatelessWidget {
  const V4SectionHeader({
    required this.title,
    this.actionLabel,
    this.onAction,
    this.subtitle,
    this.padded = false,
    super.key,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? subtitle;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (subtitle != null)
          Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
        if (actionLabel != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    );
    if (!padded) return content;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        V4Space.page,
        0,
        V4Space.page,
        V4Space.sm,
      ),
      child: content,
    );
  }
}

class V4EmptyState extends StatelessWidget {
  const V4EmptyState({
    required this.title,
    required this.message,
    this.icon = Icons.music_note_rounded,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(V4Space.section),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 48,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: V4Space.md),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: V4Space.xs),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          if (action != null) ...[const SizedBox(height: V4Space.md), action!],
        ],
      ),
    ),
  );
}

class V4InlineEmptyState extends StatelessWidget {
  const V4InlineEmptyState({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(V4Space.md),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(V4Radius.card),
    ),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

class V4LoadingState extends StatelessWidget {
  const V4LoadingState({this.label, super.key});

  final String? label;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        if (label != null) ...[
          const SizedBox(height: V4Space.sm),
          Text(label!, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    ),
  );
}
