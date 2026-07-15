import 'dart:math';

import 'package:flutter/foundation.dart';

/// Immutable description of the host's focused text field, sent to a
/// companion remote so it can seed its local editor.
@immutable
class RemoteTextFieldSnapshot {
  final String fieldId;
  final String text;
  final int selection;
  final String? hint;
  final bool obscureText;
  final bool multiline;
  final int? maxLength;
  final String? inputType;
  final String? action;

  const RemoteTextFieldSnapshot({
    required this.fieldId,
    required this.text,
    required this.selection,
    this.hint,
    this.obscureText = false,
    this.multiline = false,
    this.maxLength,
    this.inputType,
    this.action,
  });

  Map<String, dynamic> toWireData() {
    return {
      'focused': true,
      'fid': fieldId,
      'text': text,
      'sel': selection,
      if (hint != null) 'hint': hint,
      'obscure': obscureText,
      'multiline': multiline,
      if (maxLength != null) 'maxLength': maxLength,
      if (inputType != null) 'inputType': inputType,
      if (action != null) 'action': action,
    };
  }
}

/// Implemented by the focused text field so remote edits can be applied
/// through the same formatter/onChanged/onSubmitted pipeline as local input.
abstract class RemoteTextInputTarget {
  RemoteTextFieldSnapshot describeForRemote(String fieldId);
  void applyRemoteText(String text, int selection);
  void submitFromRemote(String text, int selection);
}

/// Tracks which text field currently has focus on this device so a connected
/// companion remote can type into it.
///
/// Fields register unconditionally on focus (a pointer assignment — cheap on
/// every platform); whether anything is published over the wire is decided by
/// whoever installs [onActiveFieldChanged] (only remote hosts do).
class RemoteTextInputRegistry {
  RemoteTextInputRegistry._();

  static RemoteTextInputRegistry instance = RemoteTextInputRegistry._();

  RemoteTextInputTarget? _active;
  String? _activeFieldId;
  int _fieldCounter = 0;

  // Distinguishes field sessions across app restarts: a remote that dismissed
  // its keyboard for counter-based id N must not stay suppressed when a
  // restarted host mints N again for an unrelated field.
  final String _runToken = Random().nextInt(0x7FFFFFFF).toRadixString(36);

  /// Invoked with the new field's snapshot on focus, or null on blur.
  void Function(RemoteTextFieldSnapshot? snapshot)? onActiveFieldChanged;

  /// Snapshot of the currently focused field, if any. Used to re-announce
  /// focus to a remote that connects mid-session.
  RemoteTextFieldSnapshot? get currentSnapshot {
    final active = _active;
    final fieldId = _activeFieldId;
    if (active == null || fieldId == null) return null;
    return active.describeForRemote(fieldId);
  }

  /// Marks [target] as the focused field. Idempotent for the same target, so
  /// callers may invoke it from build/didUpdateWidget without minting new
  /// field sessions.
  void notifyFocused(RemoteTextInputTarget target) {
    if (identical(_active, target)) return;
    _active = target;
    _activeFieldId = 'f${++_fieldCounter}-$_runToken';
    onActiveFieldChanged?.call(currentSnapshot);
  }

  /// Clears [target] if it is still the focused field. A late blur that
  /// arrives after focus already moved to another field is a no-op, so
  /// focus-move ordering (blur-then-focus vs focus-then-blur) doesn't matter.
  void notifyBlurred(RemoteTextInputTarget target) {
    if (!identical(_active, target)) return;
    _active = null;
    _activeFieldId = null;
    onActiveFieldChanged?.call(null);
  }

  /// Applies a remote text command to the focused field. Returns false (and
  /// drops the edit) when no field is focused or [fieldId] refers to a stale
  /// field session.
  bool handleTextInput({required String op, required String text, int? sel, String? fieldId}) {
    final active = _active;
    if (active == null) return false;
    if (fieldId != null && fieldId != _activeFieldId) return false;

    final selection = (sel ?? text.length).clamp(0, text.length);
    switch (op) {
      case 'set':
        active.applyRemoteText(text, selection);
        return true;
      case 'submit':
        active.submitFromRemote(text, selection);
        return true;
      default:
        return false;
    }
  }

  @visibleForTesting
  void reset() {
    _active = null;
    _activeFieldId = null;
    _fieldCounter = 0;
    onActiveFieldChanged = null;
  }
}
