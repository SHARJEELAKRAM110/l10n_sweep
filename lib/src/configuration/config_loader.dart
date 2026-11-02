import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../utils/path_matcher.dart';
import 'l10n_sweep_config.dart';
import 'project_detector.dart';

/// Raised for unreadable or invalid configuration.
class ConfigException implements Exception {
  ConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Result of [ConfigLoader.load].
class LoadedConfig {
  const LoadedConfig(this.config, this.warnings, this.detected);

  final L10nSweepConfig config;

  /// Non-fatal problems such as unknown options.
  final List<String> warnings;
  final DetectedProject detected;
}

/// Loads `l10n_sweep.yaml`, falling back to an `l10n_sweep:` section in
/// pubspec.yaml and finally to auto-detected defaults.
class ConfigLoader {
  const ConfigLoader({this.detector = const ProjectDetector()});

  static const fileName = 'l10n_sweep.yaml';
  static const rootKey = 'l10n_sweep';

  final ProjectDetector detector;

  static const _topLevelKeys = {
    'translations_path',
    'primary_locale',
    'source_paths',
    'file_extensions',
    'excluded_paths',
    'excluded_keys',
    'ignored_keys',
    'dynamic_key_patterns',
    'translation_functions',
    'output',
    'safety',
    'cleanup',
  };
  static const _outputKeys = {'format', 'path'};
  static const _safetyKeys = {
    'create_backup',
    'backup_path',
    'require_confirmation',
    'preserve_uncertain_keys',
    'allow_unresolved_references',
  };
  static const _cleanupKeys = {'remove_empty_parents'};

  LoadedConfig load(String projectRoot, {String? configPath}) {
    final root = p.normalize(p.absolute(projectRoot));
    if (!Directory(root).existsSync()) {
      throw ConfigException('Project directory "$root" does not exist.');
    }
    final detected = detector.detect(root);
    final warnings = <String>[];

    YamlMap? section;
    String? source;
    if (configPath != null) {
      final file = File(
        p.isAbsolute(configPath) ? configPath : p.join(root, configPath),
      );
      if (!file.existsSync()) {
        throw ConfigException('Configuration file "${file.path}" not found.');
      }
      section = _readSection(file, required: true);
      source = file.path;
    } else {
      final file = File(p.join(root, fileName));
      if (file.existsSync()) {
        section = _readSection(file, required: true);
        source = file.path;
      } else {
        final pubspec = File(p.join(root, 'pubspec.yaml'));
        if (pubspec.existsSync()) {
          section = _readSection(pubspec, required: false);
          if (section != null) source = pubspec.path;
        }
      }
    }

    final config = _build(
      root,
      section ?? YamlMap(),
      source,
      detected,
      warnings,
    );
    return LoadedConfig(config, warnings, detected);
  }

  YamlMap? _readSection(File file, {required bool required}) {
    Object? yaml;
    try {
      yaml = loadYaml(file.readAsStringSync(), sourceUrl: file.uri);
    } on YamlException catch (e) {
      throw ConfigException('Invalid YAML in ${file.path}: ${e.message}');
    } on FileSystemException catch (e) {
      throw ConfigException('Cannot read ${file.path}: ${e.message}');
    }
    if (yaml == null) {
      if (required) {
        throw ConfigException('${file.path} is empty; expected "$rootKey:".');
      }
      return null;
    }
    if (yaml is! YamlMap) {
      throw ConfigException('${file.path} must contain a YAML map.');
    }
    if (!yaml.containsKey(rootKey)) {
      if (required) {
        throw ConfigException(
          '${file.path} must have a top-level "$rootKey:" section.',
        );
      }
      return null;
    }
    final section = yaml[rootKey];
    if (section == null) return YamlMap();
    if (section is! YamlMap) {
      throw ConfigException('"$rootKey" in ${file.path} must be a map.');
    }
    return section;
  }

