import '../configuration/l10n_sweep_config.dart';
import '../models/localization_key.dart';
import '../models/localization_usage.dart';
import '../models/source_location.dart';
import '../models/translation_file.dart';
import '../models/unused_key_result.dart';
import '../parsers/json_document.dart';
import '../parsers/translation_catalog.dart';
import 'dynamic_key_analyzer.dart';
import 'project_index.dart';

/// A translation call together with the keys it may reference.
class ResolvedSink {
  const ResolvedSink(this.sink, this.resolution);

  final SinkInfo sink;
  final KeyResolution resolution;
}

/// Output of [UnusedKeyDetector.classify].
class DetectionResult {
  const DetectionResult({
    required this.keys,
    required this.dynamicPatterns,
    required this.unresolved,
    required this.undefinedKeys,
  });

  final List<KeyClassification> keys;
  final Map<KeyPattern, List<SourceLocation>> dynamicPatterns;
  final List<UnresolvedReference> unresolved;
  final Map<String, List<SourceLocation>> undefinedKeys;
}

/// Decides, for every key in every locale file, whether it is used.
///
/// The rule throughout: a key is only [KeyStatus.unused] when nothing in
/// the scanned code could reference it.
class UnusedKeyDetector {
  const UnusedKeyDetector(this.config);

  final L10nSweepConfig config;

  static const _maxEvidence = 5;

  DetectionResult classify({
    required TranslationCatalog catalog,
    required List<ResolvedSink> sinks,
    required Set<String> weakLiterals,
  }) {
    // Collect evidence from translation calls.
    final staticKeys = <String, List<SourceLocation>>{};
    final codePatterns = <KeyPattern, List<SourceLocation>>{};
    final declaredPatterns = <KeyPattern, String>{
      for (final p in config.dynamicPatterns) p: 'matches dynamic_key_patterns',
    };
    final declaredLocations = <KeyPattern, List<SourceLocation>>{};
    final unresolved = <UnresolvedReference>[];
    for (final resolved in sinks) {
      final sink = resolved.sink;
      final r = resolved.resolution;
      for (final key in r.keys) {
        (staticKeys[key] ??= []).add(sink.location);
      }
      for (final pattern in r.patterns) {
        (codePatterns[pattern] ??= []).add(sink.location);
      }
      for (final glob in sink.annotation.patterns) {
        final pattern = KeyPattern.glob(glob);
        declaredPatterns[pattern] =
            'declared by a "// l10n_sweep:keys" comment';
        (declaredLocations[pattern] ??= []).add(sink.location);
      }
      if (r.unresolved.isNotEmpty) {
        unresolved.add(
          UnresolvedReference(
            location: sink.location,
            snippet: sink.snippet,
            reason: r.unresolved.join('; '),
            acknowledged: !sink.annotation.isEmpty,
          ),
        );
      }
    }
    final staticPrefixes = <String>{
      for (final key in staticKeys.keys) ...selfAndAncestors(key),
    };
    final blocking = config.safety.allowUnresolvedReferences
        ? 0
        : unresolved.where((u) => !u.acknowledged).length;

    // Gather every key across locales, primary first.
    final primary = catalog.primary;
    final order = <String>[];
    final locales = <String, List<String>>{};
    final entries = <String, List<TranslationEntry>>{};
    for (final file in catalog.files) {
      for (final entry in file.entries.values) {
        final key = entry.key.key;
        if (!locales.containsKey(key)) order.add(key);
        (locales[key] ??= []).add(file.locale);
        (entries[key] ??= []).add(entry);
      }
    }

    final classifications = <String, KeyClassification>{};
    for (final key in order) {
      final isGroup = entries[key]!.any((e) => e.key.isGroup);
      final children = {
        for (final e in entries[key]!)
          if (e.key.isGroup) ..._groupChildren(e),
      };
      final reasons = <String>[];
      final evidence = <SourceLocation>[];
      KeyStatus status;

      final excludedBy = _firstMatch(config.excludedKeyPatterns, key, children);
      final ignoredBy = _firstMatch(config.ignoredKeyPatterns, key, children);
      if (excludedBy != null) {
        status = KeyStatus.excluded;
        reasons.add('matches excluded_keys "${excludedBy.display}"');
      } else if (ignoredBy != null) {
        status = KeyStatus.used;
        reasons.add('matches ignored_keys "${ignoredBy.display}"');
      } else if (_staticallyUsed(key, staticKeys, staticPrefixes, evidence)) {
        status = KeyStatus.used;
        reasons.add('referenced by a translation call');
      } else if (_declaredUse(
        key,
        children,
        declaredPatterns,
        declaredLocations,
        reasons,
        evidence,
      )) {
        status = KeyStatus.used;
      } else if (_patternUse(key, children, codePatterns, reasons, evidence)) {
        status = KeyStatus.dynamicallyUsed;
      } else if (weakLiterals.contains(key)) {
        status = KeyStatus.potentiallyUnused;
        reasons.add(
          'the string "$key" appears in source code outside a translation '
          'call',
        );
      } else if (blocking > 0) {
        status = KeyStatus.potentiallyUnused;
        reasons.add(
          'no reference found, but $blocking translation '
          '${blocking == 1 ? 'call' : 'calls'} could not be resolved and '
          'may reference it',
        );
      } else {
        status = KeyStatus.unused;
        reasons.add('no reference found');
      }

      final inPrimary = primary != null && primary.entries.containsKey(key);
      classifications[key] = KeyClassification(
        key: key,
        status: status,
        reasons: reasons,
        locales: locales[key]!,
        inPrimary: inPrimary,
        isGroup: isGroup,
        evidence: evidence.take(_maxEvidence).toList(),
      );
    }

    _propagateLinks(classifications, entries);

    // Keys referenced in code that no locale defines.
    final undefined = <String, List<SourceLocation>>{};
    final knownPrefixes = <String>{
      for (final key in order) ...selfAndAncestors(key),
    };
    staticKeys.forEach((key, locations) {
      final definedOrInsideGroup = selfAndAncestors(
        key,
      ).any(classifications.containsKey);
      if (!definedOrInsideGroup && !knownPrefixes.contains(key)) {
        undefined[key] = locations;
      }
    });

    return DetectionResult(
      keys: [for (final key in order) classifications[key]!],
      dynamicPatterns: {...codePatterns, ...declaredLocations},
      unresolved: unresolved,
      undefinedKeys: undefined,
    );
  }

