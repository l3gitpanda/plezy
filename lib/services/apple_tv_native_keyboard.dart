import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../utils/text_input_diagnostics.dart';
import '../widgets/tv_virtual_keyboard.dart' show TvVirtualKeyboardHandle;
import 'apple_tv_remote_touch_service.dart';
import 'gamepad_service.dart';
import 'tvos_system_navigation_service.dart';

void _log(String message) => TextInputDiagnostics.log('AppleTvNativeKeyboard', message);

/// Presents the native tvOS system keyboard (full-screen, with "Type with
/// iPhone" and Siri Remote dictation) for a single-line text field and
/// mirrors its text into the caller's [TextEditingController].
class AppleTvNativeKeyboard {
  static const _channel = MethodChannel('com.plezy/native_keyboard');
  static int _nextRequestId = 0;
  static _Session? _activeSession;
  static bool _handlerInstalled = false;

  // Once the native keyboard has failed to present (or the channel itself
  // is unreachable), stop trying it for the rest of the app session —
  // `showTvVirtualKeyboard` checks this to fall back to the custom
  // on-screen keyboard instead of silently doing nothing.
  static bool _nativeKeyboardUnavailable = false;

  /// Whether the native tvOS keyboard is known to be unusable this session
  /// (channel missing/threw, or the platform side failed to present it).
  static bool get isKnownUnavailable => _nativeKeyboardUnavailable;

  @visibleForTesting
  static void debugResetNativeKeyboardUnavailable() {
    _nativeKeyboardUnavailable = false;
  }

  static TvVirtualKeyboardHandle show({
    required TextEditingController controller,
    String? hintText,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    List<TextInputFormatter>? inputFormatters,
    bool obscureText = false,
    int? maxLength,
    TextCapitalization textCapitalization = TextCapitalization.none,
    bool autocorrect = true,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
    VoidCallback? onAction,
  }) {
    _ensureHandler();

    final requestId = _nextRequestId++;
    final session = _Session(
      requestId: requestId,
      controller: controller,
      inputFormatters: inputFormatters,
      maxLength: maxLength,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      onAction: onAction,
    );

    // Rapid reopen: resolve the superseded session's `closed` future
    // deterministically instead of leaving it dangling.
    _activeSession?._finish();
    _activeSession = session;

    _log('show requestId=$requestId type=$keyboardType obscure=$obscureText maxLength=$maxLength');
    unawaited(GamepadService.setNativeTextInputFocused(true));
    AppleTvRemoteTouchService.instance.nativeTextInputActive = true;
    // Menu must reach the system while the keyboard is up, or it can't be
    // dismissed — see TvosSystemNavigationService.setKeyboardSessionActive.
    unawaited(TvosSystemNavigationService.setKeyboardSessionActive(true));

    unawaited(
      _channel
          .invokeMethod<void>('show', {
            'requestId': requestId,
            'text': controller.text,
            'hintText': hintText,
            'keyboardType': _keyboardTypeName(keyboardType),
            'textInputAction': _textInputActionName(textInputAction),
            'obscureText': obscureText,
            'maxLength': maxLength,
            'textCapitalization': _textCapitalizationName(textCapitalization),
            'autocorrect': autocorrect,
          })
          .catchError((Object error) {
            _log('show failed requestId=$requestId error=$error');
            _nativeKeyboardUnavailable = true;
            session._finish();
          }),
    );

    return TvVirtualKeyboardHandle.fromCallbacks(
      close: () => _dismiss(session),
      closed: session._closedCompleter.future,
    );
  }

  static void _dismiss(_Session session) {
    if (session.closed) return;
    _log('dismiss requestId=${session.requestId}');
    unawaited(
      _channel.invokeMethod<void>('dismiss', {'requestId': session.requestId}).catchError((Object error) {
        _log('dismiss failed requestId=${session.requestId} error=$error');
      }),
    );
    session._finish();
  }

  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    final arguments = call.arguments as Map?;
    final requestId = arguments?['requestId'] as int?;
    final session = _activeSession;
    if (session == null || session.requestId != requestId || session.closed) {
      _log('ignoring stale ${call.method} requestId=$requestId activeRequestId=${session?.requestId}');
      return;
    }

    switch (call.method) {
      case 'textChanged':
        session._applyNativeText(arguments?['text'] as String? ?? '');
      case 'submitted':
        session._applyNativeText(arguments?['text'] as String? ?? '');
        session._submit();
      case 'closed':
        session._finish();
      case 'presentFailed':
        // The platform side could not make the hidden field first responder
        // (e.g. tvOS focus engine contention) — stop trying the native
        // keyboard and let this session close so its caller falls back to
        // the custom on-screen keyboard.
        _log('presentFailed requestId=$requestId — native keyboard unavailable');
        _nativeKeyboardUnavailable = true;
        session._finish();
    }
  }

  static String _keyboardTypeName(TextInputType? keyboardType) {
    final index = keyboardType?.index;
    if (index == TextInputType.number.index) return 'number';
    if (index == TextInputType.phone.index) return 'phone';
    if (index == TextInputType.emailAddress.index) return 'email';
    if (index == TextInputType.url.index) return 'url';
    return 'text';
  }

  static String? _textInputActionName(TextInputAction? textInputAction) {
    return switch (textInputAction) {
      TextInputAction.search => 'search',
      TextInputAction.next => 'next',
      TextInputAction.go => 'go',
      TextInputAction.send => 'send',
      TextInputAction.done => 'done',
      _ => null,
    };
  }

  static String _textCapitalizationName(TextCapitalization textCapitalization) => textCapitalization.name;
}

class _Session {
  _Session({
    required this.requestId,
    required this.controller,
    required this.inputFormatters,
    required this.maxLength,
    required this.onChanged,
    required this.onSubmitted,
    required this.onAction,
  });

  final int requestId;
  final TextEditingController controller;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onAction;

  final _closedCompleter = Completer<void>();
  bool closed = false;

  void _applyNativeText(String nativeText) {
    final previous = controller.value;
    var next = previous.copyWith(
      text: nativeText,
      selection: TextSelection.collapsed(offset: nativeText.length),
      composing: TextRange.empty,
    );

    final formatters = [
      ...?inputFormatters,
      if (maxLength != null && maxLength! > 0) LengthLimitingTextInputFormatter(maxLength),
    ];
    for (final formatter in formatters) {
      next = formatter.formatEditUpdate(previous, next);
    }

    controller.value = next;
    if (next.text != previous.text) {
      onChanged?.call(next.text);
    }

    if (next.text != nativeText) {
      // A formatter rejected some characters (e.g. join-by-code's
      // FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]'))) — echo the
      // corrected text back so the native field stays in sync.
      unawaited(
        AppleTvNativeKeyboard._channel.invokeMethod<void>('update', {'requestId': requestId, 'text': next.text}),
      );
    }
  }

  void _submit() {
    final onSubmitted = this.onSubmitted;
    if (onSubmitted != null) {
      onSubmitted(controller.text);
    } else {
      onAction?.call();
    }
    _finish();
  }

  void _finish() {
    if (closed) return;
    closed = true;
    unawaited(GamepadService.setNativeTextInputFocused(false));
    AppleTvRemoteTouchService.instance.nativeTextInputActive = false;
    unawaited(TvosSystemNavigationService.setKeyboardSessionActive(false));
    if (!_closedCompleter.isCompleted) _closedCompleter.complete();
  }
}
