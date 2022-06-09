import 'dart:isolate';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:collection/collection.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_lint/src/type_checker.dart';

const _providerBase = TypeChecker.fromRuntime(ProviderBase);
const _family = TypeChecker.fromRuntime(Family);
const _providerOrFamily = TypeChecker.any([_providerBase, _family]);

const _widget = TypeChecker.fromName('Widget', packageName: 'flutter');

const _widgetRef =
    TypeChecker.fromName('WidgetRef', packageName: 'flutter_riverpod');

const _consumerWidget = TypeChecker.fromName(
  'ConsumerWidget',
  packageName: 'flutter_riverpod',
);
const _consumerState = TypeChecker.fromName(
  'ConsumerState',
  packageName: 'flutter_riverpod',
);
const _ref = TypeChecker.fromRuntime(Ref);

void main(List<String> args, SendPort sendPort) {
  startPlugin(sendPort, _RiverpodLint());
}

class _RiverpodLint extends PluginBase {
  @override
  Iterable<Lint> getLints(ResolvedUnitResult unit) {
    final visitor = RiverpodVisitor(unit);
    unit.unit.accept(visitor);

    return visitor.lints;
  }
}

mixin _ProviderCreationVisitor on RecursiveAstVisitor<void> {
  /// The initialization of a provider was found
  void visitProviderCreation(AstNode providerNode);

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    super.visitFunctionExpressionInvocation(node);

    if (node.isProviderCreation ?? false) {
      visitProviderCreation(node);
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    super.visitInstanceCreationExpression(node);

    final createdType = node.staticType?.element;
    if (createdType != null &&
        _providerOrFamily.isAssignableFrom(createdType)) {
      visitProviderCreation(node);
    }
  }
}

class RefLifecycleInvocation {
  RefLifecycleInvocation._(this.invocation);

  // Whether the invocation is inside or ouside the build method of a provider/widget
  // Null if unknown
  static bool? _isWithinBuild(AstNode node) {
    var hasFoundFunctionExpression = false;

    for (final parent in node.parents) {
      if (parent is FunctionExpression) {
        if (hasFoundFunctionExpression) return false;

        if (parent.isWidgetBuilder ?? false) {
          return true;
        }

        // Since anonymous functions could be the build of a provider,
        // we need to check their ancestors for more information.
        hasFoundFunctionExpression = true;
      }
      if (parent is InstanceCreationExpression) {
        return parent.isProviderCreation;
      }
      if (parent is FunctionExpressionInvocation) {
        return parent.isProviderCreation;
      }
      if (parent is MethodDeclaration) {
        if (hasFoundFunctionExpression || parent.name.name != 'build') {
          return false;
        }

        final classElement = parent.parents
            .whereType<ClassDeclaration>()
            .firstOrNull
            ?.declaredElement;

        if (classElement == null) return null;
        return _consumerWidget.isAssignableFrom(classElement) ||
            _consumerState.isAssignableFrom(classElement);
      }
    }
    return null;
  }

  final MethodInvocation invocation;

  late final bool? isWithinBuild = _isWithinBuild(invocation);
}

mixin _RefLifecycleVisitor on RecursiveAstVisitor<void> {
  /// A Ref/WidgetRef method was invoked. It isn't guaranted to be watch/listen/read
  void visitRefInvocation(RefLifecycleInvocation node);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);
    final targetType = node.target?.staticType?.element;
    if (targetType == null) return;

    if (_ref.isAssignableFrom(targetType) ||
        _widgetRef.isAssignableFrom(targetType)) {
      visitRefInvocation(RefLifecycleInvocation._(node));
    }
  }
}

