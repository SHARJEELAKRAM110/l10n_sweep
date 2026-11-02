import '../models/localization_usage.dart';
import 'key_expression.dart';
import 'project_index.dart';

/// The possible values of a key expression.
class KeyResolution {
  KeyResolution({
    Set<String>? keys,
    Set<KeyPattern>? patterns,
    List<String>? unresolved,
  }) : keys = keys ?? {},
       patterns = patterns ?? {},
       unresolved = unresolved ?? [];

  /// Exact keys the expression can produce.
  final Set<String> keys;

  /// Shapes of keys built at run time.
  final Set<KeyPattern> patterns;

  /// Why some values could not be determined. Non-empty means the
  /// expression may produce keys that are not described by [keys] or
  /// [patterns].
  final List<String> unresolved;

  bool get isEmpty => keys.isEmpty && patterns.isEmpty && unresolved.isEmpty;

  bool sameAs(KeyResolution other) =>
      keys.length == other.keys.length &&
      patterns.length == other.patterns.length &&
      unresolved.length == other.unresolved.length &&
      keys.containsAll(other.keys) &&
      patterns.containsAll(other.patterns) &&
      unresolved.toSet().containsAll(other.unresolved);

  void addAll(KeyResolution other) {
    keys.addAll(other.keys);
    patterns.addAll(other.patterns);
    for (final reason in other.unresolved) {
      if (!unresolved.contains(reason)) unresolved.add(reason);
    }
  }
}

/// Evaluates [KeyExpr]s against a [ProjectIndex].
///
/// Evaluation over-approximates: when several declarations share a name,
/// all of them contribute values. Over-approximating the set of used keys is
/// the safe direction, because it can only keep keys, never delete them.
/// Whenever a value cannot be described, the result carries an
/// `unresolved` reason instead of silently producing nothing.
class KeyResolver {
  KeyResolver(this.index);

  final ProjectIndex index;

  static const _maxDepth = 1000;
  static const _maxIterations = 8;
  static const _maxFiniteCombinations = 256;
  static const _maxAlternatives = 200;

  /// Minimum number of literal characters a dynamic key must contain to be
  /// treated as a pattern. Shorter shapes like `'$a.$b'` match nearly every
  /// key and are reported as unresolved instead.
  static const minimumPatternAnchor = 2;

  // References form a graph that is often cyclic (a field passed to a
  // constructor whose parameter is stored in a field of the same name).
  // Each strongly connected component is solved by Kleene iteration at its
  // root: back-edges see the value the target produced in the previous pass,
  // and the root repeats the pass until no handed-out value changed. Results
  // are cached; entries from a superseded pass are discarded.
  final Map<Object, KeyResolution> _cache = {};
  final Map<Object, int> _cachedAt = {};
  final List<(Object, int)> _cacheLog = [];
  final Map<Object, int> _active = {};
  final Map<Object, KeyResolution> _lastValue = {};
  final Set<Object> _handedOut = {};
  Set<int> _hits = {};
  bool _unstable = false;
  int _clock = 0;

  KeyResolution resolve(KeyExpr expr) => _eval(expr);

  KeyResolution _eval(KeyExpr expr) {
    switch (expr) {
      case LiteralExpr(:final value):
        return KeyResolution(keys: {value});
      case TemplateExpr(:final parts):
        return _template(parts);
      case UnionExpr(:final options):
        final result = KeyResolution();
        for (final o in options) {
          result.addAll(_eval(o));
        }
        return result;
      case CollectionExpr():
        return KeyResolution(unresolved: ['a collection is used as a key']);
      case ElementsOfExpr(:final collection):
        return _evalAll(_elements(collection));
      case MapKeysOfExpr(:final collection):
        return _evalAll(_mapKeys(collection));
      case UnknownExpr(:final reason):
        return KeyResolution(unresolved: [reason]);
      case SymbolRef() || ParamRef() || CallRef() || ThisRef():
        return _reference(expr);
    }
  }

