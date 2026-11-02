import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/syntactic_entity.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import '../configuration/l10n_sweep_config.dart';
import '../models/analysis_issue.dart';
import '../models/source_location.dart';
import 'key_expression.dart';
import 'project_index.dart';

/// Builds a [FileIndex] from Dart source using the analyzer's parser.
///
/// The analysis is syntactic: no type resolution or package resolution is
/// needed, so it works on any project without running `pub get`. Data flow
/// is tracked through local variables, constants, fields, getters, function
/// parameters, constructor parameters and collection literals by name. Where
/// the source does not determine a value, an [UnknownExpr] is recorded so the
/// resolver can treat the reference conservatively.
class DartAstAnalyzer {
  const DartAstAnalyzer({this.translationFunctions = const []});

  /// Translation methods provided by easy_localization.
  static const translationMethods = {'tr', 'plural', 'trExists'};

  final List<TranslationFunction> translationFunctions;

  FileIndex analyze({
    required String path,
    required String content,
    required bool isUsageSource,
  }) {
    final index = FileIndex(path, isUsageSource: isUsageSource);
    final result = parseString(content: content, throwIfDiagnostics: false);
    if (result.errors.isNotEmpty) {
      final first = result.errors.first;
      final loc = result.lineInfo.getLocation(first.offset);
      index.issues.add(
        AnalysisIssue.warning(
          'dart_syntax_error',
          'Dart syntax error (${result.errors.length} total): ${first.message}. '
              'References in the unparsable region may be missed.',
          at: SourceLocation(path, loc.lineNumber, loc.columnNumber),
        ),
      );
    }
    result.unit.accept(
      _IndexingVisitor(index, content, result.lineInfo, translationFunctions),
    );
    return index;
  }
}

/// How a name is bound inside a function body.
sealed class _Binding {
  const _Binding();
}

class _LocalVariable extends _Binding {
  const _LocalVariable(this.declaration);
  final VariableDeclaration declaration;
}

class _LoopVariable extends _Binding {
  const _LoopVariable(this.iterable);
  final Expression iterable;
}

class _Parameter extends _Binding {
  const _Parameter(this.functionId);
  final String functionId;
}

class _ClosureParameter extends _Binding {
  const _ClosureParameter(this.function, this.name);
  final FunctionExpression function;
  final String name;
}

class _Opaque extends _Binding {
  const _Opaque(this.reason);
  final String reason;
}

class _IndexingVisitor extends RecursiveAstVisitor<void> {
  _IndexingVisitor(
    this.index,
    this.content,
    this.lineInfo,
    this.translationFunctions,
  ) : lines = content.split('\n');

  final FileIndex index;
  final String content;
  final List<String> lines;
  final LineInfo lineInfo;
  final List<TranslationFunction> translationFunctions;

  final Map<VariableDeclaration, KeyExpr> _localValues = {};
  final Set<VariableDeclaration> _inProgress = {};
  final Map<AstNode, Map<String, List<AssignmentExpression>>> _assignments = {};

  bool get _usage => index.isUsageSource;

  static const _elementCallbacks = {
    'map',
    'forEach',
    'where',
    'expand',
    'any',
    'every',
    'firstWhere',
    'lastWhere',
    'singleWhere',
    'takeWhile',
    'skipWhile',
    'indexWhere',
    'lastIndexWhere',
    'removeWhere',
    'retainWhere',
    'firstWhereOrNull',
    'lastWhereOrNull',
    'singleWhereOrNull',
    'sortedBy',
    'groupBy',
  };
  static const _indexedCallbacks = {
    'mapIndexed',
    'forEachIndexed',
    'whereIndexed',
    'expandIndexed',
  };
  static const _elementAccessors = {
    'first',
    'last',
    'single',
    'firstOrNull',
    'lastOrNull',
    'singleOrNull',
    'values',
  };
  static const _elementMethods = {
    'elementAt',
    'elementAtOrNull',
    'firstWhere',
    'lastWhere',
    'singleWhere',
    'firstWhereOrNull',
    'lastWhereOrNull',
    'singleWhereOrNull',
    'reduce',
  };
  static const _identityMethods = {'toString', 'trim'};