class RiverpodVisitor extends RecursiveAstVisitor<void>
    with _RefLifecycleVisitor, _ProviderCreationVisitor {
  RiverpodVisitor(this.unit);

  final ResolvedUnitResult unit;
  final lints = <Lint>[];

  @override
  void visitRefInvocation(RefLifecycleInvocation node) {
    switch (node.invocation.methodName.name) {
      case 'read':
        if (node.isWithinBuild ?? false) {
          lints.add(
            Lint(
              code: 'riverpod_avoid_read_inside_build',
              message:
                  'Avoid using ref.read inside the build method of widgets/providers.',
              location: unit.lintLocationFromOffset(
                node.invocation.offset,
                length: node.invocation.length,
              ),
            ),
          );
        }
        break;
      case 'watch':
        if (node.isWithinBuild == false) {
          lints.add(
            Lint(
              code: 'riverpod_avoid_watch_outside_build',
              message:
                  'Avoid using ref.watch outside the build method of widgets/providers.',
              location: unit.lintLocationFromOffset(
                node.invocation.offset,
                length: node.invocation.length,
              ),
            ),
          );
        }
        break;
      default:
    }
  }

  @override
  void visitProviderCreation(AstNode providerNode) {
    _checkValidProviderDeclaration(providerNode);
    _checkProviderDependencies(providerNode);
  }

  void _checkProviderDependencies(AstNode providerNode) {
    if (providerNode is InstanceCreationExpression) {
      final dependenciesExpression = providerNode.argumentList.arguments
          .whereType<NamedExpression>()
          .firstWhereOrNull((e) => e.name.label.name == 'dependencies')
          ?.expression;

      if (dependenciesExpression is ListLiteral) {
        print(
            'Provider creation $providerNode ----- dependencies ${dependenciesExpression.elements.map((e) => e.runtimeType)}');
      }
    }
  }

  void _checkValidProviderDeclaration(AstNode providerNode) {
    final declaration =
        providerNode.parents.whereType<VariableDeclaration>().firstOrNull;
    final variable = declaration?.declaredElement;

    if (variable == null) {
      lints.add(
        Lint(
          code: 'riverpod_final_provider',
          message: 'Providers should always be declared as final',
          location: unit.lintLocationFromOffset(
            providerNode.offset,
            length: providerNode.length,
          ),
        ),
      );
      return;
    }

    final isGlobal = declaration!.parents.any((element) =>
        element is TopLevelVariableDeclaration ||
        (element is FieldDeclaration && element.isStatic));

    if (!isGlobal) {
      lints.add(
        Lint(
          code: 'riverpod_avoid_dynamic_provider',
          message:
              'Providers should be either top level variables or static properties',
          location: unit.lintLocationFromOffset(
            variable.nameOffset,
            length: variable.nameLength,
          ),
        ),
      );
    }

    if (!variable.isFinal) {
      lints.add(
        Lint(
          code: 'riverpod_final_provider',
          message: 'Providers should always be declared as final',
          location: unit.lintLocationFromOffset(
            variable.nameOffset,
            length: variable.nameLength,
          ),
        ),
      );
    }
  }
}

extension on AstNode {
  Iterable<AstNode> get parents sync* {
    for (var node = parent; node != null; node = node.parent) {
      yield node;
    }
  }
}

VariableDeclaration? findProviderDeclaration(AstNode node) {}

extension on FunctionExpressionInvocation {
  /// Null if unknown
  bool? get isProviderCreation {
    final returnType = staticType?.element;
    if (returnType == null) return null;

    final function = this.function;

    return _providerOrFamily.isAssignableFrom(returnType) &&
        function is PropertyAccess &&
        (function.propertyName.name == 'autoDispose' ||
            function.propertyName.name == 'family');
  }
}

extension on FunctionExpression {
  /// Null if unknown
  bool? get isWidgetBuilder {
    final returnType = declaredElement?.returnType.element;
    if (returnType == null) return null;

    return _widget.isAssignableFrom(returnType);
  }
}

extension on InstanceCreationExpression {
  /// Null if unknown
  bool? get isProviderCreation {
    final type = staticType?.element;
    if (type == null) return null;

    return _providerOrFamily.isAssignableFrom(type);
  }
}