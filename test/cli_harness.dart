import 'package:l10n_sweep/cli.dart';

/// A [Prompter] that replays scripted answers.
class ScriptedPrompter implements Prompter {
  ScriptedPrompter({
    this.canPrompt = true,
    this.selection,
    this.confirmAnswer = false,
  });

  @override
  final bool canPrompt;

  /// Labels to select, or `null` to cancel. When unset, the preselection
  /// is accepted.
  final List<String>? Function(List<SelectableItem> items)? selection;
  final bool confirmAnswer;

  final List<String> shownLabels = [];
  final List<String> preselected = [];
  final List<String> questions = [];

  @override
  List<int>? select(String title, List<SelectableItem> items) {
    shownLabels.addAll(items.map((i) => i.label));
    preselected.addAll(items.where((i) => i.selected).map((i) => i.label));
    if (selection == null) {
      return [
        for (var i = 0; i < items.length; i++)
          if (items[i].selected) i,
      ];
    }
    final labels = selection!(items);
    if (labels == null) return null;
    return [
      for (var i = 0; i < items.length; i++)
        if (labels.contains(items[i].label)) i,
    ];
  }

  @override
  bool confirm(String question, {bool defaultValue = false}) {
    questions.add(question);
    return confirmAnswer;
  }
}

class CliRun {
  CliRun(this.exitCode, this.out, this.err);

  final int exitCode;
  final String out;
  final String err;

  @override
  String toString() => 'exit $exitCode\n--- stdout\n$out\n--- stderr\n$err';
}

Future<CliRun> runCli(
  List<String> args, {
  required String projectRoot,
  Prompter? prompter,
}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = await L10nSweepCli(
    out: out,
    err: err,
    prompter: prompter ?? ScriptedPrompter(canPrompt: false),
    workingDirectory: projectRoot,
    color: false,
  ).run(args);
  return CliRun(code, out.toString(), err.toString());
}