  L10nSweepConfig _build(
    String root,
    YamlMap map,
    String? source,
    DetectedProject detected,
    List<String> warnings,
  ) {
    _warnUnknown(map, _topLevelKeys, rootKey, warnings);
    final output = _map(map, 'output');
    final safety = _map(map, 'safety');
    final cleanup = _map(map, 'cleanup');
    if (output != null) _warnUnknown(output, _outputKeys, 'output', warnings);
    if (safety != null) _warnUnknown(safety, _safetyKeys, 'safety', warnings);
    if (cleanup != null) {
      _warnUnknown(cleanup, _cleanupKeys, 'cleanup', warnings);
    }

    final extensions = _stringList(map, 'file_extensions') ?? const ['dart'];
    final normalizedExtensions = [
      for (final ext in extensions)
        ext.startsWith('.') ? ext.substring(1) : ext,
    ];
    for (final ext in normalizedExtensions) {
      if (ext != 'dart') {
        warnings.add(
          'file_extensions: ".$ext" files are parsed as Dart source; '
          'only Dart is supported.',
        );
      }
    }

    final formatValue = _string(output, 'format');
    ReportFormat format;
    try {
      format = formatValue == null
          ? ReportFormat.console
          : ReportFormat.parse(formatValue);
    } on FormatException catch (e) {
      throw ConfigException('output.format: ${e.message}');
    }

    return L10nSweepConfig(
      projectRoot: root,
      translationsPath: normalizeRelative(
        _string(map, 'translations_path') ??
            detected.translationsPath ??
            'assets/translations',
      ),
      primaryLocale: _string(map, 'primary_locale') ?? detected.fallbackLocale,
      sourcePaths: [
        for (final s in _stringList(map, 'source_paths') ?? const ['lib'])
          normalizeRelative(s),
      ],
      fileExtensions: normalizedExtensions,
      excludedPaths: [
        for (final s in _stringList(map, 'excluded_paths') ?? const <String>[])
          normalizeRelative(s),
      ],
      excludedKeys: _stringList(map, 'excluded_keys') ?? const [],
      ignoredKeys: _stringList(map, 'ignored_keys') ?? const [],
      dynamicKeyPatterns: _stringList(map, 'dynamic_key_patterns') ?? const [],
      translationFunctions: _translationFunctions(map),
      output: OutputConfig(format: format, path: _string(output, 'path')),
      safety: SafetyConfig(
        createBackup: _bool(safety, 'create_backup') ?? true,
        backupPath: normalizeRelative(
          _string(safety, 'backup_path') ?? '.l10n_sweep/backups',
        ),
        requireConfirmation: _bool(safety, 'require_confirmation') ?? true,
        preserveUncertainKeys: _bool(safety, 'preserve_uncertain_keys') ?? true,
        allowUnresolvedReferences:
            _bool(safety, 'allow_unresolved_references') ?? false,
      ),
      cleanup: CleanupConfig(
        removeEmptyParents: _bool(cleanup, 'remove_empty_parents') ?? true,
      ),
      configFile: source,
    );
  }

  List<TranslationFunction> _translationFunctions(YamlMap map) {
    final value = map['translation_functions'];
    if (value == null) return const [];
    if (value is! YamlList) {
      throw ConfigException('translation_functions must be a list.');
    }
    final result = <TranslationFunction>[];
    for (final item in value) {
      if (item is String) {
        result.add(TranslationFunction(name: item));
        continue;
      }
      if (item is! YamlMap || item['name'] is! String) {
        throw ConfigException(
          'Each translation_functions entry needs a "name", for example '
          '{name: translate, key_argument: 0}.',
        );
      }
      final arg = item['key_argument'];
      if (arg == null || arg is int) {
        final position = (arg as int?) ?? 0;
        if (position < 0) {
          throw ConfigException('key_argument must not be negative.');
        }
        result.add(
          TranslationFunction(name: item['name'] as String, position: position),
        );
      } else if (arg is String) {
        result.add(
          TranslationFunction(name: item['name'] as String, namedArgument: arg),
        );
      } else {
        throw ConfigException(
          'key_argument must be an argument index or a named argument.',
        );
      }
    }
    return result;
  }

  static void _warnUnknown(
    YamlMap map,
    Set<String> known,
    String section,
    List<String> warnings,
  ) {
    for (final key in map.keys) {
      if (!known.contains(key)) {
        warnings.add('Unknown option "$key" in "$section" is ignored.');
      }
    }
  }

  static YamlMap? _map(YamlMap? map, String key) {
    final value = map?[key];
    if (value == null) return null;
    if (value is! YamlMap) throw ConfigException('"$key" must be a map.');
    return value;
  }

  static String? _string(YamlMap? map, String key) {
    final value = map?[key];
    if (value == null) return null;
    if (value is String) return value;
    if (value is num || value is bool) return value.toString();
    throw ConfigException('"$key" must be a string.');
  }

  static bool? _bool(YamlMap? map, String key) {
    final value = map?[key];
    if (value == null) return null;
    if (value is bool) return value;
    throw ConfigException('"$key" must be true or false.');
  }

  static List<String>? _stringList(YamlMap map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is String) return [value];
    if (value is! YamlList) throw ConfigException('"$key" must be a list.');
    return [
      for (final item in value)
        if (item is String || item is num)
          item.toString()
        else
          throw ConfigException('"$key" must only contain strings.'),
    ];
  }
}
