import '../models/translation_file.dart';
import '../parsers/json_document.dart';
import '../parsers/json_parser.dart';
import '../parsers/json_translation_parser.dart';

/// Raised when an edit cannot be performed or fails verification.
class JsonEditException implements Exception {
  JsonEditException(this.path, this.message);

  final String path;
  final String message;

  @override
  String toString() => '$path: $message';
}

/// The new contents of a locale file after removing keys.
class JsonEditResult {
  const JsonEditResult({
    required this.path,
    required this.newContent,
    required this.removedKeys,
  });

  final String path;

  /// Complete new file contents, including the original BOM if any.
  final String newContent;
  final List<String> removedKeys;
}

/// Removes keys from a locale file by deleting their exact text spans.
///
/// Everything that is not removed — indentation, line endings, key order,
/// escapes, non-ASCII text, comments in JSONC files — stays byte-for-byte
/// identical. Every edit is verified by re-parsing the result and checking
/// that exactly the requested keys disappeared and all other values are
/// unchanged.
class JsonPreservationService {
  const JsonPreservationService({this.removeEmptyParents = true});

  /// Whether to remove objects emptied by the removal.
  final bool removeEmptyParents;

  JsonEditResult removeKeys(TranslationFile file, Set<String> keys) {
    final document = file.document;
    if (document == null) {
      throw JsonEditException(file.path, 'file is not valid JSON');
    }
    final root = document.root;
    if (root is! JsonObject) {
      throw JsonEditException(file.path, 'top-level value is not an object');
    }

    final targets = <String>{};
    final removed = <String>[];
    for (final key in keys) {
      final entry = file.entries[key];
      if (entry == null) continue;
      targets.add(_pathKey(entry.key.segments));
      removed.add(key);
    }
    if (targets.isEmpty) {
      return JsonEditResult(
        path: file.path,
        newContent: file.originalText,
        removedKeys: const [],
      );
    }
    final prefixes = <String>{};
    for (final target in targets) {
      final parts = target.split('\u0000');
      for (var i = 1; i < parts.length; i++) {
        prefixes.add(parts.take(i).join('\u0000'));
      }
    }

    final text = document.text;
    final edits = <_Edit>[];
    final rootRemoved = _planObject(
      text,
      root,
      const [],
      targets,
      prefixes,
      edits,
    );
    if (rootRemoved) {
      edits
        ..clear()
        ..add(_Edit(root.start + 1, root.end - 1, ''));
    }

    final edited = _apply(text, edits, file.path);
    _verify(file, edited, removed.toSet());
    return JsonEditResult(
      path: file.path,
      newContent: file.hadBom ? '﻿$edited' : edited,
      removedKeys: removed,
    );
  }

  static String _pathKey(List<String> segments) => segments.join('\u0000');

  /// Plans edits for [object]. Returns `true` when every member of a
  /// non-empty object is removed, letting the caller remove the object.
  bool _planObject(
    String text,
    JsonObject object,
    List<String> prefix,
    Set<String> targets,
    Set<String> prefixes,
    List<_Edit> edits,
  ) {
    final members = object.members;
    if (members.isEmpty) return false;
    final remove = List<bool>.filled(members.length, false);
    final childEdits = <_Edit>[];
    for (var i = 0; i < members.length; i++) {
      final member = members[i];
      final path = [...prefix, member.name];
      final key = _pathKey(path);
      if (targets.contains(key)) {
        remove[i] = true;
        continue;
      }
      final value = member.value;
      if (value is JsonObject &&
          prefixes.contains(key) &&
          !JsonTranslationParser.isGroup(value)) {
        final nested = <_Edit>[];
        final emptied = _planObject(
          text,
          value,
          path,
          targets,
          prefixes,
          nested,
        );
        if (emptied && removeEmptyParents) {
          remove[i] = true;
        } else if (emptied) {
          childEdits.add(_Edit(value.start + 1, value.end - 1, ''));
        } else {
          childEdits.addAll(nested);
        }
      }
    }

    if (remove.every((r) => r)) return true;
    edits.addAll(childEdits);
    _planMemberRemovals(text, object, remove, edits);
    return false;
  }

