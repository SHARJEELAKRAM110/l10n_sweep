import 'package:l10n_sweep/l10n_sweep.dart';
import 'package:test/test.dart';

String remove(
  String content,
  Set<String> keys, {
  bool removeEmptyParents = true,
  String path = 'en.json',
}) {
  final file = const JsonTranslationParser().parse(
    locale: 'en',
    path: path,
    absolutePath: path,
    content: content,
  );
  return JsonPreservationService(
    removeEmptyParents: removeEmptyParents,
  ).removeKeys(file, keys).newContent;
}

void main() {
  const sample = '''
{
  "a": "A",
  "b": "B",
  "c": "C"
}
''';

  test('removes a middle member', () {
    expect(remove(sample, {'b'}), '{\n  "a": "A",\n  "c": "C"\n}\n');
  });

  test('removes the first member', () {
    expect(remove(sample, {'a'}), '{\n  "b": "B",\n  "c": "C"\n}\n');
  });

  test('removes the last member and its separating comma', () {
    expect(remove(sample, {'c'}), '{\n  "a": "A",\n  "b": "B"\n}\n');
  });

  test('removes consecutive and scattered members', () {
    expect(remove(sample, {'b', 'c'}), '{\n  "a": "A"\n}\n');
    expect(remove(sample, {'a', 'c'}), '{\n  "b": "B"\n}\n');
  });

  test('removing everything leaves an empty object', () {
    expect(remove(sample, {'a', 'b', 'c'}), '{}\n');
  });

  test('removes emptied parent objects', () {
    const nested = '''
{
  "keep": "K",
  "old": {
    "x": "X",
    "y": "Y"
  },
  "home": {
    "title": "T",
    "gone": "G"
  }
}
''';
    expect(remove(nested, {'old.x', 'old.y', 'home.gone'}), '''
{
  "keep": "K",
  "home": {
    "title": "T"
  }
}
''');
  });

  test('can keep emptied parent objects', () {
    const nested = '{\n  "old": {\n    "x": "X"\n  },\n  "k": "K"\n}\n';
    expect(
      remove(nested, {'old.x'}, removeEmptyParents: false),
      '{\n  "old": {},\n  "k": "K"\n}\n',
    );
  });

  test('keeps parents that were already empty', () {
    const nested = '{"empty": {}, "a": "A", "b": "B"}';
    expect(remove(nested, {'a'}), '{"empty": {}, "b": "B"}');
  });

  test('preserves Unicode, RTL text, escapes and unrelated bytes', () {
    const text =
        '{\n'
        '\t"greeting": "السلام علیکم",\n'
        '\t"escaped": "Line\\nTab\\t\\u00e9",\n'
        '\t"remove": "x",\n'
        '\t"emoji": "😀 مرحبا"\n'
        '}';
    final result = remove(text, {'remove'});
    expect(
      result,
      '{\n'
      '\t"greeting": "السلام علیکم",\n'
      '\t"escaped": "Line\\nTab\\t\\u00e9",\n'
      '\t"emoji": "😀 مرحبا"\n'
      '}',
    );
  });

  test('preserves CRLF line endings', () {
    const text = '{\r\n  "a": "A",\r\n  "b": "B"\r\n}\r\n';
    expect(remove(text, {'a'}), '{\r\n  "b": "B"\r\n}\r\n');
    expect(remove(text, {'b'}), '{\r\n  "a": "A"\r\n}\r\n');
  });

  test('preserves a byte order mark', () {
    expect(remove('﻿{"a": 1, "b": 2}', {'a'}), '﻿{ "b": 2}');
  });

  test('removes flat dotted keys by their real JSON path', () {
    const text = '{"home.title": "T", "home": {"title2": "U"}, "x": "X"}';
    expect(
      remove(text, {'home.title'}),
      '{ "home": {"title2": "U"}, "x": "X"}',
    );
  });

  test('removes a whole plural group', () {
    const text = '{\n  "items": {"one": "1", "other": "n"},\n  "k": "K"\n}';
    expect(remove(text, {'items'}), '{\n  "k": "K"\n}');
  });

  test('handles JSONC comments and trailing commas', () {
    const text = '''
{
  // Header comment stays.
  "a": "A", // about a
  // about b
  "b": "B", // trailing b
  "c": "C", // about c
}
''';
    expect(remove(text, {'b'}), '''
{
  // Header comment stays.
  "a": "A", // about a
  "c": "C", // about c
}
''');
    expect(remove(text, {'c'}), '''
{
  // Header comment stays.
  "a": "A", // about a
  // about b
  "b": "B", // trailing b
}
''');
  });

  test('ignores keys that are not in the file', () {
    expect(remove(sample, {'missing'}), sample);
  });

  test('refuses invalid files', () {
    final file = const JsonTranslationParser().parse(
      locale: 'en',
      path: 'en.json',
      absolutePath: 'en.json',
      content: '{"a": ',
    );
    expect(
      () => const JsonPreservationService().removeKeys(file, {'a'}),
      throwsA(isA<JsonEditException>()),
    );
  });

  test('removes many keys from a large file', () {
    final buffer = StringBuffer('{\n');
    for (var i = 0; i < 5000; i++) {
      buffer.write('  "group$i": {"a": "A$i", "b": "B$i"}');
      buffer.write(i == 4999 ? '\n' : ',\n');
    }
    buffer.write('}\n');
    final keys = {for (var i = 0; i < 5000; i += 2) 'group$i.a'};
    final result = remove(buffer.toString(), keys);
    final reparsed = const JsonTranslationParser().parse(
      locale: 'en',
      path: 'en.json',
      absolutePath: 'en.json',
      content: result,
    );
    expect(reparsed.entries, hasLength(10000 - 2500));
    expect(reparsed.entries.containsKey('group0.a'), isFalse);
    expect(reparsed.entries['group0.b']!.rawValue, '"B0"');
  });
}