  KeyResolution _evalAll(Iterable<KeyExpr> exprs) {
    final result = KeyResolution();
    for (final e in exprs) {
      result.addAll(_eval(e));
    }
    return result;
  }

  KeyResolution _reference(KeyExpr ref) {
    final key = _cacheKey(ref);
    final cached = _cache[key];
    if (cached != null) return cached;
    final activeAt = _active[key];
    if (activeAt != null) {
      _hits.add(activeAt);
      _handedOut.add(key);
      return _lastValue[key] ?? KeyResolution();
    }
    final position = _active.length;
    if (position >= _maxDepth) {
      return KeyResolution(unresolved: ['reference chain is too deep']);
    }
    _active[key] = position;
    final started = ++_clock;
    final outerHits = _hits;
    final outerUnstable = _unstable;
    var hits = <int>{};
    var lowest = position + 1;
    KeyResolution result;
    var passes = 0;
    while (true) {
      _hits = <int>{};
      _unstable = false;
      result = _evalAll(_definitions(ref));
      hits = _hits;
      if (_handedOut.remove(key) &&
          !(_lastValue[key] ?? KeyResolution()).sameAs(result)) {
        _unstable = true;
      }
      _lastValue[key] = result;
      lowest = hits.isEmpty
          ? position + 1
          : hits.reduce((a, b) => a < b ? a : b);
      // Not part of a cycle, or part of one rooted further out: done.
      if (lowest != position || !_unstable) break;
      // Root of a cycle whose values are still changing: run another pass.
      _invalidateSince(started);
      if (++passes >= _maxIterations) {
        result.unresolved.add('a recursive value could not be determined');
        _unstable = false;
        break;
      }
    }
    _active.remove(key);
    final partOfOuterCycle = lowest < position;
    if (!partOfOuterCycle) _lastValue.remove(key);
    final time = ++_clock;
    _cache[key] = result;
    _cachedAt[key] = time;
    _cacheLog.add((key, time));
    _hits = outerHits..addAll(hits.where((i) => i < position));
    _unstable = outerUnstable || (partOfOuterCycle && _unstable);
    return result;
  }

  /// Drops cache entries created after [time].
  void _invalidateSince(int time) {
    while (_cacheLog.isNotEmpty && _cacheLog.last.$2 > time) {
      final (key, created) = _cacheLog.removeLast();
      if (_cachedAt[key] == created) {
        _cache.remove(key);
        _cachedAt.remove(key);
      }
    }
  }

  Object _cacheKey(KeyExpr ref) => switch (ref) {
    SymbolRef(:final name, :final qualifier, :final enclosingClass) =>
      'S|$name|$qualifier|$enclosingClass',
    ParamRef(:final functionId, :final parameterName) =>
      'P|$functionId|$parameterName',
    CallRef(:final name, :final qualifier, :final enclosingClass) =>
      'C|$name|$qualifier|$enclosingClass',
    ThisRef(:final memberName) => 'T|$memberName',
    _ => ref,
  };

  /// The expressions a reference can evaluate to.
  List<KeyExpr> _definitions(KeyExpr ref) {
    switch (ref) {
      case SymbolRef(:final name, :final qualifier, :final enclosingClass):
        return _symbolDefinitions(name, qualifier, enclosingClass);
      case ParamRef(:final functionId, :final parameterName):
        return _parameterDefinitions(functionId, parameterName);
      case CallRef(:final name, :final qualifier, :final enclosingClass):
        return _callDefinitions(name, qualifier, enclosingClass);
      case ThisRef(:final memberName):
        return index.receivers[memberName] ?? const [];
      default:
        return [ref];
    }
  }

