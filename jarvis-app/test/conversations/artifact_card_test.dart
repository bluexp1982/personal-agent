import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/design/app_palette.dart';
import 'package:jarvis_app/src/features/conversations/artifact_card.dart';

Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: Center(child: child)));
}

void main() {
  testWidgets('外壳把标题、等宽主行、详情行与附加行按顺序排出来', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const SizedBox(
          width: 360,
          child: ArtifactCard(
            icon: Icons.insert_drive_file_outlined,
            title: '生成文件',
            primaryLine: 'prototypes/calc.html',
            detailLine: '项目内 · 14.2 KB',
            extraLines: <String>['原文件已备份：/data/backups/index.html'],
          ),
        ),
      ),
    );

    expect(find.text('生成文件'), findsOneWidget);
    expect(find.text('prototypes/calc.html'), findsOneWidget);
    expect(find.text('项目内 · 14.2 KB'), findsOneWidget);
    expect(find.textContaining('原文件已备份'), findsOneWidget);

    // 主行是等宽字体：路径要能一眼看出层级，与正文区分开。
    final mono = tester.widget<Text>(find.text('prototypes/calc.html'));
    expect(mono.style?.fontFamily, isNotNull);

    expect(
      tester.getTopLeft(find.text('prototypes/calc.html')).dy,
      lessThan(tester.getTopLeft(find.text('项目内 · 14.2 KB')).dy),
    );
  });

  testWidgets('缩略图在信息行上方，动作区在最后', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 360,
          child: ArtifactCard(
            icon: Icons.image_outlined,
            title: '生成的图片',
            primaryLine: '季度复盘_generate_image_20261105-153012.png',
            detailLine: '1328×1328 · 2.4 MB',
            thumbnail: Container(
              key: const Key('thumb'),
              height: 120,
              color: const Color(0xFF3366CC),
            ),
            actions: <Widget>[
              ArtifactActionButton(
                key: const Key('save'),
                icon: Icons.save_alt,
                label: '保存',
                onPressed: () {},
              ),
              ArtifactActionButton(
                key: const Key('open'),
                icon: kArtifactOpenIcon,
                label: '打开',
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getTopLeft(find.byKey(const Key('thumb'))).dy,
      lessThan(tester.getTopLeft(find.text('生成的图片')).dy),
      reason: '缩略图在信息行上面',
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('open'))).dy,
      greaterThan(tester.getTopLeft(find.textContaining('1328×1328')).dy),
      reason: '动作区在信息之后',
    );

    // 「保存」与「打开」是同一档按钮：都是文字按钮，没有谁被填成实心。
    // 以前「打开」是 tonal 填充，同一行看起来像两个层级。
    for (final key in <Key>[const Key('save'), const Key('open')]) {
      expect(
        find.descendant(of: find.byKey(key), matching: find.byType(TextButton)),
        findsOneWidget,
        reason: '$key 应该是文字按钮',
      );
      expect(
        find.descendant(of: find.byKey(key), matching: find.byType(FilledButton)),
        findsNothing,
      );
    }
    // 两枚按钮必须等高：一条 18dp 图标 + 同一套 TextButton 内边距。
    expect(
      tester.getSize(find.byKey(const Key('save'))).height,
      tester.getSize(find.byKey(const Key('open'))).height,
    );
  });

  testWidgets('缩略图在卡片里水平居中', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 360,
          child: ArtifactCard(
            icon: Icons.image_outlined,
            title: '生成的图片',
            primaryLine: 'a.png',
            thumbnail: Container(
              key: const Key('thumb'),
              width: 120,
              height: 120,
              color: const Color(0xFF3366CC),
            ),
          ),
        ),
      ),
    );

    final card = tester.getRect(find.byType(ArtifactCard));
    final thumb = tester.getRect(find.byKey(const Key('thumb')));
    final leftGap = thumb.left - card.left;
    final rightGap = card.right - thumb.right;

    // 卡片内边距左 12 右 10（各加 1px 描边），居中后左右差恒为 2。
    expect(
      leftGap - rightGap,
      closeTo(2, 1),
      reason: '缩略图应水平居中，而不是贴着左边',
    );
  });

  testWidgets('状态胶囊用状态色派生，不自写 alpha', (tester) async {
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) {
            final palette = AppPalette.of(context);
            return ArtifactCard(
              icon: Icons.insert_drive_file_outlined,
              title: '生成文件',
              chip: ArtifactStatusChip(
                label: '已写入',
                color: palette.status.success,
              ),
            );
          },
        ),
      ),
    );

    expect(find.text('已写入'), findsOneWidget);
    final chip = tester.widget<Container>(
      find.ancestor(
        of: find.text('已写入'),
        matching: find.byType(Container),
      ).first,
    );
    expect(chip.decoration, isA<BoxDecoration>());
  });

  testWidgets('没有动作时不渲染动作区', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const ArtifactCard(
          icon: Icons.insert_drive_file_outlined,
          title: '生成文件',
          primaryLine: 'a.html',
        ),
      ),
    );

    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
  });
}
