import '../models/analysis_issue.dart';
import '../models/localization_key.dart';
import '../models/source_location.dart';
import '../models/translation_file.dart';
import 'json_document.dart';
import 'json_parser.dart';

/// Converts locale file contents into [TranslationFile]s.
///
/// Nested objects are flattened into dot-notation keys. Plural and gender
/// groups (`{"one": ..., "other": ...}`) stay together as a single unit,
/// mirroring how easy_localization's `plural()` and `tr(gender: ...)` read
/// them.
class JsonTranslationParser {
  const JsonTranslationParser();

  static const pluralForms = {'zero', 'one', 'two', 'few', 'many', 'other'};
  static const genderForms = {'male', 'female', 'other'};

  /// Matches linked translations such as `@:app.name` or
  /// `@.capitalize:(common.ok)`.
  static final _linkPattern = RegExp(
    r'@(?:\.[a-zA-Z]+)?:(?:\(([\w\-|.]+)\)|([\w\-|.]+))',
  );

  TranslationFile parse({
    required String locale,
    required String path,
    required String absolutePath,
    required String content,
  }) {
    final issues = <AnalysisIssue>[];
    final hadBom = content.startsWith('﻿');
    JsonDocument document;
    try {
      document = JsonParser.parse(content);
    } on JsonSyntaxException catch (e) {
      issues.add(
        AnalysisIssue.error(
          'invalid_json',
          'Invalid JSON: ${e.message}',
          at: SourceLocation(path, e.line, e.column),
        ),
      );
      return TranslationFile(
        locale: locale,
        path: path,
        absolutePath: absolutePath,
        originalText: content,
        hadBom: hadBom,
        document: null,
        entries: const {},
        issues: issues,
      );
    }

    final root = document.root;
    if (root is! JsonObject) {
      issues.add(
        AnalysisIssue.error(
          'invalid_root',
          'The top-level JSON value must be an object',
          at: SourceLocation(path, 1, 1),
        ),
      );
      return TranslationFile(
        locale: locale,
        path: path,
        absolutePath: absolutePath,
        originalText: content,
        hadBom: hadBom,
        document: null,
        entries: const {},
        issues: issues,
      );
    }

    if (document.hasComments && !path.endsWith('.jsonc')) {
      issues.add(
        AnalysisIssue.warning(
          'json_comments',
          'File contains comments, which standard JSON decoders (including '
              "easy_localization's default loader) reject",
          at: SourceLocation(path, 1, 1),
        ),
      );
    }
    if (document.hasTrailingCommas && !path.endsWith('.jsonc')) {
      issues.add(
        AnalysisIssue.warning(
          'json_trailing_comma',
          'File contains trailing commas, which standard JSON decoders reject',
          at: SourceLocation(path, 1, 1),
        ),
      );
    }
    for (final dup in document.duplicateMembers) {
      final loc = document.locationOf(dup.offset);
      issues.add(
        AnalysisIssue.warning(
          'duplicate_key',
          'Duplicate key "${dup.path}"; only the last value is used at run time',
          at: SourceLocation(path, loc.line, loc.column),
        ),
      );
    }

    final entries = <String, TranslationEntry>{};
    void visit(JsonObject object, List<String> prefix) {
      for (final member in object.members) {
        final segments = [...prefix, member.name];
        final value = member.value;
        if (value is JsonObject &&
            value.members.isNotEmpty &&
            !isGroup(value)) {
          visit(value, segments);
          continue;
        }
        final key = LocalizationKey(segments, isGroup: value is JsonObject);
        final loc = document.locationOf(member.nameStart);
        final previous = entries[key.key];
        if (previous != null &&
            previous.key.segments.join('\u0000') != segments.join('\u0000')) {
          issues.add(
            AnalysisIssue.warning(
              'key_collision',
              'Key "${key.key}" is defined both as a nested path and as a '
                  'dotted member name',
              at: SourceLocation(path, loc.line, loc.column),
            ),
          );
        }
        entries[key.key] = TranslationEntry(
          key: key,
          member: member,
          rawValue: value.sourceIn(document.text),
          line: loc.line,
          linkedKeys: _linksIn(value),
        );
      }
    }

    visit(root, const []);
    return TranslationFile(
      locale: locale,
      path: path,
      absolutePath: absolutePath,
      originalText: content,
      hadBom: hadBom,
      document: document,
      entries: entries,
      issues: issues,
    );
  }

  /// Whether [object] is a plural or gender group rather than a namespace.
  static bool isGroup(JsonObject object) {
    if (object.members.isEmpty) return false;
    final names = object.members.map((m) => m.name).toSet();
    final allLeaves = object.members.every((m) => m.value is! JsonObject);
    if (!allLeaves) return false;
    return pluralForms.containsAll(names) || genderForms.containsAll(names);
  }

  static Set<String> _linksIn(JsonNode node) {
    final links = <String>{};
    void collect(JsonNode n) {
      switch (n) {
        case JsonString(:final value):
          for (final m in _linkPattern.allMatches(value)) {
            var target = m[1] ?? m[2]!;
            while (target.endsWith('.')) {
              target = target.substring(0, target.length - 1);
            }
            if (target.isNotEmpty) links.add(target);
          }
        case JsonObject(:final members):
          for (final m in members) {
            collect(m.value);
          }
        case JsonArray(:final elements):
          elements.forEach(collect);
        default:
          break;
      }
    }

    collect(node);
    return links;
  }
}
