import 'package:l10n_sweep/src/cli/prompter.dart';
import 'package:l10n_sweep/src/utils/ansi.dart';
import 'package:test/test.dart';

List<SelectableItem> items() => [
  SelectableItem(label: 'a', selected: true),
  SelectableItem(label: 'b', selected: true),
  SelectableItem(label: 'c'),
];

List<int>? runKeys(List<int> bytes, List<SelectableItem> list) {
  final input = [...bytes];
  final output = StringBuffer();
  return InteractiveSelector(
    ansi: const Ansi(false),
    readByte: () => input.isEmpty ? -1 : input.removeAt(0),
    write: output.write,
  ).run('Select', list);
}

void main() {
  group('InteractiveSelector', () {
    test('enter accepts the preselection', () {
      expect(runKeys([13], items()), [0, 1]);
    });

    test('space toggles the item under the cursor', () {
      // down, space (deselect b), down, space (select c), enter
      expect(runKeys([0x6A, 0x20, 0x6A, 0x20, 10], items()), [0, 2]);
    });

    test('arrow escape sequences move the cursor', () {
      // down arrow twice, space, up arrow, space, enter
      expect(
        runKeys([27, 91, 66, 27, 91, 66, 0x20, 27, 91, 65, 0x20, 13], items()),
        [0, 2],
      );
    });

    test('a toggles all', () {
      expect(runKeys([0x61, 13], items()), [0, 1, 2]);
      expect(runKeys([0x61, 0x61, 13], items()), isEmpty);
    });

    test('q, Ctrl+C and end of input cancel', () {
      expect(runKeys([0x71], items()), isNull);
      expect(runKeys([3], items()), isNull);
      expect(runKeys([], items()), isNull);
    });
  });

  group('LineSelector', () {
    List<int>? runLines(List<String> lines) {
      final input = [...lines];
      return LineSelector(
        readLine: () => input.isEmpty ? null : input.removeAt(0),
        write: (_) {},
      ).run('Select', items());
    }

    test('toggles numbers and ranges', () {
      expect(runLines(['2-3', '']), [0, 2]);
      expect(runLines(['n', '3', '']), [2]);
      expect(runLines(['a', '']), [0, 1, 2]);
    });

    test('re-prompts on invalid input and cancels on q', () {
      expect(runLines(['9', 'x', '']), [0, 1]);
      expect(runLines(['q']), isNull);
    });

    test('parses selections', () {
      expect(LineSelector.parseSelection('1, 3-4', 5), {0, 2, 3});
      expect(LineSelector.parseSelection('0', 5), isNull);
      expect(LineSelector.parseSelection('4-2', 5), isNull);
    });
  });
}
