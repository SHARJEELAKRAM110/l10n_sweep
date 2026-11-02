# Contributing to l10n_sweep

Thanks for helping! Bug reports with a minimal reproduction (a Dart snippet
and the JSON it is checked against) are the most valuable contribution.

## Ground rule

**A key must never be classified as definitely unused unless the analyzer can
prove that nothing references it.** Any change that makes detection more
aggressive needs a test showing why it is still safe. When in doubt, produce
an `UnknownExpr`; the resolver turns it into an unresolved reference.

## Development setup

```bash
git clone https://github.com/SHARJEELAKRAM110/l10n_sweep.git
cd l10n_sweep
dart pub get
```

Requirements: Dart SDK 3.9 or newer. Flutter is not needed.

## Checks

Run these before opening a pull request; CI runs the same commands.

```bash
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

Run the CLI against the bundled fixture:

```bash
dart run l10n_sweep -C test/fixtures/sample_flutter_app analyze --verbose
```

## Architecture

```
lib/src/
  analyzer/        Dart AST indexing, key resolution, classification
  parsers/         JSON parsing with offsets, locale discovery, Dart file discovery
  cleanup/         Text-preserving edits, backups, transactional cleanup
  configuration/   l10n_sweep.yaml loading and project detection
  models/          Report and key models (no I/O)
  reporting/       Console, JSON and Markdown renderers
  cli/             Commands and terminal prompts
```

The pipeline is:

1. `DartAstAnalyzer` parses each file with `package:analyzer` and records a
   compact, AST-free `FileIndex`: translation calls (sinks), declarations,
   call sites and string literals, with expressions converted to `KeyExpr`.
2. `ProjectIndex` merges file indexes. `KeyResolver` evaluates each sink's
   `KeyExpr` to exact keys, key patterns or unresolved reasons.
3. `UnusedKeyDetector` classifies every key in every locale file.
4. `CleanupEngine` removes selected keys with `JsonPreservationService`,
   which deletes exact text spans and verifies the result.

The engine (`package:l10n_sweep/l10n_sweep.dart`) must not depend on the CLI.

## Tests

- `test/unit`: parsers, analyzer, resolver, preservation, configuration.
- `test/integration`: the sample app fixture through the CLI.
- `test/safety`: guarantees that files are never modified unexpectedly.

Every bug fix needs a regression test. Filesystem tests use temporary
directories (`test/helpers.dart`).

## Commit and release process

- Keep `lib/src/version.dart` in sync with `pubspec.yaml` (a test checks it).
- Add an entry to `CHANGELOG.md` for user-visible changes.
- Maintainers publish with `dart pub publish` after CI passes.

## Code of conduct

Be respectful and constructive. Harassment of any kind is not tolerated.
