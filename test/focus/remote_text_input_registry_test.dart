import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/remote_text_input_registry.dart';

class _FakeTarget implements RemoteTextInputTarget {
  String text = '';
  int selection = 0;
  final List<String> submitted = [];

  @override
  RemoteTextFieldSnapshot describeForRemote(String fieldId) {
    return RemoteTextFieldSnapshot(fieldId: fieldId, text: text, selection: selection, hint: 'fake');
  }

  @override
  void applyRemoteText(String newText, int newSelection) {
    text = newText;
    selection = newSelection;
  }

  @override
  void submitFromRemote(String newText, int newSelection) {
    applyRemoteText(newText, newSelection);
    submitted.add(newText);
  }
}

void main() {
  late RemoteTextInputRegistry registry;

  setUp(() {
    registry = RemoteTextInputRegistry.instance;
    registry.reset();
  });

  tearDown(() => registry.reset());

  group('RemoteTextInputRegistry', () {
    test('notifyFocused publishes a snapshot and is idempotent per target', () {
      final target = _FakeTarget()..text = 'abc';
      final snapshots = <RemoteTextFieldSnapshot?>[];
      registry.onActiveFieldChanged = snapshots.add;

      registry.notifyFocused(target);
      expect(snapshots, hasLength(1));
      expect(snapshots.single?.text, 'abc');
      final firstFieldId = snapshots.single?.fieldId;

      registry.notifyFocused(target);
      expect(snapshots, hasLength(1), reason: 're-focusing the same target must not mint a new field session');
      expect(registry.currentSnapshot?.fieldId, firstFieldId);
    });

    test('notifyBlurred publishes null and clears the snapshot', () {
      final target = _FakeTarget();
      final snapshots = <RemoteTextFieldSnapshot?>[];
      registry.onActiveFieldChanged = snapshots.add;

      registry.notifyFocused(target);
      registry.notifyBlurred(target);

      expect(snapshots, [isNotNull, isNull]);
      expect(registry.currentSnapshot, isNull);
    });

    test('late blur from a previous target is a no-op after focus moved', () {
      final a = _FakeTarget();
      final b = _FakeTarget()..text = 'b';
      final snapshots = <RemoteTextFieldSnapshot?>[];
      registry.onActiveFieldChanged = snapshots.add;

      registry.notifyFocused(a);
      registry.notifyFocused(b);
      registry.notifyBlurred(a);

      expect(registry.currentSnapshot?.text, 'b');
      expect(snapshots.last?.text, 'b');
    });

    test('each focus session mints a fresh fieldId', () {
      final a = _FakeTarget();
      final b = _FakeTarget();

      registry.notifyFocused(a);
      final firstId = registry.currentSnapshot?.fieldId;
      registry.notifyFocused(b);
      final secondId = registry.currentSnapshot?.fieldId;

      expect(firstId, isNotNull);
      expect(secondId, isNotNull);
      expect(secondId, isNot(firstId));
    });

    test('handleTextInput set applies text and clamps the caret', () {
      final target = _FakeTarget();
      registry.notifyFocused(target);

      expect(registry.handleTextInput(op: 'set', text: 'hello', sel: 99), isTrue);
      expect(target.text, 'hello');
      expect(target.selection, 5);

      expect(registry.handleTextInput(op: 'set', text: 'hi'), isTrue);
      expect(target.selection, 2, reason: 'missing sel defaults to end of text');
    });

    test('handleTextInput submit routes to submitFromRemote', () {
      final target = _FakeTarget();
      registry.notifyFocused(target);

      expect(registry.handleTextInput(op: 'submit', text: 'query'), isTrue);
      expect(target.submitted, ['query']);
      expect(target.text, 'query');
    });

    test('handleTextInput drops edits with no active target', () {
      expect(registry.handleTextInput(op: 'set', text: 'orphan'), isFalse);
    });

    test('handleTextInput drops edits with a stale fieldId', () {
      final a = _FakeTarget();
      final b = _FakeTarget();

      registry.notifyFocused(a);
      final staleId = registry.currentSnapshot!.fieldId;
      registry.notifyFocused(b);

      expect(registry.handleTextInput(op: 'set', text: 'stale', fieldId: staleId), isFalse);
      expect(b.text, isEmpty);

      final currentId = registry.currentSnapshot!.fieldId;
      expect(registry.handleTextInput(op: 'set', text: 'fresh', fieldId: currentId), isTrue);
      expect(b.text, 'fresh');
    });

    test('handleTextInput rejects unknown ops', () {
      final target = _FakeTarget();
      registry.notifyFocused(target);

      expect(registry.handleTextInput(op: 'explode', text: 'x'), isFalse);
      expect(target.text, isEmpty);
    });

    test('snapshot wire data round trips through toWireData', () {
      const snapshot = RemoteTextFieldSnapshot(
        fieldId: 'f1',
        text: 'abc',
        selection: 3,
        hint: 'Search',
        obscureText: true,
        multiline: false,
        maxLength: 32,
        inputType: 'text',
        action: 'search',
      );

      expect(snapshot.toWireData(), {
        'focused': true,
        'fid': 'f1',
        'text': 'abc',
        'sel': 3,
        'hint': 'Search',
        'obscure': true,
        'multiline': false,
        'maxLength': 32,
        'inputType': 'text',
        'action': 'search',
      });
    });
  });
}
