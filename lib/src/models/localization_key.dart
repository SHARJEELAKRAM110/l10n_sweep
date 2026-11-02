/// A translatable unit inside a locale file.
///
/// A unit is either a leaf value (`"home.title": "Welcome"`) or a plural /
/// gender group such as `{"one": "1 item", "other": "{} items"}`, which
/// easy_localization resolves as a single key.
class LocalizationKey {
  LocalizationKey(this.segments, {this.isGroup = false})
    : key = segments.join('.');

  /// Dot-notation key, as passed to `tr()`.
  final String key;

  /// JSON object path. Differs from `key.split('.')` when a JSON member name
  /// itself contains a dot.
  final List<String> segments;

  /// Whether this unit is a plural or gender group.
  final bool isGroup;

  /// Whether [other] equals this key or is nested beneath it.
  bool isAncestorOrSelfOf(String other) =>
      other == key || other.startsWith('$key.');

  @override
  bool operator ==(Object other) =>
      other is LocalizationKey && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;
}

/// Returns `key` and each of its dot-separated ancestors, longest first.
///
/// `ancestorsOf('a.b.c')` yields `a.b.c`, `a.b`, `a`.
Iterable<String> selfAndAncestors(String key) sync* {
  var current = key;
  while (true) {
    yield current;
    final dot = current.lastIndexOf('.');
    if (dot <= 0) return;
    current = current.substring(0, dot);
  }
}
