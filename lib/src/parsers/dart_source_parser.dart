import 'dart:io';

import 'package:path/path.dart' as p;

import '../analyzer/dart_ast_analyzer.dart';
import '../analyzer/project_index.dart';
import '../configuration/l10n_sweep_config.dart';
import '../utils/path_matcher.dart';

/// A Dart file selected for analysis.
class DartSource {
  const DartSource({
    required this.path,
    required this.absolutePath,
    required this.isUsageSource,
  });

  /// Path relative to the project root.
  final String path;
  final String absolutePath;

  /// `false` when the file is under `excluded_paths`.
  final bool isUsageSource;
}

/// Finds the Dart files to analyze according to the configuration.
class DartSourceCollector {
  const DartSourceCollector(this.config);

  final L10nSweepConfig config;

  static const _skippedDirectories = {'.dart_tool', '.git', 'build', '.idea'};

  List<DartSource> collect() {
    final root = config.projectRoot;
    final excluded = PathMatcher(config.excludedPaths);
    final extensions = {for (final e in config.fileExtensions) '.$e'};
    final seen = <String>{};
    final result = <DartSource>[];
    for (final sourcePath in config.sourcePaths) {
      final absolute = p.normalize(p.join(root, sourcePath));
      final type = FileSystemEntity.typeSync(absolute);
      final Iterable<File> files;
      if (type == FileSystemEntityType.file) {
        files = [File(absolute)];
      } else if (type == FileSystemEntityType.directory) {
        files = _walk(Directory(absolute));
      } else {
        continue;
      }
      for (final file in files) {
        if (!extensions.contains(p.extension(file.path))) continue;
        final relative = relativePosix(file.path, root);
        if (!seen.add(relative)) continue;
        result.add(
          DartSource(
            path: relative,
            absolutePath: file.path,
            isUsageSource: !excluded.matches(relative),
          ),
        );
      }
    }
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  Iterable<File> _walk(Directory dir) sync* {
    List<FileSystemEntity> children;
    try {
      children = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final child in children) {
      if (child is File) {
        yield child;
      } else if (child is Directory &&
          !_skippedDirectories.contains(p.basename(child.path))) {
        yield* _walk(child);
      }
    }
  }
}

/// Parses Dart files into [FileIndex]es, reusing results for files whose
/// contents have not changed since the last call.
///
/// Keeping one parser alive (in an IDE plugin or watch mode, for example)
/// makes re-analysis incremental: only edited files are parsed again.
class DartSourceParser {
  DartSourceParser({List<TranslationFunction> translationFunctions = const []})
    : _analyzer = DartAstAnalyzer(translationFunctions: translationFunctions);

  final DartAstAnalyzer _analyzer;
  final Map<String, ({String content, bool usage, FileIndex index})> _cache =
      {};

  int _parsedCount = 0;

  /// Number of files actually parsed (cache misses) so far.
  int get parsedCount => _parsedCount;

  FileIndex parse({
    required String path,
    required String content,
    required bool isUsageSource,
  }) {
    final cached = _cache[path];
    if (cached != null &&
        cached.usage == isUsageSource &&
        cached.content == content) {
      return cached.index;
    }
    _parsedCount++;
    final index = _analyzer.analyze(
      path: path,
      content: content,
      isUsageSource: isUsageSource,
    );
    _cache[path] = (content: content, usage: isUsageSource, index: index);
    return index;
  }

  /// Drops cached entries for files that no longer exist.
  void retainOnly(Set<String> paths) {
    _cache.removeWhere((path, _) => !paths.contains(path));
  }
}
