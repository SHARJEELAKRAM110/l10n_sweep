import 'source_location.dart';

/// A regular-expression description of keys produced by dynamic code such as
/// `'home.$section'.tr()`.
class KeyPattern {
  KeyPattern(this.source, this.display) : regex = RegExp('^(?:$source)\$');

  /// Builds a pattern from a user-facing glob where `*` matches any run of
  /// characters (including dots).
  factory KeyPattern.glob(String glob) =>
      KeyPattern(glob.split('*').map(RegExp.escape).join('.*'), glob);

  /// Regular expression body without anchors.
  final String source;

  /// Human readable form, with `*` for dynamic parts.
  final String display;
  final RegExp regex;

  bool matches(String key) => regex.hasMatch(key);

  @override
  bool operator ==(Object other) =>
      other is KeyPattern && other.source == source;

  @override
  int get hashCode => source.hashCode;

  @override
  String toString() => display;
}

/// How a translation call refers to its key.
enum UsageKind {
  /// The key is a compile-time known string, possibly via constants.
  staticKey,

  /// The key is built at run time, but its shape is partially known.
  dynamicPattern,

  /// The key cannot be determined at all.
  unresolved,
}

/// One key (or key pattern) referenced by a translation call.
class LocalizationUsage {
  const LocalizationUsage.staticKey(this.key, this.location, this.snippet)
    : kind = UsageKind.staticKey,
      pattern = null,
      reason = null;

  const LocalizationUsage.dynamicPattern(
    KeyPattern this.pattern,
    this.location,
    this.snippet,
  ) : kind = UsageKind.dynamicPattern,
      key = null,
      reason = null;

  const LocalizationUsage.unresolved(this.reason, this.location, this.snippet)
    : kind = UsageKind.unresolved,
      key = null,
      pattern = null;

  final UsageKind kind;
  final String? key;
  final KeyPattern? pattern;
  final String? reason;
  final SourceLocation location;

  /// Source of the translation call, shortened for display.
  final String snippet;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    if (key != null) 'key': key,
    if (pattern != null) 'pattern': pattern!.display,
    if (reason != null) 'reason': reason,
    'location': location.toJson(),
    'snippet': snippet,
  };
}

/// A translation call whose key could not be determined statically.
class UnresolvedReference {
  const UnresolvedReference({
    required this.location,
    required this.snippet,
    required this.reason,
    required this.acknowledged,
  });

  final SourceLocation location;
  final String snippet;
  final String reason;

  /// Whether a `// l10n_sweep:ignore` or `// l10n_sweep:keys` comment covers
  /// this call.
  final bool acknowledged;

  Map<String, Object?> toJson() => {
    'location': location.toJson(),
    'snippet': snippet,
    'reason': reason,
    'acknowledged': acknowledged,
  };
}
