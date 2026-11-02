import 'package:l10n_sweep/l10n_sweep.dart';
import 'package:test/test.dart';

TranslationFile parse(String content, {String path = 'en.json'}) =>
    const JsonTranslationParser().parse(
      locale: 'en',
      path: path,
      absolutePath: path,
      content: content,
    );

void main() {
  group('JsonParser', () {
    test('records offsets of members and values', () {
      const text = '{"a": "x", "b": {"c": 1}}';
      final doc = JsonParser.parse(text);
      final root = doc.root as JsonObject;
      expect(root.members.map((m) => m.name), ['a', 'b']);
      expect(root.members.first.value.sourceIn(text), '"x"');
      expect(root.members.first.commaOffset, text.indexOf(','));
      expect(root.members.last.value.sourceIn(text), '{"c": 1}');
    });

    test('decodes escapes and unicode', () {
      final doc = JsonParser.parse(r'{"k": "a\"b\\c\nاé 😀"}');
      final value = (doc.root as JsonObject).members.single.value as JsonString;
      expect(value.value, 'a"b\\c\nاé 😀');
    });

    test('reports line and column for syntax errors', () {
      const text = '{\n  "a": "x",\n  "b": "y"\n  "c": "z"\n}';
      expect(
        () => JsonParser.parse(text),
        throwsA(
          isA<JsonSyntaxException>()
              .having((e) => e.line, 'line', 4)
              .having((e) => e.column, 'column', 3)
              .having((e) => e.message, 'message', contains('"b"')),
        ),
      );
    });

    test('rejects common mistakes', () {
      for (final bad in [
        '',
        '{',
        '{"a": }',
        "{'a': 1}",
        '{"a": 01}',
        '{"a": tru}',
        '{"a": "x"} extra',
        '{"a": "unterminated}',
        '{"a": "\\x"}',
        '{"a": "\\u12"}',
        '{"a": "tab\there"}',
        '[1, 2',
      ]) {
        expect(
          () => JsonParser.parse(bad),
          throwsA(isA<JsonSyntaxException>()),
          reason: bad,
        );
      }
    });

    test('accepts comments and trailing commas but records them', () {
      final doc = JsonParser.parse('''
{
  // comment
  "a": 1, /* block */
  "b": [1, 2,],
}
''');
      expect(doc.hasComments, isTrue);
      expect(doc.hasTrailingCommas, isTrue);
      expect((doc.root as JsonObject).members, hasLength(2));
    });

    test('strips a byte order mark', () {
      final doc = JsonParser.parse('﻿{"a": 1}');
      expect(doc.text, '{"a": 1}');
    });

    test('records duplicate members', () {
      final doc = JsonParser.parse('{"a": {"x": 1, "x": 2}}');
      expect(doc.duplicateMembers.single.path, 'a.x');
    });

    test('handles deeply nested input without stack overflow', () {
      final deep = '${'{"a":' * 600}1${'}' * 600}';
      expect(() => JsonParser.parse(deep), throwsA(isA<JsonSyntaxException>()));
    });
  });

  group('JsonTranslationParser', () {
    test('flattens nested objects into dot notation', () {
      final file = parse('''
{
  "app_name": "App",
  "home": {"title": "Welcome", "nested": {"deep": "Deep"}},
  "empty": {}
}
''');
      expect(file.entries.keys, [
        'app_name',
        'home.title',
        'home.nested.deep',
        'empty',
      ]);
      expect(file.entries['home.nested.deep']!.key.segments, [
        'home',
        'nested',
        'deep',
      ]);
    });

    test('keeps flat dotted keys with their real JSON path', () {
      final file = parse('{"home.title": "Welcome", "a": {"b.c": "x"}}');
      expect(file.entries.keys, ['home.title', 'a.b.c']);
      expect(file.entries['home.title']!.key.segments, ['home.title']);
      expect(file.entries['a.b.c']!.key.segments, ['a', 'b.c']);
    });

    test('warns when nested and flat keys collide', () {
      final file = parse('{"a.b": "flat", "a": {"b": "nested"}}');
      expect(file.issues.map((i) => i.code), contains('key_collision'));
    });

    test('treats plural and gender objects as one unit', () {
      final file = parse('''
{
  "items": {"zero": "none", "one": "one", "other": "many"},
  "gender": {"male": "he", "female": "she", "other": "they"},
  "namespace": {"one": {"nested": "x"}}
}
''');
      expect(file.entries.keys, ['items', 'gender', 'namespace.one.nested']);
      expect(file.entries['items']!.key.isGroup, isTrue);
    });

    test('preserves Urdu and Arabic text', () {
      final file = parse('{"greeting": "السلام علیکم", "rtl": "مرحبا"}');
      expect(file.entries['greeting']!.rawValue, '"السلام علیکم"');
    });

    test('extracts linked translation targets', () {
      final file = parse(r'''
{"a": "See @:other.key and @.upper:(third). Also @:end."}
''');
      expect(file.entries['a']!.linkedKeys, {'other.key', 'third', 'end'});
    });

    test('reports invalid JSON with location instead of throwing', () {
      final file = parse(
        '{\n  "a": "x",,\n}',
        path: 'assets/translations/en.json',
      );
      expect(file.isValid, isFalse);
      final issue = file.issues.single;
      expect(issue.code, 'invalid_json');
      expect(issue.location!.line, 2);
      expect(issue.location!.path, 'assets/translations/en.json');
    });

    test('rejects a non-object root', () {
      final file = parse('["a"]');
      expect(file.isValid, isFalse);
      expect(file.issues.single.code, 'invalid_root');
    });

    test('warns about comments in .json but not in .jsonc', () {
      expect(
        parse('{"a": 1 // c\n}').issues.map((i) => i.code),
        contains('json_comments'),
      );
      expect(parse('{"a": 1 // c\n}', path: 'en.jsonc').issues, isEmpty);
    });
  });

  group('TranslationCatalog', () {
    test('derives locales from file names', () {
      expect(TranslationCatalog.localeFromFileName('en.json'), 'en');
      expect(TranslationCatalog.localeFromFileName('en-US.json'), 'en-US');
      expect(
        TranslationCatalog.localeFromFileName('zh_Hant_TW.json'),
        'zh_Hant_TW',
      );
      expect(TranslationCatalog.localeFromFileName('config.json'), isNull);
    });

    test('puts the primary locale first and falls back to en', () {
      final catalog = TranslationCatalog.fromSources({
        't/fr.json': '{}',
        't/en.json': '{}',
        't/ar.json': '{}',
      });
      expect(catalog.primary!.locale, 'en');
      expect(catalog.files.map((f) => f.locale), ['en', 'ar', 'fr']);
    });

    test('matches the primary locale regardless of separator and case', () {
      final catalog = TranslationCatalog.fromSources({
        't/en_US.json': '{}',
        't/fr.json': '{}',
      }, primaryLocale: 'en-us');
      expect(catalog.primary!.locale, 'en_US');
    });
  });
}
