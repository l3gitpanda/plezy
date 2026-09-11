import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../providers/yattee/yattee_account_provider.dart';
import '../../services/yattee/yattee_exceptions.dart';
import '../../theme/mono_tokens.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../settings/async_form_state_mixin.dart';

/// Two-step Yattee Server connect flow, the Seerr flow's shape:
///   1. Probe the instance URL (`/health`), racing https/http/default-port
///      candidates for schemeless input but never settling on plaintext
///      while TLS may still answer.
///   2. Sign in with the HTTP Basic Auth account the server's setup wizard
///      created, verified against `/info`.
///
/// The finished [YatteeSession] is handed to
/// [YatteeAccountProvider.adoptSession] and the screen pops.
class YatteeConnectScreen extends StatefulWidget {
  const YatteeConnectScreen({super.key});

  @override
  State<YatteeConnectScreen> createState() => _YatteeConnectScreenState();
}

class _YatteeConnectScreenState extends State<YatteeConnectScreen> with AsyncFormStateMixin, ControllerDisposerMixin {
  late final _urlController = createTextEditingController();
  late final _usernameController = createTextEditingController();
  late final _passwordController = createTextEditingController();
  final _urlFocus = FocusNode(debugLabel: 'YatteeConnect:Url');
  final _continueFocus = FocusNode(debugLabel: 'YatteeConnect:Continue');
  final _changeServerFocus = FocusNode(debugLabel: 'YatteeConnect:ChangeServer');
  final _usernameFocus = FocusNode(debugLabel: 'YatteeConnect:Username');
  final _passwordFocus = FocusNode(debugLabel: 'YatteeConnect:Password');
  final _formKey = GlobalKey<FormState>();

  /// Set once the probe answers; null while on the URL step.
  String? _baseUrl;

  @override
  void dispose() {
    _urlFocus.dispose();
    _continueFocus.dispose();
    _changeServerFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    final input = _urlController.text.trim();
    if (input.isEmpty) {
      setErrorText(t.addServer.required);
      return;
    }
    await runAsync<void>(() async {
      final account = context.read<YatteeAccountProvider>();
      final baseUrl = await account.authService.probeFirstReachable(input);
      if (!mounted) return;
      setState(() => _baseUrl = baseUrl);
      requestFocusAfterFrame(_usernameFocus);
    }, errorMapper: _describeError);
  }

  Future<void> _signIn() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final baseUrl = _baseUrl;
    if (baseUrl == null) return;
    await runAsync<void>(() async {
      final account = context.read<YatteeAccountProvider>();
      final session = await account.authService.signIn(
        baseUrl: baseUrl,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
      await account.adoptSession(session);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    }, errorMapper: _describeError);
  }

  String _describeError(Object e) => switch (e) {
    YatteeUrlException(:final message, :final display) => display ?? message,
    YatteeAuthException(:final message, :final display) => display ?? message,
    YatteeApiException(:final message) => message,
    _ => t.addServer.couldNotReachServer(error: e.toString()),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.yattee.connectTitle),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _baseUrl == null ? _buildUrlStep(theme) : _buildSignInStep(theme),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildUrlStep(ThemeData theme) {
    return [
      FocusableTextFormField(
        controller: _urlController,
        focusNode: _urlFocus,
        autofocus: true,
        tvTextInputAutoOpenBehavior: deferredUrlFieldAutoOpen,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
        enabled: !busy,
        onNavigateDown: () => _continueFocus.requestFocus(),
        textInputAction: TextInputAction.go,
        onFieldSubmitted: busy ? null : (_) => _probe(),
        decoration: InputDecoration(
          labelText: t.yattee.serverUrl,
          // URL example — intentionally not localized.
          hintText: 'https://yattee.example.com',
          helperText: t.yattee.serverUrlHelper,
          prefixIcon: const AppIcon(Symbols.link_rounded, fill: 1),
        ),
      ),
      const SizedBox(height: 16),
      FocusableButton(
        focusNode: _continueFocus,
        useBackgroundFocus: true,
        onNavigateUp: () => _urlFocus.requestFocus(),
        onPressed: busy ? null : _probe,
        child: FilledButton.icon(
          onPressed: busy ? null : _probe,
          icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.travel_explore_rounded, fill: 1),
          label: Text(t.yattee.checkServer),
        ),
      ),
      ...buildInlineError(theme),
    ];
  }

  List<Widget> _buildSignInStep(ThemeData theme) {
    return [
      _buildInstanceCard(theme),
      const SizedBox(height: 16),
      FocusableTextFormField(
        controller: _usernameController,
        focusNode: _usernameFocus,
        autocorrect: false,
        enableSuggestions: false,
        enabled: !busy,
        textInputAction: TextInputAction.next,
        onFieldSubmitted: busy ? null : (_) => _passwordFocus.requestFocus(),
        decoration: InputDecoration(
          labelText: t.addServer.username,
          prefixIcon: const AppIcon(Symbols.person_rounded, fill: 1),
        ),
        validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
      ),
      const SizedBox(height: 12),
      FocusableTextFormField(
        controller: _passwordController,
        focusNode: _passwordFocus,
        obscureText: true,
        enabled: !busy,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: busy ? null : (_) => _signIn(),
        decoration: InputDecoration(
          labelText: t.addServer.password,
          prefixIcon: const AppIcon(Symbols.lock_rounded, fill: 1),
        ),
        validator: (v) => v == null || v.isEmpty ? t.addServer.required : null,
      ),
      const SizedBox(height: 16),
      FocusableButton(
        useBackgroundFocus: true,
        onPressed: busy ? null : _signIn,
        child: FilledButton.icon(
          onPressed: busy ? null : _signIn,
          icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.login_rounded, fill: 1),
          label: Text(t.addServer.signIn),
        ),
      ),
      ...buildInlineError(theme),
    ];
  }

  Widget _buildInstanceCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(tokens(context).radiusMd),
      ),
      child: Row(
        children: [
          const AppIcon(Symbols.cloud_done_rounded, fill: 1),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.services.names.yattee, style: theme.textTheme.titleSmall),
                Text(
                  _baseUrl ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                ),
              ],
            ),
          ),
          FocusableButton(
            focusNode: _changeServerFocus,
            useBackgroundFocus: true,
            onPressed: busy ? null : _resetToUrlStep,
            child: TextButton(onPressed: busy ? null : _resetToUrlStep, child: Text(t.addServer.change)),
          ),
        ],
      ),
    );
  }

  void _resetToUrlStep() {
    setState(() {
      _baseUrl = null;
      _usernameController.clear();
      _passwordController.clear();
    });
  }
}