  // ---------------------------------------------------------------------
  // Declarations
  // ---------------------------------------------------------------------

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    _addClassName(node);
    super.visitClassDeclaration(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    _addClassName(node);
    super.visitMixinDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    _addClassName(node);
    super.visitEnumDeclaration(node);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    _addClassName(node);
    super.visitExtensionDeclaration(node);
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    _addClassName(node);
    super.visitExtensionTypeDeclaration(node);
  }

  void _addClassName(AstNode node) {
    final name = _typeDeclarationName(node);
    if (name != null) index.classNames.add(name);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    for (final v in node.variables.variables) {
      index.variables.add(
        VariableInfo(
          name: v.name.lexeme,
          className: null,
          values: [if (v.initializer != null) convert(v.initializer)],
          isImmutable: _isImmutable(v),
        ),
      );
    }
    super.visitTopLevelVariableDeclaration(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    final className = _enclosingTypeName(node);
    for (final v in node.fields.variables) {
      index.variables.add(
        VariableInfo(
          name: v.name.lexeme,
          className: className,
          values: [if (v.initializer != null) convert(v.initializer)],
          isImmutable: _isImmutable(v),
        ),
      );
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final name = node.name.lexeme;
    final returns = _returnsOf(node.functionExpression.body);
    if (node.isGetter) {
      index.variables.add(
        VariableInfo(
          name: name,
          className: null,
          values: returns,
          isImmutable: true,
        ),
      );
    } else if (!node.isSetter) {
      index.functions.add(
        FunctionInfo(
          id: _functionIdOf(node),
          name: name,
          className: null,
          constructorName: null,
          isConstructor: false,
          parameters: _parametersOf(node.functionExpression.parameters),
          returns: returns,
        ),
      );
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final name = node.name.lexeme;
    final className = _enclosingTypeName(node);
    final returns = _returnsOf(node.body);
    if (node.isGetter) {
      index.variables.add(
        VariableInfo(
          name: name,
          className: className,
          values: returns,
          isImmutable: true,
        ),
      );
    } else if (!node.isSetter && !node.isOperator) {
      index.functions.add(
        FunctionInfo(
          id: _functionIdOf(node),
          name: name,
          className: className,
          constructorName: null,
          isConstructor: false,
          parameters: _parametersOf(node.parameters),
          returns: returns,
        ),
      );
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    final className = _enclosingTypeName(node);
    if (className != null) {
      final id = _functionIdOf(node);
      index.functions.add(
        FunctionInfo(
          id: id,
          name: className,
          className: className,
          constructorName: node.name?.lexeme,
          isConstructor: true,
          parameters: _parametersOf(node.parameters),
          returns: const [],
        ),
      );
      for (final p in node.parameters.parameters) {
        final name = p.name?.lexeme;
        if (name != null && _isFieldFormal(p)) {
          (index.memberAssignments['$className#$name'] ??= []).add(
            ParamRef(id, name),
          );
        }
      }
      for (final init in node.initializers) {
        if (init is ConstructorFieldInitializer) {
          (index.memberAssignments['$className#${init.fieldName.name}'] ??= [])
              .add(convert(init.expression));
        }
      }
    }
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final lhs = node.leftHandSide;
    String? name;
    if (lhs is SimpleIdentifier) {
      if (_bindingOf(lhs, lhs.name) == null) name = lhs.name;
    } else if (lhs is PrefixedIdentifier) {
      name = lhs.identifier.name;
    } else if (lhs is PropertyAccess) {
      name = lhs.propertyName.name;
    }
    if (name != null) {
      final value = _assignedValue(node);
      if (value != null) (index.assignments[name] ??= []).add(value);
    }
    super.visitAssignmentExpression(node);
  }

  KeyExpr? _assignedValue(AssignmentExpression node) {
    final op = node.operator.lexeme;
    if (op == '=' || op == '??=') return convert(node.rightHandSide);
    if (op == '+=') {
      return TemplateExpr([
        const UnknownExpr('compound assignment'),
        convert(node.rightHandSide),
      ]);
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Invocations and translation calls
  // ---------------------------------------------------------------------

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    final target = node.target;
    index.invocations.add(
      _invocation(name, _qualifierOf(target), node.argumentList),
    );
    if (target != null && !node.isCascaded) _recordReceiver(name, target);
    if (_usage) {
      if (DartAstAnalyzer.translationMethods.contains(name)) {
        _translationMethodSink(node);
      }
      _customSink(node, name, _qualifierOf(target), node.argumentList);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final typeName = _simpleTypeName(node.constructorName.type);
    final ctorName = node.constructorName.name?.name;
    index.invocations.add(
      _invocation(
        ctorName ?? typeName,
        ctorName == null ? null : typeName,
        node.argumentList,
      ),
    );
    if (_usage) {
      _customSink(
        node,
        ctorName ?? typeName,
        ctorName == null ? null : typeName,
        node.argumentList,
      );
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final target = node.target;
    if (target != null && !node.isCascaded) {
      _recordReceiver(node.propertyName.name, target);
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    _recordReceiver(node.identifier.name, node.prefix);
    super.visitPrefixedIdentifier(node);
  }

  void _recordReceiver(String member, Expression target) {
    if (target is StringLiteral ||
        target is SimpleIdentifier ||
        target is PrefixedIdentifier ||
        target is PropertyAccess) {
      (index.receivers[member] ??= []).add(convert(target));
    }
  }

  InvocationInfo _invocation(
    String name,
    String? qualifier,
    ArgumentList arguments,
  ) {
    if (arguments.arguments.isEmpty) {
      return InvocationInfo(
        name: name,
        qualifier: qualifier,
        positional: const [],
        named: const {},
      );
    }
    final positional = <KeyExpr>[];
    final named = <String, KeyExpr>{};
    for (final arg in arguments.arguments) {
      if (arg is NamedArgument) {
        named[arg.name.lexeme] = convert(arg.argumentExpression);
      } else if (arg is Expression) {
        positional.add(convert(arg));
      }
    }
    return InvocationInfo(
      name: name,
      qualifier: qualifier,
      positional: positional,
      named: named,
    );
  }

  /// Handles `'key'.tr()`, `tr('key')`, `context.tr('key')`,
  /// `'key'.plural(n)`, `plural('key', n)`, `Text('key').tr()` and `tr()`
  /// on `this` inside `extension on String`.
  void _translationMethodSink(MethodInvocation node) {
    if (node.isCascaded) return;
    final name = node.methodName.name;
    final positional = node.argumentList.arguments
        .whereType<Expression>()
        .toList();
    final keyInArguments = name == 'plural'
        ? positional.length >= 2
        : positional.isNotEmpty;
    final target = node.target;
    KeyExpr key;
    if (keyInArguments) {
      key = convert(positional.first);
      _warnIfTranslated(positional.first);
    } else if (target != null) {
      final keyExpression = _textWidgetKey(target) ?? target;
      key = convert(keyExpression);
      _warnIfTranslated(keyExpression);
    } else {
      final member = _stringExtensionMember(node);
      if (member == null) return;
      key = ThisRef(member);
    }
    _addSink(node, key);
  }

  /// Flags `'key'.tr().tr()`: the outer call looks up translated text,
  /// which is almost certainly a mistake. It cannot reference a key, so it
  /// does not affect classification.
  void _warnIfTranslated(Expression expression) {
    var inner = expression;
    while (inner is ParenthesizedExpression) {
      inner = inner.expression;
    }
    if (inner is MethodInvocation &&
        DartAstAnalyzer.translationMethods.contains(inner.methodName.name)) {
      final loc = lineInfo.getLocation(inner.end);
      index.issues.add(
        AnalysisIssue.warning(
          'double_translation',
          'The result of ${inner.methodName.name}() is translated again; '
              'the outer call looks up translated text, not a key',
          at: SourceLocation(index.path, loc.lineNumber, loc.columnNumber),
        ),
      );
    }
  }

  void _customSink(
    AstNode node,
    String name,
    String? qualifier,
    ArgumentList arguments,
  ) {
    for (final fn in translationFunctions) {
      final matches =
          fn.name == name ||
          (qualifier != null && fn.name == '$qualifier.$name');
      if (!matches) continue;
      Expression? arg;
      if (fn.namedArgument != null) {
        for (final a in arguments.arguments) {
          if (a is NamedArgument && a.name.lexeme == fn.namedArgument) {
            arg = a.argumentExpression;
          }
        }
      } else {
        final positional = arguments.arguments.whereType<Expression>().toList();
        if (fn.position < positional.length) arg = positional[fn.position];
      }
      if (arg != null) _addSink(node, convert(arg));
    }
  }

  /// `Text('key')` used as the receiver of easy_localization's
  /// `Text.tr()` extension.
  Expression? _textWidgetKey(Expression target) {
    ArgumentList? args;
    if (target is InstanceCreationExpression &&
        target.constructorName.name == null &&
        _simpleTypeName(target.constructorName.type) == 'Text') {
      args = target.argumentList;
    } else if (target is MethodInvocation &&
        target.target == null &&
        target.methodName.name == 'Text') {
      args = target.argumentList;
    }
    if (args == null) return null;
    return args.arguments.whereType<Expression>().firstOrNull;
  }

  void _addSink(AstNode node, KeyExpr key) {
    final loc = lineInfo.getLocation(node.offset);
    index.sinks.add(
      SinkInfo(
        key: key,
        location: SourceLocation(index.path, loc.lineNumber, loc.columnNumber),
        snippet: _snippet(node),
        annotation: _annotationFor(loc.lineNumber),
      ),
    );
  }

  static final _annotationPattern = RegExp(
    r'//\s*l10n_sweep:\s*(ignore|keys)\b(.*)$',
  );

  SinkAnnotation _annotationFor(int line) {
    for (final candidate in [line, line - 1]) {
      if (candidate < 1 || candidate > lines.length) continue;
      final match = _annotationPattern.firstMatch(
        lines[candidate - 1].trimRight(),
      );
      if (match == null) continue;
      if (match[1] == 'ignore') return const SinkAnnotation(ignore: true);
      final patterns = match[2]!
          .split(RegExp(r'[,\s]+'))
          .where((s) => s.isNotEmpty)
          .toList();
      return SinkAnnotation(patterns: patterns);
    }
    return SinkAnnotation.none;
  }

  String _snippet(AstNode node) {
    final text = content
        .substring(node.offset, node.end)
        .replaceAll(RegExp(r'\s+'), ' ');
    return text.length > 120 ? '${text.substring(0, 117)}...' : text;
  }

  // ---------------------------------------------------------------------
  // Literals and references (usage files only)
  // ---------------------------------------------------------------------

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _recordLiteral(node, node.value);
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    final value = node.stringValue;
    if (value != null) _recordLiteral(node, value);
    super.visitAdjacentStrings(node);
  }

  void _recordLiteral(AstNode node, String value) {
    if (value.isEmpty || value.length > 512) return;
    AstNode? current = node.parent;
    while (current != null) {
      if (current is Directive) return;
      if (current is VariableDeclaration) {
        (index.declaredLiterals[current.name.lexeme] ??= {}).add(value);
        return;
      }
      if (current is Statement ||
          current is ClassMember ||
          current is CompilationUnitMember) {
        break;
      }
      current = current.parent;
    }
    if (_usage) index.literals.add(value);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_usage) index.referencedNames.add(node.name);
    final parent = node.parent;
    final effective = parent is PrefixedIdentifier && parent.identifier == node
        ? parent
        : node;
    final context = effective.parent;
    if (context is ArgumentList ||
        context is NamedArgument ||
        context is ListLiteral ||
        context is VariableDeclaration ||
        context is ReturnStatement ||
        context is ExpressionFunctionBody ||
        (context is AssignmentExpression &&
            context.rightHandSide == effective)) {
      index.tearOffs.add(node.name);
    }
    super.visitSimpleIdentifier(node);
  }

  // ---------------------------------------------------------------------
  // Expression conversion
  // ---------------------------------------------------------------------

  KeyExpr convert(Expression? e) {
    if (e == null) return UnionExpr.empty;
    switch (e) {
      case SimpleStringLiteral():
        return LiteralExpr(e.value);
      case AdjacentStrings():
        return TemplateExpr([for (final s in e.strings) convert(s)]);
      case StringInterpolation():
        return TemplateExpr([
          for (final element in e.elements)
            switch (element) {
              InterpolationString() => LiteralExpr(element.value),
              InterpolationExpression() => convert(element.expression),
            },
        ]);
      case ParenthesizedExpression():
        return convert(e.expression);
      case ConditionalExpression():
        return UnionExpr([
          convert(e.thenExpression),
          convert(e.elseExpression),
        ]);
      case BinaryExpression():
        final op = e.operator.lexeme;
        if (op == '+') {
          return TemplateExpr([
            convert(e.leftOperand),
            convert(e.rightOperand),
          ]);
        }
        if (op == '??') {
          return UnionExpr([convert(e.leftOperand), convert(e.rightOperand)]);
        }
        return UnknownExpr('result of the "$op" operator');
      case SwitchExpression():
        return UnionExpr([for (final c in e.cases) convert(c.expression)]);
      case AsExpression():
        return convert(e.expression);
      case PostfixExpression() when e.operator.lexeme == '!':
        return convert(e.operand);
      case AwaitExpression():
        return convert(e.expression);
      case CascadeExpression():
        return convert(e.target);
      case NullLiteral():
        return UnionExpr.empty;
      case SimpleIdentifier():
        return _identifier(e);
      case PrefixedIdentifier():
        return _prefixedMember(e.prefix, e.identifier.name);
      case PropertyAccess():
        final target = e.target;
        if (target == null) return const UnknownExpr('cascade property');
        return _memberOf(target, e.propertyName.name);
      case IndexExpression():
        final target = e.target;
        if (target == null) return const UnknownExpr('cascade index');
        return ElementsOfExpr(convert(target));
      case MethodInvocation():
        return _invocationValue(e);
      case ListLiteral():
        final (values, _) = _collectionElements(e.elements);
        return CollectionExpr(values);
      case SetOrMapLiteral():
        final (values, keys) = _collectionElements(e.elements);
        return CollectionExpr(values, keys);
      case ThisExpression():
        final member = _stringExtensionMember(e);
        return member == null
            ? const UnknownExpr('"this" outside a String extension')
            : ThisRef(member);
      case FunctionExpression():
        return const UnknownExpr('function value');
      case IntegerLiteral() || DoubleLiteral() || BooleanLiteral():
        return const UnknownExpr('non-string literal');
      default:
        return UnknownExpr('unsupported expression ${_describeNode(e)}');
    }
  }

  static String _describeNode(AstNode node) =>
      node.runtimeType.toString().replaceAll('Impl', '');

  (List<KeyExpr>, List<KeyExpr>) _collectionElements(
    NodeList<CollectionElement> elements,
  ) {
    final values = <KeyExpr>[];
    final keys = <KeyExpr>[];
    void add(CollectionElement element) {
      switch (element) {
        case Expression():
          values.add(convert(element));
        case MapLiteralEntry():
          keys.add(convert(element.key));
          values.add(convert(element.value));
        case SpreadElement():
          final inner = convert(element.expression);
          values.add(ElementsOfExpr(inner));
          keys.add(MapKeysOfExpr(inner));
        case IfElement():
          add(element.thenElement);
          final otherwise = element.elseElement;
          if (otherwise != null) add(otherwise);
        case ForElement():
          add(element.body);
        case NullAwareElement():
          values.add(convert(element.value));
        default:
          values.add(
            UnknownExpr('collection element ${_describeNode(element)}'),
          );
      }
    }

    elements.forEach(add);
    return (values, keys);
  }

  KeyExpr _identifier(SimpleIdentifier id) {
    final binding = _bindingOf(id, id.name);
    if (binding != null) return _valueOf(binding, id.name);
    return SymbolRef(id.name, enclosingClass: _enclosingTypeName(id));
  }

  KeyExpr _prefixedMember(SimpleIdentifier prefix, String name) {
    if (_elementAccessors.contains(name)) {
      return ElementsOfExpr(convert(prefix));
    }
    if (name == 'keys') return MapKeysOfExpr(convert(prefix));
    if (_bindingOf(prefix, prefix.name) != null) return SymbolRef(name);
    return SymbolRef(
      name,
      qualifier: prefix.name,
      enclosingClass: _enclosingTypeName(prefix),
    );
  }

  KeyExpr _memberOf(Expression target, String name) {
    if (_elementAccessors.contains(name)) {
      return ElementsOfExpr(convert(target));
    }
    if (name == 'keys') return MapKeysOfExpr(convert(target));
    if (target is ThisExpression) {
      return SymbolRef(name, enclosingClass: _enclosingTypeName(target));
    }
    return SymbolRef(name, qualifier: _qualifierOf(target));
  }

  KeyExpr _invocationValue(MethodInvocation node) {
    final name = node.methodName.name;
    final target = node.target;
    if (target != null) {
      if (_elementMethods.contains(name)) {
        return ElementsOfExpr(convert(target));
      }
      if (_identityMethods.contains(name)) return convert(target);
      // Translated text cannot name a key. Translating it again is reported
      // by the sink itself (see _translationMethodSink).
      if (DartAstAnalyzer.translationMethods.contains(name)) {
        return UnionExpr.empty;
      }
      final qualifier =
          target is SimpleIdentifier && _bindingOf(target, target.name) != null
          ? null
          : _qualifierOf(target);
      return CallRef(name, qualifier: qualifier);
    }
    if (DartAstAnalyzer.translationMethods.contains(name)) {
      return UnionExpr.empty;
    }
    return CallRef(name, enclosingClass: _enclosingTypeName(node));
  }

  String? _qualifierOf(Expression? target) => switch (target) {
    SimpleIdentifier() => target.name,
    PrefixedIdentifier() => target.identifier.name,
    _ => null,
  };

  // ---------------------------------------------------------------------
  // Scopes
  // ---------------------------------------------------------------------

  /// Finds the local declaration of [name] visible from [from], if any.
  _Binding? _bindingOf(AstNode from, String name) {
    AstNode? node = from.parent;
    while (node != null) {
      switch (node) {
        case Block():
          final found = _searchStatements(node.statements, name);
          if (found != null) return found;
        case SwitchMember():
          final found = _searchStatements(node.statements, name);
          if (found != null) return found;
        case ForStatement():
          final found = _searchForParts(node.forLoopParts, name);
          if (found != null) return found;
        case ForElement():
          final found = _searchForParts(node.forLoopParts, name);
          if (found != null) return found;
        case CatchClause():
          if (node.exceptionParameter?.name.lexeme == name ||
              node.stackTraceParameter?.name.lexeme == name) {
            return const _Opaque('catch clause variable');
          }
        case FunctionExpression():
          if (_declaresParameter(node.parameters, name)) {
            final parent = node.parent;
            if (parent is FunctionDeclaration) {
              return _Parameter(_functionIdOf(parent));
            }
            return _ClosureParameter(node, name);
          }
        case MethodDeclaration():
          if (_declaresParameter(node.parameters, name)) {
            return _Parameter(_functionIdOf(node));
          }
        case ConstructorDeclaration():
          if (_declaresParameter(node.parameters, name)) {
            return _Parameter(_functionIdOf(node));
          }
        case ClassDeclaration() ||
            MixinDeclaration() ||
            EnumDeclaration() ||
            ExtensionDeclaration() ||
            ExtensionTypeDeclaration() ||
            CompilationUnit():
          return null;
        default:
          break;
      }
      node = node.parent;
    }
    return null;
  }

  _Binding? _searchStatements(NodeList<Statement> statements, String name) {
    for (final s in statements) {
      if (s is VariableDeclarationStatement) {
        for (final v in s.variables.variables) {
          if (v.name.lexeme == name) return _LocalVariable(v);
        }
      } else if (s is FunctionDeclarationStatement) {
        if (s.functionDeclaration.name.lexeme == name) {
          return const _Opaque('local function');
        }
      } else if (s is PatternVariableDeclarationStatement) {
        if (_patternDeclares(s.declaration.pattern, name)) {
          return const _Opaque('destructured variable');
        }
      }
    }
    return null;
  }

  _Binding? _searchForParts(ForLoopParts parts, String name) {
    switch (parts) {
      case ForEachPartsWithDeclaration():
        if (parts.loopVariable.name.lexeme == name) {
          return _LoopVariable(parts.iterable);
        }
      case ForPartsWithDeclarations():
        for (final v in parts.variables.variables) {
          if (v.name.lexeme == name) return _LocalVariable(v);
        }
      case ForEachPartsWithPattern():
        if (_patternDeclares(parts.pattern, name)) {
          return const _Opaque('destructured loop variable');
        }
      default:
        break;
    }
    return null;
  }

  bool _patternDeclares(DartPattern pattern, String name) =>
      RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(pattern.toSource());

  bool _declaresParameter(FormalParameterList? list, String name) =>
      list != null && list.parameters.any((p) => p.name?.lexeme == name);

  KeyExpr _valueOf(_Binding binding, String name) => switch (binding) {
    _LocalVariable(:final declaration) => _localValue(declaration),
    _LoopVariable(:final iterable) => ElementsOfExpr(convert(iterable)),
    _Parameter(:final functionId) => ParamRef(functionId, name),
    _ClosureParameter(:final function) => _closureParameter(function, name),
    _Opaque(:final reason) => UnknownExpr('$reason "$name"'),
  };

  KeyExpr _localValue(VariableDeclaration declaration) {
    final cached = _localValues[declaration];
    if (cached != null) return cached;
    if (!_inProgress.add(declaration)) {
      return const UnknownExpr('self-referencing variable');
    }
    final name = declaration.name.lexeme;
    final values = <KeyExpr>[];
    final initializer = declaration.initializer;
    if (initializer != null) values.add(convert(initializer));
    final scope = _enclosingBody(declaration);
    if (scope != null) {
      for (final assignment
          in _assignmentsIn(scope)[name] ?? const <AssignmentExpression>[]) {
        final value = _assignedValue(assignment);
        values.add(
          value ??
              UnknownExpr('"$name" changed by ${assignment.operator.lexeme}'),
        );
      }
    }
    final result = switch (values.length) {
      0 => UnknownExpr('"$name" has no visible value'),
      1 => values.single,
      _ => UnionExpr(values),
    };
    _inProgress.remove(declaration);
    _localValues[declaration] = result;
    return result;
  }

  AstNode? _enclosingBody(AstNode node) {
    AstNode? current = node.parent;
    while (current != null) {
      if (current is FunctionBody) return current;
      if (current is CompilationUnit) return null;
      current = current.parent;
    }
    return null;
  }

  Map<String, List<AssignmentExpression>> _assignmentsIn(AstNode body) =>
      _assignments.putIfAbsent(body, () {
        final collector = _AssignmentCollector();
        body.accept(collector);
        return collector.byName;
      });

  KeyExpr _closureParameter(FunctionExpression function, String name) {
    final params = function.parameters?.parameters ?? const <FormalParameter>[];
    var position = 0;
    int? index;
    for (final p in params) {
      if (p.isNamed) continue;
      if (p.name?.lexeme == name) index = position;
      position++;
    }
    final argumentList = function.parent;
    final call = argumentList?.parent;
    if (index != null &&
        argumentList is ArgumentList &&
        call is MethodInvocation &&
        call.target != null) {
      final method = call.methodName.name;
      final target = convert(call.target);
      if (method == 'forEach' && params.length == 2) {
        return index == 0 ? MapKeysOfExpr(target) : ElementsOfExpr(target);
      }
      if (_elementCallbacks.contains(method) && index == 0) {
        return ElementsOfExpr(target);
      }
      if (_indexedCallbacks.contains(method) && index == 1) {
        return ElementsOfExpr(target);
      }
      if (method == 'fold' && index == 1) return ElementsOfExpr(target);
      if (method == 'reduce') return ElementsOfExpr(target);
    }
    return UnknownExpr('closure parameter "$name"');
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  List<KeyExpr> _returnsOf(FunctionBody body) {
    if (body is ExpressionFunctionBody) return [convert(body.expression)];
    if (body is BlockFunctionBody) {
      final collector = _ReturnCollector();
      body.block.accept(collector);
      return [for (final r in collector.returns) convert(r)];
    }
    return const [];
  }

  List<ParameterInfo> _parametersOf(FormalParameterList? list) {
    if (list == null) return const [];
    final result = <ParameterInfo>[];
    var position = 0;
    for (final p in list.parameters) {
      final name = p.name?.lexeme;
      final isNamed = p.isNamed;
      final index = isNamed ? null : position++;
      if (name == null) continue;
      final defaultValue = _defaultValueOf(p);
      result.add(
        ParameterInfo(
          name: name,
          position: index,
          isNamed: isNamed,
          defaultValue: defaultValue == null ? null : convert(defaultValue),
        ),
      );
    }
    return result;
  }

  /// Finds a parameter's default value without depending on how a given
  /// analyzer version models it: it is the expression after `=` or `:`.
  static Expression? _defaultValueOf(FormalParameter parameter) {
    Expression? search(AstNode node, int depth) {
      SyntacticEntity? previous;
      for (final child in node.childEntities) {
        if (child is Expression &&
            previous is Token &&
            (previous.lexeme == '=' || previous.lexeme == ':')) {
          return child;
        }
        if (child is AstNode &&
            child is! Expression &&
            child is! Annotation &&
            child is! TypeAnnotation &&
            depth < 2) {
          final found = search(child, depth + 1);
          if (found != null) return found;
        }
        previous = child;
      }
      return null;
    }

    return search(parameter, 0);
  }

  static bool _isImmutable(VariableDeclaration v) =>
      v.isConst || (v.isFinal && v.initializer != null);

  static bool _isFieldFormal(FormalParameter p) =>
      p is FieldFormalParameter ||
      p.childEntities.any((c) => c is FieldFormalParameter);

  String _functionIdOf(AstNode declaration) {
    switch (declaration) {
      case ConstructorDeclaration():
        final className = _enclosingTypeName(declaration) ?? '';
        return '$className#ctor:${declaration.name?.lexeme ?? ''}';
      case MethodDeclaration():
        final className = _enclosingTypeName(declaration) ?? '';
        return '$className#${declaration.name.lexeme}';
      case FunctionDeclaration():
        final name = declaration.name.lexeme;
        if (declaration.parent is CompilationUnit) return '#$name';
        return '${index.path}@${declaration.offset}#$name';
      default:
        return '${index.path}@${declaration.offset}';
    }
  }

  String? _enclosingTypeName(AstNode node) {
    AstNode? current = node.parent;
    while (current != null) {
      final name = _typeDeclarationName(current);
      if (name != null) return name;
      if (current is CompilationUnit) return null;
      current = current.parent;
    }
    return null;
  }

  /// Reads a type declaration's name from tokens, which stays stable across
  /// analyzer versions.
  static String? _typeDeclarationName(AstNode node) => switch (node) {
    ClassDeclaration() => node.classKeyword.next?.lexeme,
    MixinDeclaration() => node.name.lexeme,
    EnumDeclaration() => node.enumKeyword.next?.lexeme,
    ExtensionDeclaration() => node.name?.lexeme ?? '<extension>',
    ExtensionTypeDeclaration() => node.typeKeyword.next?.lexeme,
    _ => null,
  };

  /// If [node] is inside a member of an `extension on String`, returns the
  /// member name.
  String? _stringExtensionMember(AstNode node) {
    String? member;
    AstNode? current = node.parent;
    while (current != null) {
      if (current is MethodDeclaration) member ??= current.name.lexeme;
      if (current is ExtensionDeclaration) {
        return member != null && _extendsString(current) ? member : null;
      }
      if (current is CompilationUnit) return null;
      current = current.parent;
    }
    return null;
  }

  static bool _extendsString(ExtensionDeclaration node) {
    Token? token = node.extensionKeyword;
    while (token != null && !token.isEof && token.lexeme != '{') {
      if (token.lexeme == 'on') return token.next?.lexeme == 'String';
      token = token.next;
    }
    return false;
  }

  static String _simpleTypeName(NamedType type) {
    final source = type.toSource().split('<').first.replaceAll('?', '');
    return source.split('.').last.trim();
  }
}

class _AssignmentCollector extends RecursiveAstVisitor<void> {
  final Map<String, List<AssignmentExpression>> byName = {};

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final lhs = node.leftHandSide;
    if (lhs is SimpleIdentifier) (byName[lhs.name] ??= []).add(node);
    super.visitAssignmentExpression(node);
  }
}

class _ReturnCollector extends RecursiveAstVisitor<void> {
  final List<Expression> returns = [];

  @override
  void visitReturnStatement(ReturnStatement node) {
    final expression = node.expression;
    if (expression != null) returns.add(expression);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}

  @override
  void visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {}
}
