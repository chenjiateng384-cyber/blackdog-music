import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_library/ui/app_theme.dart';
import 'package:my_music_library/ui/components/v4_foundation.dart';
import 'package:my_music_library/ui/v4_design_system.dart';

void main() {
  testWidgets('基础组件共用主题且保持现有页面层级', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const V4AppScaffold(
          body: Column(
            children: [
              V4PageHeader(title: '音乐库', subtitle: '浏览本地音乐'),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: V4Space.page),
                child: V4SectionHeader(title: '最近播放'),
              ),
              Expanded(
                child: V4EmptyState(title: '还没有歌曲', message: '扫描音乐目录后会显示在这里'),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('音乐库'), findsOneWidget);
    expect(find.text('最近播放'), findsOneWidget);
    expect(find.text('还没有歌曲'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
  });

  test('一加 13 宽度保持 20 间距，宽屏才增加留白', () {
    expect(V4Layout.horizontalPaddingFor(412), V4Space.page);
    expect(V4Layout.horizontalPaddingFor(599), V4Space.page);
    expect(V4Layout.horizontalPaddingFor(600), V4Space.lg);
    expect(V4Layout.maxContentWidth, 720);
  });
}
