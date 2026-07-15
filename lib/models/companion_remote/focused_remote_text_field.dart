import 'package:flutter/foundation.dart';

/// Phone-side description of the text field currently focused on the host,
/// parsed from a `textFieldFocus` command. Mirrors
/// `RemoteTextFieldSnapshot.toWireData()` on the host.
@immutable
class FocusedRemoteTextField {
  final String fieldId;
  final String text;
  final int selection;
  final String? hint;
  final bool obscureText;
  final bool multiline;
  final int? maxLength;
  final String? inputType;
  final String? action;

  const FocusedRemoteTextField({
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

  /// Returns null for blur payloads (`focused != true`) or malformed data.
  static FocusedRemoteTextField? fromWireData(Map<String, dynamic>? data) {
    if (data == null) return null;
    if (data['focused'] != true) return null;
    final fieldId = data['fid'] as String?;
    if (fieldId == null || fieldId.isEmpty) return null;

    final text = data['text'] as String? ?? '';
    final selection = (data['sel'] as int? ?? text.length).clamp(0, text.length);
    return FocusedRemoteTextField(
      fieldId: fieldId,
      text: text,
      selection: selection,
      hint: data['hint'] as String?,
      obscureText: data['obscure'] as bool? ?? false,
      multiline: data['multiline'] as bool? ?? false,
      maxLength: data['maxLength'] as int?,
      inputType: data['inputType'] as String?,
      action: data['action'] as String?,
    );
  }
}
