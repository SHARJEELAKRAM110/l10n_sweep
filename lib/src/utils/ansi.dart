import 'dart:io';

/// Minimal ANSI styling that can be switched off for CI logs and files.
class Ansi {
  const Ansi(this.enabled);

  /// Colors are enabled for terminals that support them, unless `NO_COLOR`
  /// is set (https://no-color.org) or `TERM` is `dumb`.
  factory Ansi.detect() {
    final env = Platform.environment;
    if (env.containsKey('NO_COLOR') || env['TERM'] == 'dumb') {
      return const Ansi(false);
    }
    if (env.containsKey('FORCE_COLOR')) return const Ansi(true);
    return Ansi(stdout.hasTerminal && stdout.supportsAnsiEscapes);
  }

  final bool enabled;

  String _wrap(String text, String code) =>
      enabled ? '\x1B[${code}m$text\x1B[0m' : text;

  String bold(String text) => _wrap(text, '1');
  String dim(String text) => _wrap(text, '2');
  String red(String text) => _wrap(text, '31');
  String green(String text) => _wrap(text, '32');
  String yellow(String text) => _wrap(text, '33');
  String cyan(String text) => _wrap(text, '36');
}
