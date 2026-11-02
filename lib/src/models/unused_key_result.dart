import 'source_location.dart';

/// How confidently a key is known to be used.
enum KeyStatus {
  /// Referenced by a statically known translation call, linked from a used
  /// translation, or marked as used in configuration.
  used('used'),

  /// May be referenced by a translation call whose key is built at run time,
  /// such as `'home.$section'.tr()`.
  dynamicallyUsed('dynamic'),

  /// No translation call references the key, but the analyzer cannot rule
  /// out a reference (the key string appears elsewhere in the code, or some
  /// translation calls could not be resolved).
  potentiallyUnused('potentially_unused'),

  /// No reference was found and every translation call was resolved.
  unused('unused'),

  /// Matched by `excluded_keys`; never reported or removed.
  excluded('excluded');

  const KeyStatus(this.id);

  /// Identifier used in reports.
  final String id;

  /// Ordering used when propagating usage through linked translations.
  int get rank => switch (this) {
    unused => 0,
    potentiallyUnused => 1,
    dynamicallyUsed => 2,
    used || excluded => 3,
  };
}

/// The verdict for one translation key.
class KeyClassification {
  KeyClassification({
    required this.key,
    required this.status,
    required this.reasons,
    required this.locales,
    required this.inPrimary,
    required this.isGroup,
    required this.evidence,
  });

  final String key;
  KeyStatus status;

  /// Human readable explanations, most important first.
  final List<String> reasons;

  /// Locales whose file contains this key.
  final List<String> locales;

  /// Whether the primary locale defines this key.
  final bool inPrimary;

  /// Whether this is a plural or gender group.
  final bool isGroup;

  /// Where the key (or a pattern matching it) is referenced. Capped.
  final List<SourceLocation> evidence;

  /// Whether `clean --yes` may remove this key.
  bool get isSafeToRemove => status == KeyStatus.unused && inPrimary;

  Map<String, Object?> toJson() => {
    'key': key,
    'status': status.id,
    'in_primary_locale': inPrimary,
    if (isGroup) 'group': true,
    'locales': locales,
    'reasons': reasons,
    if (evidence.isNotEmpty)
      'references': [for (final e in evidence) e.toJson()],
  };
}
