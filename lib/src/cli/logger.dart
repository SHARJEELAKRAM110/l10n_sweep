import 'dart:io';

import '../utils/ansi.dart';

/// Writes CLI output. Diagnostics go to stderr so that machine-readable
/// output on stdout (`--format json`) stays parseable.
class Logger {
  Logger({required this.ansi, StringSink? out, StringSink? err})
    : _out = out ?? stdout,
      _err = err ?? stderr;

  final Ansi ansi;
  final StringSink _out;
  final StringSink _err;

  /// Writes [text] to stdout as-is.
  void write(String text) => _out.write(text);

  void info(String message) => _out.writeln(message);

  void success(String message) => _out.writeln(ansi.green(message));

  void detail(String message) => _out.writeln(ansi.dim(message));

  void warn(String message) => _err.writeln(ansi.yellow('Warning: $message'));

  void error(String message) => _err.writeln(ansi.red('Error: $message'));

  /// Writes a status line to stderr, for use alongside stdout reports.
  void status(String message) => _err.writeln(ansi.dim(message));
}
