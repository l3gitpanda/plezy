import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/focusable_text_field.dart';
import 'package:plezy/focus/remote_text_input_registry.dart';

void main() {
  testWidgets('unwired single-line fields traverse with arrow keys', (tester) async {
    final first = FocusNode(debugLabel: 'first');
    final second = FocusNode(debugLabel: 'second');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    addTearDown(c1.dispose);
    addTearDown(c2.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              FocusableTextField(controller: c1, focusNode: first, enableTvKeyboard: false),
              FocusableTextField(controller: c2, focusNode: second, enableTvKeyboard: false),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    first.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'first');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'second');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'first');
  });

  testWidgets('unwired multiline field keeps arrow keys for the caret', (tester) async {
    final first = FocusNode(debugLabel: 'multiline');
    final second = FocusNode(debugLabel: 'below');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final c1 = TextEditingController(text: 'line1\nline2');
    final c2 = TextEditingController();
    addTearDown(c1.dispose);
    addTearDown(c2.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              FocusableTextField(controller: c1, focusNode: first, maxLines: 4, enableTvKeyboard: false),
              FocusableTextField(controller: c2, focusNode: second, enableTvKeyboard: false),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    first.requestFocus();
    c1.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'multiline');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'multiline');
  });

  group('remote text input registry integration', () {
    late RemoteTextInputRegistry registry;

    setUp(() {
      registry = RemoteTextInputRegistry.instance;
      registry.reset();
    });

    tearDown(() => registry.reset());

    testWidgets('focused field registers, applies remote edits through formatters, and submits', (tester) async {
      final node = FocusNode(debugLabel: 'field');
      addTearDown(node.dispose);
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final changes = <String>[];
      final submissions = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusableTextField(
              controller: controller,
              focusNode: node,
              enableTvKeyboard: false,
              decoration: const InputDecoration(hintText: 'Search'),
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (oldValue, newValue) => newValue.copyWith(text: newValue.text.toUpperCase()),
                ),
              ],
              maxLength: 6,
              onChanged: changes.add,
              onSubmitted: submissions.add,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(registry.currentSnapshot, isNull);

      node.requestFocus();
      await tester.pump();

      final snapshot = registry.currentSnapshot;
      expect(snapshot, isNotNull);
      expect(snapshot!.hint, 'Search');
      expect(snapshot.text, isEmpty);

      expect(registry.handleTextInput(op: 'set', text: 'hello'), isTrue);
      expect(controller.text, 'HELLO', reason: 'input formatters must apply to remote edits');
      expect(changes, ['HELLO']);

      expect(registry.handleTextInput(op: 'set', text: 'hello world'), isTrue);
      expect(controller.text, 'HELLO ', reason: 'maxLength must apply to remote edits');

      expect(registry.handleTextInput(op: 'submit', text: 'hello '), isTrue);
      expect(submissions, ['HELLO ']);

      node.unfocus();
      await tester.pump();
      expect(registry.currentSnapshot, isNull);
      expect(registry.handleTextInput(op: 'set', text: 'late'), isFalse);
    });

    testWidgets('focus moving between fields keeps the registry on the newest field', (tester) async {
      final first = FocusNode(debugLabel: 'first');
      final second = FocusNode(debugLabel: 'second');
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final c1 = TextEditingController(text: 'one');
      final c2 = TextEditingController(text: 'two');
      addTearDown(c1.dispose);
      addTearDown(c2.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                FocusableTextField(controller: c1, focusNode: first, enableTvKeyboard: false),
                FocusableTextField(controller: c2, focusNode: second, enableTvKeyboard: false),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      first.requestFocus();
      await tester.pump();
      expect(registry.currentSnapshot?.text, 'one');
      final firstFieldId = registry.currentSnapshot?.fieldId;

      second.requestFocus();
      await tester.pump();
      expect(registry.currentSnapshot?.text, 'two');
      expect(registry.currentSnapshot?.fieldId, isNot(firstFieldId));

      expect(registry.handleTextInput(op: 'set', text: 'stale', fieldId: firstFieldId), isFalse);
      expect(c2.text, 'two');
    });

    testWidgets('disposing a focused field clears the registry', (tester) async {
      final node = FocusNode(debugLabel: 'field');
      addTearDown(node.dispose);
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusableTextField(controller: controller, focusNode: node, enableTvKeyboard: false),
          ),
        ),
      );
      await tester.pump();

      node.requestFocus();
      await tester.pump();
      expect(registry.currentSnapshot, isNotNull);

      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      await tester.pump();

      expect(registry.currentSnapshot, isNull);
    });
  });
}
