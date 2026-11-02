import 'dart:io';

import 'package:l10n_sweep/l10n_sweep.dart';
import 'package:path/path.dart' as p;

/// Analyzes in-memory sources with a default configuration.
AnalysisReport analyzeMemory({
  required Map<String, String> dart,
  Map<String, String>? json,
  String? primaryLocale,
  List<String> excludedPaths = const [],
  List<String> excludedKeys = const [],
  List<String> ignoredKeys = const [],
  List<String> dynamicKeyPatterns = const [],
  List<TranslationFunction> translationFunctions = const [],
  bool allowUnresolved = false,
}) {
  final config = L10nSweepConfig(
    projectRoot: '/project',
    primaryLocale: primaryLocale,
    excludedPaths: excludedPaths,
    excludedKeys: excludedKeys,
    ignoredKeys: ignoredKeys,
    dynamicKeyPatterns: dynamicKeyPatterns,
    translationFunctions: translationFunctions,
    safety: SafetyConfig(allowUnresolvedReferences: allowUnresolved),
  );
  return LocalizationAnalyzer.analyzeSources(
    config: config,
    dartSources: dart,
    translationSources: json ?? {'assets/translations/en.json': '{}'},
  ).report;
}

/// Shorthand: a single en.json file.
Map<String, String> enJson(String content) => {
  'assets/translations/en.json': content,
};

KeyStatus statusOf(AnalysisReport report, String key) =>
    report.keys.firstWhere((k) => k.key == key).status;

Set<String> keysWith(AnalysisReport report, KeyStatus status) =>
    report.withStatus(status).map((k) => k.key).toSet();

/// Creates a temporary project directory populated with [files].
Directory createProject(Map<String, String> files) {
  final dir = Directory.systemTemp.createTempSync('l10n_sweep_test_');
  files.forEach((path, content) {
    final file = File(p.join(dir.path, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  });
  return dir;
}

/// Copies a fixture directory into a fresh temporary directory.
Directory copyFixture(String name) {
  final source = Directory(p.join('test', 'fixtures', name));
  final target = Directory.systemTemp.createTempSync('l10n_sweep_fixture_');
  for (final entity in source.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = p.relative(entity.path, from: source.path);
    final destination = File(p.join(target.path, relative));
    destination.parent.createSync(recursive: true);
    destination.writeAsBytesSync(entity.readAsBytesSync());
  }
  return target;
}

/// Snapshot of every file below [dir], for detecting modifications.
Map<String, List<int>> snapshot(Directory dir) => {
  for (final entity in dir.listSync(recursive: true))
    if (entity is File)
      p.relative(entity.path, from: dir.path): entity.readAsBytesSync(),
};

void deleteQuietly(Directory dir) {
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Best effort on Windows, where scanners can briefly lock files.
  }
}
