import 'package:l10n_sweep/l10n_sweep.dart';
import 'package:test/test.dart';

import '../helpers.dart';

const _specJson = '''
{
  "app_name": "My Application",
  "home": {
    "title": "Welcome",
    "description": "Welcome to our application"
  },
  "profile": {
    "title": "My Profile",
    "edit_button": "Edit Profile"
  },
  "unused_message": "This message is never used"
}
''';

void main() {
  group('static references', () {
    test('detects the README example', () {
      final report = analyzeMemory(
        dart: {
          'lib/main.dart': '''
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Column(children: [
    Text('app_name'.tr()),
    Text('home.title'.tr()),
    Text('profile.title'.tr()),
  ]);
}
''',
        },
        json: enJson(_specJson),
      );
      expect(report.unusedKeys.map((k) => k.key), [
        'home.description',
        'profile.edit_button',
        'unused_message',
      ]);
      expect(keysWith(report, KeyStatus.used), {
        'app_name',
        'home.title',
        'profile.title',
      });
      expect(report.unresolvedReferences, isEmpty);
    });

    test('supports every easy_localization call form', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
import 'package:easy_localization/easy_localization.dart' as easy;
void f(BuildContext context, int n) {
  'k1'.tr();
  'k2'.tr(args: ['John']);
  'k3'.tr(namedArgs: {'name': 'John'});
  'k4'.tr(gender: 'male');
  tr('k5');
  context.tr('k6');
  easy.tr('k7', args: ['a']);
  'k8'.plural(n);
  plural('k9', n);
  context.plural('k10', n, args: ['x']);
  Text('k11').tr();
  const Text('k12').tr();
  trExists('k13');
}
''',
        },
        json: enJson('''
{"k1":"","k2":"","k3":"","k4":{"male":"","female":""},"k5":"","k6":"",
 "k7":"","k8":{"one":"","other":""},"k9":"","k10":"","k11":"","k12":"",
 "k13":"","k14":""}
'''),
      );
      expect(report.unusedKeys.map((k) => k.key), ['k14']);
      expect(report.keys.where((k) => k.isGroup).map((k) => k.key), [
        'k4',
        'k8',
      ]);
    });

    test('a call to a single plural form keeps the whole group', () {
      final report = analyzeMemory(
        dart: {'lib/a.dart': "f() => 'items.one'.tr();"},
        json: enJson('{"items": {"one": "1", "other": "n"}, "x": ""}'),
      );
      expect(statusOf(report, 'items'), KeyStatus.used);
      expect(statusOf(report, 'x'), KeyStatus.unused);
    });
  });

  group('constants and collections', () {
    test('follows constants, fields and getters', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
const titleKey = 'home.title';
class Keys {
  static const description = 'home.description';
  String get edit => 'profile.edit_button';
}
f(Keys keys) {
  titleKey.tr();
  Keys.description.tr();
  keys.edit.tr();
}
''',
        },
        json: enJson(_specJson),
      );
      expect(keysWith(report, KeyStatus.used), {
        'home.title',
        'home.description',
        'profile.edit_button',
      });
      expect(keysWith(report, KeyStatus.unused), {
        'app_name',
        'profile.title',
        'unused_message',
      });
    });

    test('resolves generated LocaleKeys in excluded paths', () {
      final report = analyzeMemory(
        excludedPaths: ['lib/generated'],
        dart: {
          'lib/generated/locale_keys.g.dart': '''
abstract class LocaleKeys {
  static const app_name = 'app_name';
  static const home_title = 'home.title';
  static const unused_message = 'unused_message';
}
''',
          'lib/main.dart': '''
f() {
  LocaleKeys.home_title.tr();
  tr(LocaleKeys.app_name);
}
''',
        },
        json: enJson(_specJson),
      );
      expect(statusOf(report, 'home.title'), KeyStatus.used);
      expect(statusOf(report, 'app_name'), KeyStatus.used);
      // Declared in the generated file but never referenced.
      expect(statusOf(report, 'unused_message'), KeyStatus.unused);
    });

    test('treats every element of a referenced collection as used', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
const keys = ['home.title', 'home.description'];
const labels = {Tab.home: 'profile.title', Tab.profile: 'profile.edit_button'};
const others = ['app_name'];
f(Tab tab) {
  Text(keys.first.tr());
  Text(labels[tab]!.tr());
  for (final k in others) {
    k.tr();
  }
}
''',
        },
        json: enJson(_specJson),
      );
      expect(report.unusedKeys.map((k) => k.key), ['unused_message']);
    });

    test('follows closures over collections', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
final items = ['home.title', 'profile.title'];
f() => items.map((k) => Text(k.tr())).toList();
''',
        },
        json: enJson(_specJson),
      );
      expect(statusOf(report, 'home.title'), KeyStatus.used);
      expect(statusOf(report, 'profile.title'), KeyStatus.used);
      expect(statusOf(report, 'home.description'), KeyStatus.unused);
    });

    test('follows conditionals, switch expressions and ??', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
String label(Status s, bool flag, String? override) {
  final k = flag ? 'home.title' : 'home.description';
  k.tr();
  (override ?? 'app_name').tr();
  return switch (s) {
    Status.a => 'profile.title',
    Status.b => 'profile.edit_button',
  }.tr();
}
void main() => label(Status.a, true, null);
''',
        },
        json: enJson(_specJson),
      );
      expect(report.unusedKeys.map((k) => k.key), ['unused_message']);
    });
  });

  group('wrappers', () {
    test('follows wrapper functions to their call sites', () {
      final report = analyzeMemory(
        dart: {
          'lib/util.dart': '''
String getTranslation(String key) {
  return key.tr();
}
''',
          'lib/main.dart': "f() => getTranslation('home.title');",
        },
        json: enJson(_specJson),
      );
      expect(statusOf(report, 'home.title'), KeyStatus.used);
      expect(statusOf(report, 'profile.title'), KeyStatus.unused);
      expect(report.unresolvedReferences, isEmpty);
    });

    test('follows wrapper widgets through constructor fields', () {
      final report = analyzeMemory(
        dart: {
          'lib/widgets.dart': '''
class AppText extends StatelessWidget {
  const AppText(this.textKey, {super.key, this.fallback = 'app_name'});
  final String textKey;
  final String fallback;
  @override
  Widget build(BuildContext context) => Text(textKey.tr());
}
class Title extends StatefulWidget {
  const Title({required this.labelKey});
  final String labelKey;
}
class _TitleState extends State<Title> {
  Widget build(BuildContext context) => Text(widget.labelKey.tr());
}
''',
          'lib/main.dart': '''
f() => [const AppText('home.title'), Title(labelKey: 'profile.title')];
''',
        },
        json: enJson(_specJson),
      );
      expect(statusOf(report, 'home.title'), KeyStatus.used);
      expect(statusOf(report, 'profile.title'), KeyStatus.used);
      expect(statusOf(report, 'home.description'), KeyStatus.unused);
    });

    test('follows wrapper methods with named and default parameters', () {
      final report = analyzeMemory(
        dart: {
          'lib/l10n.dart': '''
class L10n {
  static String t(String key, {List<String>? args}) => key.tr(args: args);
  String label({String key = 'app_name'}) => key.tr();
}
''',
          'lib/main.dart': '''
f(L10n l) {
  L10n.t('home.title');
  l.label();
  l.label(key: 'profile.title');
}
''',
        },
        json: enJson(_specJson),
      );
      expect(keysWith(report, KeyStatus.used), {
        'home.title',
        'app_name',
        'profile.title',
      });
    });

    test('follows extension getters on String', () {
      final report = analyzeMemory(
        dart: {
          'lib/ext.dart': '''
extension LocalizedString on String {
  String get localized => tr();
  String withName(String name) => this.tr(namedArgs: {'name': name});
}
''',
          'lib/main.dart': '''
f() {
  'home.title'.localized;
  'profile.title'.withName('A');
}
''',
        },
        json: enJson(_specJson),
      );
      expect(statusOf(report, 'home.title'), KeyStatus.used);
      expect(statusOf(report, 'profile.title'), KeyStatus.used);
      expect(statusOf(report, 'unused_message'), KeyStatus.unused);
    });

    test('supports configured translation functions', () {
      final report = analyzeMemory(
        translationFunctions: const [
          TranslationFunction(name: 'translate', position: 1),
          TranslationFunction(
            name: 'LocalizedLabel',
            namedArgument: 'labelKey',
          ),
        ],
        dart: {
          'lib/main.dart': '''
f(c) {
  translate(c, 'home.title');
  LocalizedLabel(labelKey: 'profile.title');
}
''',
        },
        json: enJson(_specJson),
      );
      expect(statusOf(report, 'home.title'), KeyStatus.used);
      expect(statusOf(report, 'profile.title'), KeyStatus.used);
    });
  });

  group('dynamic keys', () {
    test('interpolated keys become patterns, not unused keys', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
f(String section, String category) {
  final key = 'home.\$section';
  Text(key.tr());
  Text('\${category}_message'.tr());
}
''',
        },
        json: enJson(_specJson),
      );
      expect(keysWith(report, KeyStatus.dynamicallyUsed), {
        'home.title',
        'home.description',
        'unused_message',
      });
      expect(report.dynamicUsages.map((d) => d.pattern.display).toSet(), {
        'home.*',
        '*_message',
      });
    });

    test('concatenation with a known prefix becomes a pattern', () {
      final report = analyzeMemory(
        dart: {'lib/a.dart': "f(String id) => ('profile.' + id).tr();"},
        json: enJson(_specJson),
      );
      expect(statusOf(report, 'profile.title'), KeyStatus.dynamicallyUsed);
      expect(statusOf(report, 'home.title'), KeyStatus.unused);
    });

    test('small finite combinations are resolved exactly', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
f(bool edit) {
  final section = edit ? 'edit_button' : 'title';
  'profile.\$section'.tr();
}
''',
        },
        json: enJson(_specJson),
      );
      expect(statusOf(report, 'profile.title'), KeyStatus.used);
      expect(statusOf(report, 'profile.edit_button'), KeyStatus.used);
      expect(statusOf(report, 'home.title'), KeyStatus.unused);
    });

    test('unresolvable calls block definite classification', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
f(Map<String, dynamic> json) {
  Text(json['label'].toString().tr());
  ['a'].forEach(print);
}
''',
          'lib/main.dart':
              'void main(List<String> a) => f(jsonDecode(a.first));',
        },
        json: enJson(_specJson),
      );
      expect(report.unresolvedReferences, hasLength(1));
      expect(report.unusedKeys, isEmpty);
      expect(
        keysWith(report, KeyStatus.potentiallyUnused),
        hasLength(report.keys.length),
      );
    });

    test('tear-offs make wrapper parameters unresolved', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
String t(String key) => key.tr();
f(List<String> keys) => keys.map(t).toList();
''',
        },
        json: enJson(_specJson),
      );
      expect(report.unresolvedReferences, hasLength(1));
      expect(report.unusedKeys, isEmpty);
    });

    test('an ignore comment acknowledges an unresolved call', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
f(dynamic api) {
  // l10n_sweep:ignore
  Text(api.label.tr());
  'home.title'.tr();
}
''',
        },
        json: enJson(_specJson),
      );
      expect(report.unresolvedReferences.single.acknowledged, isTrue);
      expect(report.blockingUnresolved, isEmpty);
      expect(statusOf(report, 'unused_message'), KeyStatus.unused);
    });

    test('a keys comment declares the keys a call may use', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
f(dynamic api) {
  Text(api.label.tr()); // l10n_sweep:keys profile.*, app_name
}
''',
        },
        json: enJson(_specJson),
      );
      expect(statusOf(report, 'profile.title'), KeyStatus.used);
      expect(statusOf(report, 'app_name'), KeyStatus.used);
      expect(statusOf(report, 'home.title'), KeyStatus.unused);
    });

    test('allow_unresolved_references lifts the block', () {
      final report = analyzeMemory(
        allowUnresolved: true,
        dart: {'lib/a.dart': 'f(dynamic api) => api.label.tr();'},
        json: enJson(_specJson),
      );
      expect(report.unresolvedReferences, hasLength(1));
      expect(report.unusedKeys, hasLength(report.keys.length));
    });
  });

  group('conservative fallbacks', () {
    test('key strings elsewhere in code are potentially unused', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
f() {
  'home.title'.tr();
  return MenuItem(label: 'profile.title');
}
''',
        },
        json: enJson(_specJson),
      );
      expect(statusOf(report, 'profile.title'), KeyStatus.potentiallyUnused);
      expect(statusOf(report, 'home.description'), KeyStatus.unused);
    });

    test('referenced constants are potentially unused', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
const editKey = 'profile.edit_button';
f() {
  'home.title'.tr();
  return CustomButton(editKey);
}
''',
        },
        json: enJson(_specJson),
      );
      expect(
        statusOf(report, 'profile.edit_button'),
        KeyStatus.potentiallyUnused,
      );
    });

    test('no translation calls means nothing is provably unused', () {
      final report = analyzeMemory(
        dart: {'lib/a.dart': 'void main() {}'},
        json: enJson(_specJson),
      );
      expect(report.unusedKeys, isEmpty);
      expect(
        report.issues.map((i) => i.code),
        contains('no_translation_calls'),
      );
    });
  });

  group('configuration', () {
    test('excluded, ignored and dynamic patterns are respected', () {
      final report = analyzeMemory(
        excludedKeys: ['unused_message'],
        ignoredKeys: ['profile.*'],
        dynamicKeyPatterns: ['home.desc*'],
        dart: {'lib/a.dart': "f() => 'home.title'.tr();"},
        json: enJson(_specJson),
      );
      expect(statusOf(report, 'unused_message'), KeyStatus.excluded);
      expect(statusOf(report, 'profile.title'), KeyStatus.used);
      expect(statusOf(report, 'home.description'), KeyStatus.used);
      expect(report.unusedKeys.map((k) => k.key), ['app_name']);
    });
  });

  group('locales', () {
    test('reports missing and extra keys per locale', () {
      final report = analyzeMemory(
        dart: {'lib/a.dart': "f() => 'a'.tr();"},
        json: {
          'assets/translations/en.json': '{"a": "A", "b": "B"}',
          'assets/translations/ur.json': '{"a": "اے"}',
          'assets/translations/fr.json': '{"a": "A", "b": "B", "c": "C"}',
        },
      );
      expect(report.primaryLocale, 'en');
      final ur = report.localeFiles.firstWhere((f) => f.locale == 'ur');
      final fr = report.localeFiles.firstWhere((f) => f.locale == 'fr');
      expect(ur.missingKeys, ['b']);
      expect(fr.extraKeys, ['c']);
      expect(report.missingTranslationCount, 1);
      expect(report.unusedKeys.map((k) => k.key), ['b']);
      expect(report.orphanUnusedKeys.map((k) => k.key), ['c']);
      expect(report.keys.firstWhere((k) => k.key == 'b').locales, ['en', 'fr']);
    });

    test('honours the configured primary locale', () {
      final report = analyzeMemory(
        primaryLocale: 'ur',
        dart: {'lib/a.dart': "f() => 'a'.tr();"},
        json: {
          'assets/translations/en.json': '{"a": "A", "b": "B"}',
          'assets/translations/ur.json': '{"a": "اے"}',
        },
      );
      expect(report.primaryLocale, 'ur');
      expect(report.unusedKeys, isEmpty);
      expect(report.orphanUnusedKeys.map((k) => k.key), ['b']);
    });

    test('reports a missing primary locale as an error', () {
      final report = analyzeMemory(
        primaryLocale: 'de',
        dart: {'lib/a.dart': "f() => 'a'.tr();"},
        json: enJson('{"a": ""}'),
      );
      expect(
        report.errors.map((e) => e.code),
        contains('primary_locale_missing'),
      );
    });
  });

  group('cyclic references', () {
    test('values flow through widgets that pass a field to each other', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
class Outer extends StatefulWidget {
  const Outer({required this.title});
  final String title;
}
class _OuterState extends State<Outer> {
  Widget build(BuildContext context) => Inner(title: widget.title);
}
class Inner extends StatelessWidget {
  const Inner({required this.title});
  final String title;
  Widget build(BuildContext context) =>
      Column(children: [Text(title.tr()), Outer(title: title)]);
}
f() => Outer(title: 'home.title');
''',
        },
        json: enJson(_specJson),
      );
      expect(statusOf(report, 'home.title'), KeyStatus.used);
      expect(statusOf(report, 'profile.title'), KeyStatus.unused);
      expect(report.unresolvedReferences, isEmpty);
    });

    test('self-referencing string building terminates conservatively', () {
      final report = analyzeMemory(
        dart: {
          'lib/a.dart': '''
class Path {
  String key = 'home';
  void deeper(String part) { key = key + '.' + part; }
  String label() => key.tr();
}
void main() { Path().deeper('title'); Path().label(); }
''',
        },
        json: enJson(_specJson),
      );
      expect(statusOf(report, 'home.title'), isNot(KeyStatus.unused));
      expect(statusOf(report, 'home.description'), isNot(KeyStatus.unused));
    });

    String ring(int count) {
      final buffer = StringBuffer();
      for (var i = 0; i < count; i++) {
        final next = (i + 1) % count;
        final skip = (i * 7 + 3) % count;
        buffer.writeln('''
class W$i extends StatelessWidget {
  const W$i({required this.label, this.other = 'app_name'});
  final String label;
  final String other;
  Widget build(BuildContext c) => Column(children: [
    Text(label.tr()),
    W$next(label: label, other: other),
    W$skip(label: other, other: label),
  ]);
}''');
      }
      buffer.writeln("f() => W0(label: 'home.title');");
      return buffer.toString();
    }

    test('extremely deep reference chains fail safe', () {
      final report = analyzeMemory(
        dart: {'lib/a.dart': ring(450)},
        json: enJson(_specJson),
      );
      expect(report.unresolvedReferences, isNotEmpty);
      expect(report.unusedKeys, isEmpty);
    });

    test('large interconnected graphs resolve quickly', () {
      final stopwatch = Stopwatch()..start();
      final report = analyzeMemory(
        dart: {'lib/a.dart': ring(200)},
        json: enJson(_specJson),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
      expect(report.unresolvedReferences.map((r) => r.reason), isEmpty);
      expect(statusOf(report, 'home.title'), KeyStatus.used);
      expect(statusOf(report, 'app_name'), KeyStatus.used);
      expect(statusOf(report, 'unused_message'), KeyStatus.unused);
    });
  });

  test('linked translations keep their targets', () {
    final report = analyzeMemory(
      dart: {'lib/a.dart': "f() => 'greeting'.tr();"},
      json: enJson('''
{"greeting": "Hello from @:app_name", "app_name": "Demo",
 "farewell": "Bye @.upper:(app_short)", "app_short": "D"}
'''),
    );
    expect(statusOf(report, 'app_name'), KeyStatus.used);
    expect(statusOf(report, 'farewell'), KeyStatus.unused);
    expect(statusOf(report, 'app_short'), KeyStatus.unused);
  });

  test('translating translated text is a warning, not an unknown key', () {
    final report = analyzeMemory(
      dart: {
        'lib/a.dart': '''
f(int days) {
  'items'.plural(days).tr();
  tr(tr('home.title'));
}
''',
      },
      json: enJson(
        '{"items": {"one": "", "other": ""}, "home": {"title": ""}, "x": ""}',
      ),
    );
    expect(report.unresolvedReferences, isEmpty);
    expect(statusOf(report, 'items'), KeyStatus.used);
    expect(statusOf(report, 'home.title'), KeyStatus.used);
    expect(statusOf(report, 'x'), KeyStatus.unused);
    expect(
      report.warnings.where((w) => w.code == 'double_translation'),
      hasLength(2),
    );
  });

  test('reports keys used in code but missing from locale files', () {
    final report = analyzeMemory(
      dart: {'lib/a.dart': "f() { 'a'.tr(); 'b.c'.tr(); }"},
      json: enJson('{"a": ""}'),
    );
    expect(report.undefinedKeys.keys, ['b.c']);
  });
}
