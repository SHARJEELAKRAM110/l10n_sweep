import '../models/analysis_issue.dart';
import '../models/source_location.dart';
import 'key_expression.dart';

/// A parameter of an indexed function.
class ParameterInfo {
  const ParameterInfo({
    required this.name,
    required this.position,
    required this.isNamed,
    required this.defaultValue,
  });

  final String name;

  /// Index among positional parameters, or `null` for named parameters.
  final int? position;
  final bool isNamed;
  final KeyExpr? defaultValue;
}

/// A function, method, getter or constructor declaration.
class FunctionInfo {
  const FunctionInfo({
    required this.id,
    required this.name,
    required this.className,
    required this.constructorName,
    required this.isConstructor,
    required this.parameters,
    required this.returns,
  });

  /// Identifier used by [ParamRef.functionId].
  final String id;

  /// Simple name. For constructors, the class name.
  final String name;
  final String? className;

  /// `named` for `Foo.named(...)`, `null` for the unnamed constructor.
  final String? constructorName;
  final bool isConstructor;
  final List<ParameterInfo> parameters;

  /// Expressions this function can return.
  final List<KeyExpr> returns;

  ParameterInfo? parameter(String name) {
    for (final p in parameters) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// A top-level variable, field or getter.
class VariableInfo {
  const VariableInfo({
    required this.name,
    required this.className,
    required this.values,
    required this.isImmutable,
  });

  final String name;
  final String? className;

  /// `const`, or `final` with an initializer: assignments elsewhere to the
  /// same name cannot affect it. Getters are immutable too.
  final bool isImmutable;

  /// Initializer and getter bodies. Assignments are stored separately.
  final List<KeyExpr> values;
}

/// A call site with its arguments.
class InvocationInfo {
  const InvocationInfo({
    required this.name,
    required this.qualifier,
    required this.positional,
    required this.named,
  });

  /// Method, function or constructor name. For `Foo.named()` this is
  /// `named` with [qualifier] `Foo`. For `Foo()` it is `Foo`.
  final String name;

  /// Simple identifier the call is made on, if any.
  final String? qualifier;
  final List<KeyExpr> positional;
  final Map<String, KeyExpr> named;
}

/// What a `// l10n_sweep:` comment says about a translation call.
class SinkAnnotation {
  const SinkAnnotation({this.ignore = false, this.patterns = const []});

  static const none = SinkAnnotation();

  /// `// l10n_sweep:ignore` — the developer accepts an unresolved key.
  final bool ignore;

  /// `// l10n_sweep:keys onboarding.*, errors.*` — keys this call may use.
  final List<String> patterns;

  bool get isEmpty => !ignore && patterns.isEmpty;
}

/// A translation call (`'key'.tr()`, `tr('key')`, `context.plural(...)`,
/// or a configured translation function).
class SinkInfo {
  const SinkInfo({
    required this.key,
    required this.location,
    required this.snippet,
    required this.annotation,
  });

  final KeyExpr key;
  final SourceLocation location;
  final String snippet;
  final SinkAnnotation annotation;
}

/// Everything the analyzer learned from a single Dart file.
class FileIndex {
  FileIndex(this.path, {required this.isUsageSource});

  final String path;

  /// `false` for files under `excluded_paths`: their declarations and call
  /// arguments are indexed, but not their translation calls or literals.
  final bool isUsageSource;

  final List<FunctionInfo> functions = [];
  final List<VariableInfo> variables = [];

  /// Values assigned to non-local names (`name = value`, `x.name = value`),
  /// plus constructor parameters stored into fields (`this.name`).
  final Map<String, List<KeyExpr>> assignments = {};

  /// Same as [assignments], keyed by `Class#field`.
  final Map<String, List<KeyExpr>> memberAssignments = {};
  final List<InvocationInfo> invocations = [];

  /// Receivers of property accesses and method calls by member name, used
  /// to resolve `this` inside `extension on String`.
  final Map<String, List<KeyExpr>> receivers = {};

  /// Function names used as values (tear-offs), whose call sites are unknown.
  final Set<String> tearOffs = {};
  final Set<String> classNames = {};
  final List<SinkInfo> sinks = [];

  /// String literals outside variable initializers (usage files only).
  final Set<String> literals = {};

  /// String literals inside initializers, keyed by variable name.
  final Map<String, Set<String>> declaredLiterals = {};

  /// Identifiers referenced in usage files.
  final Set<String> referencedNames = {};
  final List<AnalysisIssue> issues = [];
}

/// The merged index of all scanned files.
class ProjectIndex {
  ProjectIndex(Iterable<FileIndex> files) {
    for (final file in files) {
      _add(file);
    }
  }

  final Map<String, FileIndex> files = {};
  final Map<String, List<FunctionInfo>> functionsById = {};
  final Map<String, List<FunctionInfo>> functionsByName = {};

  /// Constructors keyed by class name.
  final Map<String, List<FunctionInfo>> constructorsByClass = {};
  final Map<String, List<VariableInfo>> variablesByName = {};
  final Map<String, List<KeyExpr>> assignments = {};
  final Map<String, List<KeyExpr>> memberAssignments = {};
  final Map<String, List<InvocationInfo>> invocationsByName = {};
  final Map<String, List<KeyExpr>> receivers = {};
  final Set<String> tearOffs = {};
  final Set<String> classNames = {};
  final List<SinkInfo> sinks = [];
  final Set<String> literals = {};
  final Map<String, Set<String>> declaredLiterals = {};
  final Set<String> referencedNames = {};

  void _add(FileIndex file) {
    files[file.path] = file;
    for (final fn in file.functions) {
      (functionsById[fn.id] ??= []).add(fn);
      if (fn.isConstructor) {
        (constructorsByClass[fn.className!] ??= []).add(fn);
      } else {
        (functionsByName[fn.name] ??= []).add(fn);
      }
    }
    for (final v in file.variables) {
      (variablesByName[v.name] ??= []).add(v);
    }
    _mergeLists(assignments, file.assignments);
    _mergeLists(memberAssignments, file.memberAssignments);
    _mergeLists(receivers, file.receivers);
    for (final call in file.invocations) {
      (invocationsByName[call.name] ??= []).add(call);
    }
    tearOffs.addAll(file.tearOffs);
    classNames.addAll(file.classNames);
    sinks.addAll(file.sinks);
    literals.addAll(file.literals);
    file.declaredLiterals.forEach((name, values) {
      (declaredLiterals[name] ??= {}).addAll(values);
    });
    referencedNames.addAll(file.referencedNames);
  }

  static void _mergeLists<T>(
    Map<String, List<T>> target,
    Map<String, List<T>> source,
  ) {
    source.forEach((key, values) {
      (target[key] ??= []).addAll(values);
    });
  }
}