  void _planMemberRemovals(
    String text,
    JsonObject object,
    List<bool> remove,
    List<_Edit> edits,
  ) {
    final members = object.members;
    final n = members.length;
    var i = 0;
    while (i < n) {
      if (!remove[i]) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < n && remove[j + 1]) {
        j++;
      }
      if (j < n - 1) {
        // Followed by a kept member: delete from the end of the previous
        // line up to and including this run's last comma (and any comment
        // on that line). The next member keeps its own indentation.
        final start = i == 0
            ? _lineTail(text, object.start + 1)
            : _memberTail(text, members[i - 1]);
        edits.add(_Edit(start, _memberTail(text, members[j]), ''));
      } else {
        // The run reaches the end of the object: the previous member becomes
        // the last one and loses its separating comma, unless the file uses
        // trailing commas.
        final previous = members[i - 1];
        final last = members[n - 1];
        if (last.commaOffset == null && previous.commaOffset != null) {
          final comma = previous.commaOffset!;
          edits.add(_Edit(comma, comma + 1, ''));
        }
        edits.add(
          _Edit(_memberTail(text, previous), _memberTail(text, last), ''),
        );
      }
      i = j + 1;
    }
  }

  /// Position after a member's value, its comma and a comment on the same
  /// line, but before the line break.
  static int _memberTail(String text, JsonMember member) {
    final comma = member.commaOffset;
    return _lineTail(text, comma != null ? comma + 1 : member.end);
  }

  /// Extends [offset] over a trailing same-line comment, if present.
  static int _lineTail(String text, int offset) {
    var p = offset;
    while (p < text.length && (text[p] == ' ' || text[p] == '\t')) {
      p++;
    }
    if (text.startsWith('//', p)) {
      var end = text.indexOf('\n', p);
      if (end == -1) end = text.length;
      if (end > p && text[end - 1] == '\r') end--;
      return end;
    }
    if (text.startsWith('/*', p)) {
      final close = text.indexOf('*/', p + 2);
      final newline = text.indexOf('\n', p);
      if (close != -1 && (newline == -1 || close < newline)) return close + 2;
    }
    return offset;
  }

  static String _apply(String text, List<_Edit> edits, String path) {
    edits.sort((a, b) => b.start.compareTo(a.start));
    final buffer = StringBuffer();
    var cursor = text.length;
    final pieces = <String>[];
    for (final edit in edits) {
      if (edit.end > cursor || edit.start > edit.end) {
        throw JsonEditException(path, 'internal error: overlapping edits');
      }
      pieces.add(text.substring(edit.end, cursor));
      pieces.add(edit.replacement);
      cursor = edit.start;
    }
    pieces.add(text.substring(0, cursor));
    for (final piece in pieces.reversed) {
      buffer.write(piece);
    }
    return buffer.toString();
  }

  void _verify(TranslationFile original, String edited, Set<String> removed) {
    JsonDocument document;
    try {
      document = JsonParser.parse(edited);
    } on JsonSyntaxException catch (e) {
      throw JsonEditException(
        original.path,
        'verification failed: edited file would be invalid ($e)',
      );
    }
    final reparsed = const JsonTranslationParser().parse(
      locale: original.locale,
      path: original.path,
      absolutePath: original.absolutePath,
      content: edited,
    );
    if (!reparsed.isValid) {
      throw JsonEditException(original.path, 'verification failed: re-parse');
    }
    if (document.hasComments != original.document!.hasComments &&
        !original.document!.hasComments) {
      throw JsonEditException(original.path, 'verification failed: comments');
    }
    for (final entry in original.entries.entries) {
      final key = entry.key;
      final after = reparsed.entries[key];
      if (removed.contains(key)) {
        if (after != null) {
          throw JsonEditException(
            original.path,
            'verification failed: "$key" is still present',
          );
        }
        continue;
      }
      if (after == null) {
        throw JsonEditException(
          original.path,
          'verification failed: "$key" would be removed unintentionally',
        );
      }
      if (after.rawValue != entry.value.rawValue) {
        throw JsonEditException(
          original.path,
          'verification failed: the value of "$key" would change',
        );
      }
    }
    for (final key in reparsed.entries.keys) {
      if (original.entries.containsKey(key)) continue;
      final emptiedParent =
          reparsed.entries[key]!.rawValue.replaceAll(RegExp(r'\s'), '') ==
              '{}' &&
          removed.any((r) => r.startsWith('$key.'));
      if (!emptiedParent) {
        throw JsonEditException(
          original.path,
          'verification failed: unexpected key "$key"',
        );
      }
    }
  }
}

class _Edit {
  _Edit(this.start, this.end, this.replacement);

  final int start;
  final int end;
  final String replacement;
}
