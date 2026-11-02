/// The `l10n_sweep` command-line interface.
///
/// Most users run it with `dart run l10n_sweep <command>`. Embedders can call
/// [L10nSweepCli.run] directly.
library;

export 'src/cli/l10n_sweep_cli.dart' show L10nSweepCli;
export 'src/cli/prompter.dart' show Prompter, SelectableItem;