  static Iterable<String> _groupChildren(TranslationEntry entry) {
    final value = entry.member.value;
    if (value is! JsonObject) return const [];
    return value.members.map((m) => '${entry.key.key}.${m.name}');
  }

  static KeyPattern? _firstMatch(
    List<KeyPattern> patterns,
    String key,
    Set<String> children,
  ) {
    for (final p in patterns) {
      if (_patternCovers(p, key, children)) return p;
    }
    return null;
  }

  /// Whether [pattern] can produce [key], an ancestor of it (whose subtree
  /// includes [key]) or, for groups, one of its plural/gender forms.
  static bool _patternCovers(
    KeyPattern pattern,
    String key,
    Set<String> children,
  ) {
    for (final candidate in selfAndAncestors(key)) {
      if (pattern.matches(candidate)) return true;
    }
    return children.any(pattern.matches);
  }

  static bool _staticallyUsed(
    String key,
    Map<String, List<SourceLocation>> staticKeys,
    Set<String> staticPrefixes,
    List<SourceLocation> evidence,
  ) {
    var used = false;
    for (final candidate in selfAndAncestors(key)) {
      final locations = staticKeys[candidate];
      if (locations != null) {
        used = true;
        evidence.addAll(locations);
      }
    }
    if (!used && staticPrefixes.contains(key)) {
      // A translation call references a key nested under this one, such as
      // a single plural form of a group.
      used = true;
      staticKeys.forEach((k, locations) {
        if (k.startsWith('$key.')) evidence.addAll(locations);
      });
    }
    return used;
  }

  static bool _declaredUse(
    String key,
    Set<String> children,
    Map<KeyPattern, String> declared,
    Map<KeyPattern, List<SourceLocation>> locations,
    List<String> reasons,
    List<SourceLocation> evidence,
  ) {
    for (final entry in declared.entries) {
      if (_patternCovers(entry.key, key, children)) {
        reasons.add('${entry.value} ("${entry.key.display}")');
        evidence.addAll(locations[entry.key] ?? const []);
        return true;
      }
    }
    return false;
  }

  static bool _patternUse(
    String key,
    Set<String> children,
    Map<KeyPattern, List<SourceLocation>> patterns,
    List<String> reasons,
    List<SourceLocation> evidence,
  ) {
    var matched = false;
    for (final entry in patterns.entries) {
      if (_patternCovers(entry.key, key, children)) {
        if (!matched) {
          reasons.add('may be built at run time by "${entry.key.display}"');
        }
        matched = true;
        evidence.addAll(entry.value);
      }
    }
    return matched;
  }

  /// Raises the status of keys referenced through linked translations
  /// (`"@:other.key"`) to the status of the key that links to them.
  static void _propagateLinks(
    Map<String, KeyClassification> keys,
    Map<String, List<TranslationEntry>> entries,
  ) {
    // Index every key under itself and each of its ancestors, so a link to
    // `home` reaches `home.title` without scanning all keys.
    final byPrefix = <String, List<KeyClassification>>{};
    for (final k in keys.values) {
      for (final prefix in selfAndAncestors(k.key)) {
        (byPrefix[prefix] ??= []).add(k);
      }
    }
    // Worklist: statuses only ever increase, so this terminates.
    final queue = [
      for (final k in keys.values)
        if (k.status != KeyStatus.unused) k,
    ];
    while (queue.isNotEmpty) {
      final source = queue.removeLast();
      final level = source.status == KeyStatus.excluded
          ? KeyStatus.used
          : source.status;
      for (final entry in entries[source.key]!) {
        for (final link in entry.linkedKeys) {
          for (final target in byPrefix[link] ?? const <KeyClassification>[]) {
            if (target.status == KeyStatus.excluded ||
                target.status.rank >= level.rank) {
              continue;
            }
            target.status = level;
            target.reasons.insert(
              0,
              'linked from "${source.key}" (${source.status.id})',
            );
            queue.add(target);
          }
        }
      }
    }
  }
}
