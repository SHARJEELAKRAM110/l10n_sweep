/// A compact, AST-free description of how a string value is produced.
///
/// The Dart indexer converts every expression that might flow into a
/// translation call into a [KeyExpr]. Keeping this intermediate form instead
/// of whole syntax trees keeps memory low on large projects and makes each
/// file's index independent, so files can be re-indexed one at a time.
library;

sealed class KeyExpr {
  const KeyExpr();
}

/// A string literal, for example `'home.title'`.
final class LiteralExpr extends KeyExpr {
  const LiteralExpr(this.value);

  final String value;
}

/// Concatenation of parts: string interpolation, `+` or adjacent strings.
final class TemplateExpr extends KeyExpr {
  const TemplateExpr(this.parts);

  final List<KeyExpr> parts;
}

/// One of several values: `a ? b : c`, `a ?? b`, switch expressions, or a
/// variable that is assigned more than once.
final class UnionExpr extends KeyExpr {
  const UnionExpr(this.options);

  static const empty = UnionExpr([]);

  final List<KeyExpr> options;
}

/// A list, set or map literal. For maps, [elements] holds the values.
final class CollectionExpr extends KeyExpr {
  const CollectionExpr(this.elements, [this.mapKeys = const []]);

  final List<KeyExpr> elements;
  final List<KeyExpr> mapKeys;
}

/// Any element of a collection: `list.first`, `list[i]`, `map[k]`,
/// `map.values`, a for-in loop variable or a closure parameter of `map()`.
final class ElementsOfExpr extends KeyExpr {
  const ElementsOfExpr(this.collection);

  final KeyExpr collection;
}

/// Any key of a map literal: `map.keys`.
final class MapKeysOfExpr extends KeyExpr {
  const MapKeysOfExpr(this.collection);

  final KeyExpr collection;
}

/// A reference to a variable, field or getter that is not a local variable.
final class SymbolRef extends KeyExpr {
  const SymbolRef(this.name, {this.qualifier, this.enclosingClass});

  final String name;

  /// `LocaleKeys` in `LocaleKeys.title`, or `widget` in `widget.titleKey`.
  final String? qualifier;

  /// Class, mixin, enum or extension containing the reference.
  final String? enclosingClass;
}

/// A parameter of a function, method or constructor. Its values come from
/// the arguments at every call site plus any default value.
final class ParamRef extends KeyExpr {
  const ParamRef(this.functionId, this.parameterName);

  final String functionId;
  final String parameterName;
}

/// The return value of a function, method or getter call.
final class CallRef extends KeyExpr {
  const CallRef(this.name, {this.qualifier, this.enclosingClass});

  final String name;
  final String? qualifier;
  final String? enclosingClass;
}

/// `this` inside an `extension on String` member: every receiver the member
/// is called on, such as `'home.title'` in `'home.title'.localized`.
final class ThisRef extends KeyExpr {
  const ThisRef(this.memberName);

  final String memberName;
}

/// A value the indexer cannot describe.
final class UnknownExpr extends KeyExpr {
  const UnknownExpr(this.reason);

  final String reason;
}
