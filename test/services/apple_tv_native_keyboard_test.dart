import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/tv_virtual_keyboard.dart';

const _channel = MethodChannel('com.plezy/native_keyboard');

void main() {
  late List<MethodCall> calls;

  void setHandler(Future<dynamic> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, handler);
  }

  setUp(() {
    calls = <MethodCall>[];
    setHandler((call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TvDetectionService.debugSetAppleTVOverride(null);
    setHandler(null);
  });

  group('AppleTvNativeKeyboard', () {
    testWidgets('single-line Apple TV field opens the native keyboard without a Dialog', (tester) async {
      final context = await _pumpAppleTvContext(tester);
      final controller = TextEditingController(text: 'query');
      addTearDown(controller.dispose);

      final handle = showTvVirtualKeyboard(context: context, controller: controller, hintText: 'Search');
      addTearDown(() => handle?.close());
      await tester.pump();

      expect(find.byType(Dialog), findsNothing);

      final showCalls = calls.where((call) => call.method == 'show').toList();
      expect(showCalls, hasLength(1));
      final arguments = showCalls.single.arguments as Map;
      expect(arguments['text'], 'query');
      expect(arguments['hintText'], 'Search');
      expect(arguments['keyboardType'], 'text');
      expect(arguments['obscureText'], isFalse);
      expect(arguments['requestId'], isA<int>());
    });

    testWidgets('simulated textChanged updates the controller and fires onChanged', (tester) async {
      final context = await _pumpAppleTvContext(tester);
      final controller = TextEditingController();
      final changes = <String>[];
      addTearDown(controller.dispose);

      final handle = showTvVirtualKeyboard(context: context, controller: controller, onChanged: changes.add);
      addTearDown(() => handle?.close());
      await tester.pump();

      final requestId = _requestIdOf(calls);
      await _sendNativeCall('textChanged', {'requestId': requestId, 'text': 'abc'});

      expect(controller.text, 'abc');
      expect(changes, ['abc']);
    });

    testWidgets('simulated submitted fires onSubmitted and completes handle.closed', (tester) async {
      final context = await _pumpAppleTvContext(tester);
      final controller = TextEditingController();
      String? submitted;
      addTearDown(controller.dispose);

      final handle = showTvVirtualKeyboard(
        context: context,
        controller: controller,
        onSubmitted: (value) => submitted = value,
      );
      await tester.pump();

      final requestId = _requestIdOf(calls);
      await _sendNativeCall('submitted', {'requestId': requestId, 'text': 'done text'});

      expect(submitted, 'done text');
      await expectLater(handle!.closed, completes);
    });

    testWidgets('handle.close() sends dismiss and completes closed', (tester) async {
      final context = await _pumpAppleTvContext(tester);
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      final handle = showTvVirtualKeyboard(context: context, controller: controller);
      await tester.pump();

      final requestId = _requestIdOf(calls);
      handle!.close();

      final dismissCalls = calls.where((call) => call.method == 'dismiss').toList();
      expect(dismissCalls, hasLength(1));
      expect((dismissCalls.single.arguments as Map)['requestId'], requestId);
      await expectLater(handle.closed, completes);
    });

    testWidgets('formatter echo-back updates the controller and pushes the corrected text', (tester) async {
      final context = await _pumpAppleTvContext(tester);
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      final handle = showTvVirtualKeyboard(
        context: context,
        controller: controller,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9]'))],
      );
      addTearDown(() => handle?.close());
      await tester.pump();

      final requestId = _requestIdOf(calls);
      await _sendNativeCall('textChanged', {'requestId': requestId, 'text': 'a1'});

      expect(controller.text, '1');
      final updateCalls = calls.where((call) => call.method == 'update').toList();
      expect(updateCalls, hasLength(1));
      expect((updateCalls.single.arguments as Map)['text'], '1');
    });
  });
}

/// Pumps a minimal widget tree simulating Apple TV and returns a
/// [BuildContext] to drive [showTvVirtualKeyboard] directly, mirroring
/// `_pumpKeyboard` in tv_virtual_keyboard_test.dart.
Future<BuildContext> _pumpAppleTvContext(WidgetTester tester) async {
  TvDetectionService.debugSetAppleTVOverride(true);
  late BuildContext context;

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (builderContext) {
          context = builderContext;
          return const SizedBox.shrink();
        },
      ),
    ),
  );

  return context;
}

/// Reads the requestId off the captured `show` call rather than assuming a
/// fresh counter — [AppleTvNativeKeyboard] keeps static session state that
/// persists across tests in this isolate.
int _requestIdOf(List<MethodCall> calls) {
  final showCall = calls.firstWhere((call) => call.method == 'show');
  return (showCall.arguments as Map)['requestId'] as int;
}

/// Simulates a native->Dart call on the native keyboard channel.
Future<void> _sendNativeCall(String method, Map<String, dynamic> arguments) {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final data = const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments));
  return messenger.handlePlatformMessage(_channel.name, data, (_) {});
}
