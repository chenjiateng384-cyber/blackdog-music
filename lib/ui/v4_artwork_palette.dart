import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/v4/artwork.dart';

class V4ArtworkPalette {
  V4ArtworkPalette._();

  static final Map<String, Future<Color>> _cache = {};

  static Future<Color> primary(
    ArtworkReference? artwork, {
    required Brightness brightness,
    required String fallbackSeed,
  }) {
    final key = '${artwork?.artworkId ?? fallbackSeed}:${brightness.name}';
    return _cache.putIfAbsent(
      key,
      () => _extract(artwork, brightness, fallbackSeed),
    );
  }

  static Color fallback(String seed, Brightness brightness) {
    const light = [
      Color(0xFF9A6A6F),
      Color(0xFF747F8E),
      Color(0xFF7C766B),
      Color(0xFF6E8278),
      Color(0xFF7E7288),
    ];
    const dark = [
      Color(0xFF754F55),
      Color(0xFF505D6B),
      Color(0xFF5F584F),
      Color(0xFF50655B),
      Color(0xFF5E5268),
    ];
    final values = brightness == Brightness.dark ? dark : light;
    return values[(seed.hashCode & 0x7fffffff) % values.length];
  }

  static Future<Color> _extract(
    ArtworkReference? artwork,
    Brightness brightness,
    String fallbackSeed,
  ) async {
    final file = _localFile(artwork);
    if (file == null || !await file.exists()) {
      return fallback(fallbackSeed, brightness);
    }
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 32,
        targetHeight: 32,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      frame.image.dispose();
      codec.dispose();
      if (data == null) return fallback(fallbackSeed, brightness);

      var red = 0.0;
      var green = 0.0;
      var blue = 0.0;
      var total = 0.0;
      final bytesView = data.buffer.asUint8List();
      for (var index = 0; index + 3 < bytesView.length; index += 16) {
        if (bytesView[index + 3] < 128) continue;
        final r = bytesView[index];
        final g = bytesView[index + 1];
        final b = bytesView[index + 2];
        final maxChannel = math.max(r, math.max(g, b));
        final minChannel = math.min(r, math.min(g, b));
        final luminance = (r * 0.2126 + g * 0.7152 + b * 0.0722) / 255;
        if (luminance < 0.04 || luminance > 0.96) continue;
        final saturation = (maxChannel - minChannel) / 255;
        final weight = 0.35 + saturation;
        red += r * weight;
        green += g * weight;
        blue += b * weight;
        total += weight;
      }
      if (total == 0) return fallback(fallbackSeed, brightness);
      final raw = Color.fromARGB(
        255,
        (red / total).round(),
        (green / total).round(),
        (blue / total).round(),
      );
      final hsl = HSLColor.fromColor(raw);
      return hsl
          .withSaturation(hsl.saturation.clamp(0.16, 0.48))
          .withLightness(
            brightness == Brightness.dark
                ? hsl.lightness.clamp(0.28, 0.46)
                : hsl.lightness.clamp(0.36, 0.58),
          )
          .toColor();
    } catch (_) {
      return fallback(fallbackSeed, brightness);
    }
  }

  static File? _localFile(ArtworkReference? artwork) {
    final cachePath = artwork?.cachePath;
    if (cachePath != null && cachePath.isNotEmpty) return File(cachePath);
    final uri = Uri.tryParse(artwork?.contentUri ?? '');
    if (uri == null || uri.scheme != 'file') return null;
    return File.fromUri(uri);
  }
}

class V4ArtworkTintBuilder extends StatelessWidget {
  const V4ArtworkTintBuilder({
    required this.artwork,
    required this.fallbackSeed,
    required this.builder,
    super.key,
  });

  final ArtworkReference? artwork;
  final String fallbackSeed;
  final Widget Function(BuildContext context, Color primary) builder;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return FutureBuilder<Color>(
      future: V4ArtworkPalette.primary(
        artwork,
        brightness: brightness,
        fallbackSeed: fallbackSeed,
      ),
      initialData: V4ArtworkPalette.fallback(fallbackSeed, brightness),
      builder: (context, snapshot) => builder(context, snapshot.data!),
    );
  }
}