  List<KeyExpr> _symbolDefinitions(
    String name,
    String? qualifier,
    String? enclosingClass,
  ) {
    var candidates = index.variablesByName[name] ?? const <VariableInfo>[];
    final preferredClass =
        qualifier != null && index.classNames.contains(qualifier)
        ? qualifier
        : (qualifier == null ? enclosingClass : null);
    if (preferredClass != null) {
      final inClass = candidates
          .where((v) => v.className == preferredClass)
          .toList();
      if (inClass.isNotEmpty) candidates = inClass;
    }
    final values = <KeyExpr>[];
    final classes = <String?>{};
    for (final v in candidates) {
      values.addAll(v.values);
      classes.add(v.className);
    }
    for (final className in classes) {
      if (className == null) continue;
      values.addAll(index.memberAssignments['$className#$name'] ?? const []);
    }
    // `const` and initialized `final` declarations cannot be reassigned, so
    // assignments to other members of the same name are irrelevant.
    if (candidates.isEmpty || candidates.any((v) => !v.isImmutable)) {
      values.addAll(index.assignments[name] ?? const []);
    }
    if (values.isNotEmpty) return values;
    if (candidates.isNotEmpty) {
      return [UnknownExpr('no value is assigned to "$name" in scanned code')];
    }
    final shown = qualifier == null ? name : '$qualifier.$name';
    if (index.functionsByName.containsKey(name)) {
      return [UnknownExpr('"$shown" refers to a function')];
    }
    return [UnknownExpr('"$shown" is not declared in scanned code')];
  }

  List<KeyExpr> _parameterDefinitions(String functionId, String paramName) {
    final functions = index.functionsById[functionId];
    if (functions == null || functions.isEmpty) {
      return [UnknownExpr('parameter "$paramName" of an unknown function')];
    }
    final values = <KeyExpr>[];
    for (final fn in functions) {
      final param = fn.parameter(paramName);
      if (param == null) continue;
      final defaultValue = param.defaultValue;
      if (defaultValue != null) values.add(defaultValue);
      if (!fn.isConstructor && index.tearOffs.contains(fn.name)) {
        values.add(
          UnknownExpr(
            '"${fn.name}" is passed as a function value, so its arguments '
            'are unknown',
          ),
        );
      }
      var calls = 0;
      for (final call in _callSites(fn)) {
        calls++;
        final KeyExpr? arg = param.isNamed
            ? call.named[param.name]
            : (param.position! < call.positional.length
                  ? call.positional[param.position!]
                  : null);
        if (arg != null) values.add(arg);
      }
      if (calls == 0) {
        // Framework callbacks such as build() or onGenerateRoute() are
        // called from outside the scanned code, so no call sites does not
        // mean no values.
        values.add(
          UnknownExpr(
            'no call to "${fn.isConstructor ? fn.className : fn.name}" was '
            'found, so the value of "$paramName" is unknown',
          ),
        );
      }
    }
    return values;
  }

  Iterable<InvocationInfo> _callSites(FunctionInfo fn) {
    if (!fn.isConstructor) {
      return index.invocationsByName[fn.name] ?? const [];
    }
    final className = fn.className!;
    final ctorName = fn.constructorName;
    if (ctorName == null) {
      return [
        ...?index.invocationsByName[className],
        ...?index.invocationsByName['new']?.where(
          (c) => c.qualifier == className,
        ),
      ];
    }
    return (index.invocationsByName[ctorName] ?? const []).where(
      (c) => c.qualifier == className,
    );
  }

  List<KeyExpr> _callDefinitions(
    String name,
    String? qualifier,
    String? enclosingClass,
  ) {
    var functions = index.functionsByName[name] ?? const <FunctionInfo>[];
    final preferredClass =
        qualifier != null && index.classNames.contains(qualifier)
        ? qualifier
        : (qualifier == null ? enclosingClass : null);
    if (preferredClass != null) {
      final inClass = functions
          .where((f) => f.className == preferredClass)
          .toList();
      if (inClass.isNotEmpty) functions = inClass;
    }
    final values = <KeyExpr>[for (final f in functions) ...f.returns];
    if (values.isNotEmpty) return values;
    final shown = qualifier == null ? '$name()' : '$qualifier.$name()';
    if (functions.isNotEmpty) {
      return [UnknownExpr('the return value of $shown is not a known string')];
    }
    return [UnknownExpr('the return value of $shown is unknown')];
  }

