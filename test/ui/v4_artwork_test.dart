import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/models/v4/artwork.dart';
import 'package:my_music_library/ui/v4_artwork.dart';

void main() {
  testWidgets('缓存图片存在时显示真实封面', (tester) async {
    final temp = Directory.systemTemp.createTempSync('artwork-widget-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final image = File('${temp.path}/cover.png');
    image.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL5WQAAAABJRU5ErkJggg==',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: V4Artwork(
            artwork: ArtworkReference(
              artworkId: '11111111-2222-4333-8444-555555555555',
              source: 'embedded',
              confidence: 1,
              createdAt: DateTime(2026, 8, 20),
              cachePath: image.path,
            ),
            size: 120,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final rendered = tester.widget<Image>(find.byType(Image));
    final resized = rendered.image as ResizeImage;
    expect(resized.width, (120 * tester.view.devicePixelRatio).ceil());
    expect(rendered.filterQuality, FilterQuality.medium);
    expect(find.byKey(const Key('v4-artwork-placeholder')), findsNothing);
  });

  testWidgets('封面缺失或缓存损坏时显示中性黑胶占位图', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: V4Artwork(
            artwork: ArtworkReference(
              artworkId: '11111111-2222-4333-8444-555555555555',
              source: 'embedded',
              confidence: 1,
              createdAt: DateTime(2026, 8, 20),
              cachePath: '${Directory.systemTemp.path}/missing-cover.jpg',
            ),
            size: 120,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const Key('v4-artwork-placeholder')), findsOneWidget);
    expect(find.textContaining(RegExp('[A-Za-z\u3400-\u9FFF]')), findsNothing);
  });
}
