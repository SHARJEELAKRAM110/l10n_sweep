import 'dart:io';

import '../utils/ansi.dart';

/// An entry in a multi-select list.
class SelectableItem {
  SelectableItem({required this.label, this.detail, this.selected = false});

  final String label;

  /// Short annotation shown after the label, such as the key's status.
  final String? detail;
  bool selected;
}

/// Asks the user questions. Replaceable in tests.
abstract class Prompter {
  /// Whether questions can be asked (stdin is an interactive terminal).
  bool get canPrompt;

  /// Lets the user pick items. Returns the selected indices, or `null` when
  /// the user cancels.
  List<int>? select(String title, List<SelectableItem> items);

  /// Asks a yes/no question. Anything but an explicit yes returns
  /// [defaultValue].
  bool confirm(String question, {bool defaultValue = false});
}

/// Prompts on the process terminal.
class TerminalPrompter implements Prompter {
  TerminalPrompter(this.ansi);

  final Ansi ansi;

  @override
  bool get canPrompt => stdin.hasTerminal;

  @override
  List<int>? select(String title, List<SelectableItem> items) {
    final rawModeAvailable =
        ansi.enabled && stdout.hasTerminal && stdout.supportsAnsiEscapes;
    if (rawModeAvailable) {
      final previousEcho = stdin.echoMode;
      final previousLine = stdin.lineMode;
      try {
        stdin
          ..echoMode = false
          ..lineMode = false;
        return InteractiveSelector(
          ansi: ansi,
          readByte: stdin.readByteSync,
          write: stdout.write,
          pageSize: _pageSize(),
        ).run(title, items);
      } on StdinException {
        // Fall back to line-based selection below.
      } finally {
        try {
          stdin
            ..lineMode = previousLine
            ..echoMode = previousEcho;
        } on StdinException {
          // The terminal went away; nothing to restore.
        }
      }
    }
    return LineSelector(
      readLine: () => stdin.readLineSync(),
      write: stdout.write,
    ).run(title, items);
  }

  @override
  bool confirm(String question, {bool defaultValue = false}) {
    stdout.write(
      '${ansi.bold('?')} $question ${defaultValue ? '(Y/n)' : '(y/N)'} ',
    );
    final answer = stdin.readLineSync()?.trim().toLowerCase();
    if (answer == null || answer.isEmpty) return defaultValue;
    return answer == 'y' || answer == 'yes';
  }

  int _pageSize() {
    try {
      return (stdout.terminalLines - 8).clamp(5, 30);
    } on StdoutException {
      return 15;
    }
  }
}

/// A checkbox list driven by single key presses.
///
/// Keys: up/down or k/j move, space toggles, `a` toggles all, enter
/// confirms, `q` or Ctrl+C cancels.
class InteractiveSelector {
  InteractiveSelector({
    required this.ansi,
    required this.readByte,
    required this.write,
    this.pageSize = 15,
  });

  final Ansi ansi;
  final int Function() readByte;
  final void Function(String) write;
  final int pageSize;

  List<int>? run(String title, List<SelectableItem> items) {
    if (items.isEmpty) return const [];
    var cursor = 0;
    var top = 0;
    var drawnLines = 0;

    void draw() {
      if (drawnLines > 0) write('\x1B[${drawnLines}A\x1B[J');
      final lines = <String>[];
      final selected = items.where((i) => i.selected).length;
      lines.add(
        '${ansi.bold('?')} $title ${ansi.dim('($selected/${items.length} selected)')}',
      );
      if (cursor < top) top = cursor;
      if (cursor >= top + pageSize) top = cursor - pageSize + 1;
      final end = (top + pageSize).clamp(0, items.length);
      for (var i = top; i < end; i++) {
        final item = items[i];
        final pointer = i == cursor ? ansi.cyan('>') : ' ';
        final box = item.selected ? ansi.green('[x]') : '[ ]';
        final detail = item.detail == null ? '' : ansi.dim('  ${item.detail}');
        lines.add('$pointer $box ${item.label}$detail');
      }
      if (items.length > pageSize) {
        lines.add(ansi.dim('  (${top + 1}-$end of ${items.length})'));
      }
      lines.add(
        ansi.dim(
          '  up/down move, space toggle, a all, enter confirm, q cancel',
        ),
      );
      write('${lines.join('\n')}\n');
      drawnLines = lines.length;
    }

    draw();
    while (true) {
      final byte = readByte();
      switch (byte) {
        case -1 || 3 || 0x71: // EOF, Ctrl+C, q
          write('\n');
          return null;
        case 10 || 13: // enter
          return [
            for (var i = 0; i < items.length; i++)
              if (items[i].selected) i,
          ];
        case 0x20: // space
          items[cursor].selected = !items[cursor].selected;
        case 0x61: // a
          final selectAll = items.any((i) => !i.selected);
          for (final item in items) {
            item.selected = selectAll;
          }
        case 0x6B || 0x77: // k, w
          cursor = (cursor - 1) % items.length;
        case 0x6A || 0x73: // j, s
          cursor = (cursor + 1) % items.length;
        case 27: // escape sequence
          if (readByte() != 0x5B) continue;
          final code = readByte();
          if (code == 0x41) cursor = (cursor - 1) % items.length;
          if (code == 0x42) cursor = (cursor + 1) % items.length;
        case 224 || 0: // Windows console arrow prefix
          final code = readByte();
          if (code == 72) cursor = (cursor - 1) % items.length;
          if (code == 80) cursor = (cursor + 1) % items.length;
        default:
          continue;
      }
      draw();
    }
  }
}

/// Selection by typing item numbers, for terminals without raw input.
class LineSelector {
  LineSelector({required this.readLine, required this.write});

  final String? Function() readLine;
  final void Function(String) write;

  List<int>? run(String title, List<SelectableItem> items) {
    if (items.isEmpty) return const [];
    final width = '${items.length}'.length;
    while (true) {
      write('? $title\n');
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final detail = item.detail == null ? '' : '  (${item.detail})';
        write(
          '  ${'${i + 1}'.padLeft(width)}. [${item.selected ? 'x' : ' '}] '
          '${item.label}$detail\n',
        );
      }
      write(
        'Toggle numbers (e.g. 1,3-5), "a" select all, "n" select none, '
        'Enter to continue, "q" to cancel: ',
      );
      final input = readLine();
      if (input == null) return null;
      final answer = input.trim().toLowerCase();
      if (answer.isEmpty) {
        return [
          for (var i = 0; i < items.length; i++)
            if (items[i].selected) i,
        ];
      }
      if (answer == 'q') return null;
      if (answer == 'a' || answer == 'n') {
        for (final item in items) {
          item.selected = answer == 'a';
        }
        continue;
      }
      final indices = parseSelection(answer, items.length);
      if (indices == null) {
        write('Could not understand "$input".\n');
        continue;
      }
      for (final i in indices) {
        items[i].selected = !items[i].selected;
      }
    }
  }

  /// Parses `1,3-5` into zero-based indices. Returns `null` when invalid.
  static Set<int>? parseSelection(String input, int count) {
    final result = <int>{};
    for (final part in input.split(RegExp(r'[,\s]+'))) {
      if (part.isEmpty) continue;
      final range = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(part);
      if (range == null) return null;
      final from = int.parse(range[1]!);
      final to = int.parse(range[2] ?? range[1]!);
      if (from < 1 || to > count || from > to) return null;
      for (var i = from; i <= to; i++) {
        result.add(i - 1);
      }
    }
    return result;
  }
}