  List<KeyExpr> _elements(KeyExpr collection) =>
      _collectionMembers(collection, keys: false, seen: {});

  List<KeyExpr> _mapKeys(KeyExpr collection) =>
      _collectionMembers(collection, keys: true, seen: {});

  List<KeyExpr> _collectionMembers(
    KeyExpr collection, {
    required bool keys,
    required Set<Object> seen,
  }) {
    switch (collection) {
      case CollectionExpr(:final elements, :final mapKeys):
        return keys ? mapKeys : elements;
      case UnionExpr(:final options):
        return [
          for (final o in options)
            ..._collectionMembers(o, keys: keys, seen: seen),
        ];
      case ElementsOfExpr(collection: final inner):
        return [
          for (final e in _collectionMembers(inner, keys: false, seen: seen))
            ..._collectionMembers(e, keys: keys, seen: seen),
        ];
      case MapKeysOfExpr(collection: final inner):
        return [
          for (final e in _collectionMembers(inner, keys: true, seen: seen))
            ..._collectionMembers(e, keys: keys, seen: seen),
        ];
      case SymbolRef() || ParamRef() || CallRef() || ThisRef():
        final cacheKey = _cacheKey(collection);
        if (!seen.add(cacheKey)) return const [];
        if (seen.length > _maxDepth) {
          return const [UnknownExpr('collection reference chain is too deep')];
        }
        return [
          for (final d in _definitions(collection))
            ..._collectionMembers(d, keys: keys, seen: seen),
        ];
      case UnknownExpr():
        return [collection];
      case LiteralExpr() || TemplateExpr():
        return const [UnknownExpr('a string is used as a collection')];
    }
  }

  KeyResolution _template(List<KeyExpr> parts) {
    final resolved = [for (final p in parts) _eval(p)];
    // A part with no possible values means the whole key never occurs.
    for (final r in resolved) {
      if (r.isEmpty) return KeyResolution();
    }

    final allFinite = resolved.every(
      (r) => r.patterns.isEmpty && r.unresolved.isEmpty,
    );
    if (allFinite) {
      var combinations = 1;
      for (final r in resolved) {
        combinations *= r.keys.length;
        if (combinations > _maxFiniteCombinations) break;
      }
      if (combinations <= _maxFiniteCombinations) {
        var keys = <String>{''};
        for (final r in resolved) {
          keys = {
            for (final prefix in keys)
              for (final k in r.keys) '$prefix$k',
          };
        }
        return KeyResolution(keys: keys);
      }
    }

    final regex = StringBuffer();
    final display = StringBuffer();
    var anchor = 0;
    final reasons = <String>[];
    for (final r in resolved) {
      reasons.addAll(r.unresolved);
      final alternatives = [
        for (final k in r.keys) RegExp.escape(k),
        for (final p in r.patterns) p.source,
      ];
      final wildcard =
          r.unresolved.isNotEmpty || alternatives.length > _maxAlternatives;
      if (wildcard) {
        regex.write('.*');
        display.write('*');
      } else if (alternatives.length == 1 && r.patterns.isEmpty) {
        final literal = r.keys.single;
        regex.write(RegExp.escape(literal));
        display.write(literal);
        anchor += literal.length;
      } else {
        regex.write('(?:${alternatives.join('|')})');
        final shown = [...r.keys, ...r.patterns.map((p) => p.display)];
        display.write(
          shown.length == 1 ? shown.single : '{${shown.join('|')}}',
        );
        if (r.patterns.isEmpty) {
          anchor += r.keys.map((k) => k.length).reduce((a, b) => a < b ? a : b);
        }
      }
    }

    if (anchor < minimumPatternAnchor) {
      return KeyResolution(
        unresolved: [
          if (reasons.isEmpty) 'key is built entirely at run time',
          ...reasons.map((r) => 'key is built at run time ($r)'),
        ],
      );
    }
    return KeyResolution(
      patterns: {KeyPattern(regex.toString(), display.toString())},
    );
  }
}
