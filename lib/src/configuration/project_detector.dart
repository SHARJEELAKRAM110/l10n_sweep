import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Facts about a Flutter project discovered without any configuration.
class DetectedProject {
  const DetectedProject({
    required this.hasPubspec,
    required this.packageName,
    required this.isFlutter,
    required this.easyLocalizationConstraint,
    required this.declaredAssets,
    required this.easyLocalizationPath,
    required this.fallbackLocale,
    required this.translationsPath,
    required this.usesGeneratedLocaleKeys,
    required this.generatedKeysPaths,
  });

  final bool hasPubspec;
  final String? packageName;
  final bool isFlutter;

  /// Version constraint of the `easy_localization` dependency, if declared.
  final String? easyLocalizationConstraint;

  /// `flutter: assets:` entries from pubspec.yaml.
  final List<String> declaredAssets;

  /// `path:` argument of the `EasyLocalization` widget, if found.
  final String? easyLocalizationPath;

  /// Locale code from `fallbackLocale: Locale('en')`, if found.
  final String? fallbackLocale;

  /// Best guess for the translations directory, relative to the root.
  final String? translationsPath;

  /// Whether a generated `LocaleKeys` class was found.
  final bool usesGeneratedLocaleKeys;
  final List<String> generatedKeysPaths;

  bool get hasEasyLocalization => easyLocalizationConstraint != null;
}

/// Inspects pubspec.yaml and source files to infer sensible defaults.
class ProjectDetector {
  const ProjectDetector();

  static const commonTranslationDirs = [
    'assets/translations',
    'assets/translation',
    'assets/lang',
    'assets/langs',
    'assets/languages',
    'assets/l10n',
    'assets/i18n',
    'assets/locales',
    'assets/localization',
    'assets/localizations',
    'resources/langs',
    'lang',
    'translations',
  ];

  static final _easyLocalizationCall = RegExp(r'\bEasyLocalization\s*\(');
  static final _pathArgument = RegExp(r'''\bpath\s*:\s*(['"])([^'"]+)\1''');
  static final _fallbackArgument = RegExp(
    r'''\bfallbackLocale\s*:\s*(?:const\s+)?Locale\s*\(\s*(['"])(\w+)\1'''
    r'''(?:\s*,\s*(['"])(\w+)\3)?''',
  );
  static final _localeKeysClass = RegExp(r'\babstract\s+class\s+LocaleKeys\b');

  DetectedProject detect(String projectRoot) {
    final pubspecFile = File(p.join(projectRoot, 'pubspec.yaml'));
    String? packageName;
    var isFlutter = false;
    String? easyConstraint;
    final assets = <String>[];
    if (pubspecFile.existsSync()) {
      try {
        final yaml = loadYaml(pubspecFile.readAsStringSync());
        if (yaml is YamlMap) {
          packageName = yaml['name']?.toString();
          final deps = yaml['dependencies'];
          if (deps is YamlMap) {
            final flutterDep = deps['flutter'];
            isFlutter = flutterDep is YamlMap && flutterDep['sdk'] == 'flutter';
            if (deps.containsKey('easy_localization')) {
              final value = deps['easy_localization'];
              easyConstraint = value is String
                  ? value
                  : (value == null ? 'any' : value.toString());
            }
          }
          final flutter = yaml['flutter'];
          if (flutter is YamlMap && flutter['assets'] is YamlList) {
            for (final asset in flutter['assets'] as YamlList) {
              if (asset is String) {
                assets.add(asset);
              } else if (asset is YamlMap && asset['path'] is String) {
                assets.add(asset['path'] as String);
              }
            }
          }
        }
      } on YamlException {
        // Reported by the doctor command; detection stays best-effort.
      }
    }

    String? easyPath;
    String? fallback;
    final keysFiles = <String>[];
    final libDir = Directory(p.join(projectRoot, 'lib'));
    if (libDir.existsSync()) {
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        String content;
        try {
          content = entity.readAsStringSync();
        } on FileSystemException {
          continue;
        }
        if (_localeKeysClass.hasMatch(content)) {
          keysFiles.add(
            p.relative(entity.path, from: projectRoot).replaceAll(r'\', '/'),
          );
        }
        if (easyPath != null && fallback != null) continue;
        for (final call in _easyLocalizationCall.allMatches(content)) {
          final window = content.substring(
            call.end,
            (call.end + 1500).clamp(0, content.length),
          );
          easyPath ??= _pathArgument.firstMatch(window)?.group(2);
          final fb = _fallbackArgument.firstMatch(window);
          if (fb != null && fallback == null) {
            fallback = fb.group(4) == null
                ? fb.group(2)
                : '${fb.group(2)}-${fb.group(4)}';
          }
        }
      }
    }

    return DetectedProject(
      hasPubspec: pubspecFile.existsSync(),
      packageName: packageName,
      isFlutter: isFlutter,
      easyLocalizationConstraint: easyConstraint,
      declaredAssets: assets,
      easyLocalizationPath: easyPath,
      fallbackLocale: fallback,
      translationsPath: _guessTranslationsPath(projectRoot, easyPath, assets),
      usesGeneratedLocaleKeys: keysFiles.isNotEmpty,
      generatedKeysPaths: keysFiles,
    );
  }

  String? _guessTranslationsPath(
    String root,
    String? easyPath,
    List<String> assets,
  ) {
    bool hasJson(String rel) {
      final dir = Directory(p.join(root, rel));
      if (!dir.existsSync()) return false;
      return dir.listSync().any(
        (e) =>
            e is File &&
            (e.path.endsWith('.json') || e.path.endsWith('.jsonc')),
      );
    }

    String clean(String path) {
      var result = path.replaceAll(r'\', '/');
      while (result.endsWith('/')) {
        result = result.substring(0, result.length - 1);
      }
      return result;
    }

    if (easyPath != null && hasJson(clean(easyPath))) return clean(easyPath);
    for (final asset in assets) {
      final candidate = clean(asset);
      final lower = candidate.toLowerCase();
      final looksLikeTranslations = [
        'translation',
        'lang',
        'l10n',
        'i18n',
        'locale',
        'localization',
      ].any(lower.contains);
      if (looksLikeTranslations && hasJson(candidate)) return candidate;
    }
    for (final candidate in commonTranslationDirs) {
      if (hasJson(candidate)) return candidate;
    }
    return easyPath == null ? null : clean(easyPath);
  }
}
