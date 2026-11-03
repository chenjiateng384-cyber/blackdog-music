import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/v4/artwork.dart';
import 'v4_artwork_palette.dart';
import 'v4_design_system.dart';

class V4Artwork extends StatelessWidget {
  const V4Artwork({
    required this.artwork,
    this.size,
    this.borderRadius = V4Radius.artwork,
    this.semanticLabel = '专辑封面',
    this.playing = false,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.fallbackSeed,
    super.key,
  });

  final ArtworkReference? artwork;
  final double? size;
  final double borderRadius;
  final String semanticLabel;
  final bool playing;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final String? fallbackSeed;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final extent = size ?? _boundedExtent(constraints);
        final pixelRatio = MediaQuery.devicePixelRatioOf(context);
        // Keep the decoded image close to the physical display size. The old
        // 1024px cap visibly softened the large player artwork on high-density
        // Android screens such as OnePlus 13.
        final cacheExtent = (extent * pixelRatio).ceil().clamp(64, 1536);
        return SizedBox(
          width: size ?? double.infinity,
          height: size ?? double.infinity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: _ArtworkBody(
              artwork: artwork,
              cacheExtent: cacheExtent,
              semanticLabel: semanticLabel,
              playing: playing,
              fit: fit,
              alignment: alignment,
              fallbackSeed: fallbackSeed ?? semanticLabel,
            ),
          ),
        );
      },
    );
  }

  static double _boundedExtent(BoxConstraints constraints) {
    final extent = math.min(constraints.maxWidth, constraints.maxHeight);
    return extent.isFinite && extent > 0 ? extent : 256;
  }
}

class _ArtworkBody extends StatelessWidget {
  const _ArtworkBody({
    required this.artwork,
    required this.cacheExtent,
    required this.semanticLabel,
    required this.playing,
    required this.fit,
    required this.alignment,
    required this.fallbackSeed,
  });

  final ArtworkReference? artwork;
  final int cacheExtent;
  final String semanticLabel;
  final bool playing;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final String fallbackSeed;

  @override
  Widget build(BuildContext context) {
    final file = _localFile(artwork);
    if (file == null) return _placeholder(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(
          key: ValueKey(artwork?.sha256 ?? artwork?.cachePath),
          file,
          fit: fit,
          alignment: alignment,
          cacheWidth: cacheExtent,
          cacheHeight: cacheExtent,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          semanticLabel: semanticLabel,
          errorBuilder: (context, _, _) => _placeholder(context),
        ),
        if (playing)
          const ColoredBox(
            color: Color(0x52000000),
            child: Icon(Icons.graphic_eq_rounded, color: Colors.white),
          ),
      ],
    );
  }

  Widget _placeholder(BuildContext context) =>
      NeutralArtworkPlaceholder(seed: fallbackSeed);

  static File? _localFile(ArtworkReference? artwork) {
    final path = artwork?.cachePath;
    if (path != null && path.isNotEmpty) return File(path);
    final uriValue = artwork?.contentUri;
    if (uriValue == null || uriValue.isEmpty) return null;
    final uri = Uri.tryParse(uriValue);
    if (uri == null || uri.scheme != 'file') return null;
    return File.fromUri(uri);
  }
}

class NeutralArtworkPlaceholder extends StatelessWidget {
  const NeutralArtworkPlaceholder({this.seed = 'Harmony', super.key});

  final String seed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = V4ArtworkPalette.fallback(
      seed,
      Theme.of(context).brightness,
    );
    return DecoratedBox(
      key: const Key('v4-artwork-placeholder'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(colors.surfaceContainerHigh, accent, 0.28)!,
            Color.lerp(colors.surfaceContainerLow, accent, 0.10)!,
          ],
        ),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.32),
        ),
      ),
      child: Center(
        child: FractionallySizedBox(
          widthFactor: 0.38,
          heightFactor: 0.38,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.surfaceContainerLow.withValues(alpha: 0.82),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: 0.72),
              ),
            ),
            child: Icon(
              Icons.music_note_rounded,
              color: colors.onSurfaceVariant.withValues(alpha: 0.58),
            ),
          ),
        ),
      ),
    );
  }
}
