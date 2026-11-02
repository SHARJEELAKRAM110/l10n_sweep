# l10n_sweep

Find unused [easy_localization](https://pub.dev/packages/easy_localization)
translation keys in Flutter apps, and remove them safely.

`l10n_sweep` reads your Dart code with the Dart analyzer's parser, follows
keys through constants, generated `LocaleKeys`, collections, wrapper
functions and wrapper widgets, and compares the result with your JSON locale
files. Keys are only removed after you approve them, from every locale at
once, with a backup and without reformatting your files.

```text
$ dart run l10n_sweep analyze

l10n_sweep analysis

Translation files:           2 (primary: en)
Total translation keys:      24
Used keys:                   13
Unused keys:                 7
Potentially unused keys:     0
Dynamically referenced keys: 2
Excluded keys:               1
Missing translations:        1
Uncertain references:        0

Unused keys by locale:
  en.json (primary): 7
  ur.json: 7

Unused keys:
  home.description
  profile.edit_button
  settings.experimental_feature
  errors.timeout
  unused_message
  old.banner
  old.footer
  Safe to remove with "clean". Review with --verbose.

Dynamic key patterns:
  sections.*  matches 2 keys  lib/screens/home_screen.dart:33:16

Locale consistency:
  ur.json: 1 missing (settings.experimental_feature)
  ur.json: 1 not in the primary locale (ur_only)

Analysis completed successfully. (3 Dart files, 10 translation calls, 344 ms)
```

## Contents

- [Why another tool?](#why-another-tool)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Removing unused keys, step by step](#removing-unused-keys-step-by-step)
- [How keys are classified](#how-keys-are-classified)
- [Supported patterns](#supported-patterns)
- [Dynamic keys and their limitations](#dynamic-keys-and-their-limitations)
- [Cleanup safety](#cleanup-safety)
- [Commands](#commands)
- [Configuration](#configuration)
- [Multiple locales](#multiple-locales)
- [Reports](#reports)
- [CI/CD integration](#cicd-integration)
- [Programmatic use](#programmatic-use)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## Why another tool?

Searching the codebase for each key string misses keys that are stored in
constants, passed through helpers, or built with interpolation — and deleting
those breaks the app at run time. `l10n_sweep` is built around one rule:

> A key is reported as **definitely unused** only when the analyzer can show
> that nothing in the scanned code references it. Everything else is kept or
> flagged for human review.

## Requirements

- Dart SDK 3.11 or newer (Flutter 3.41 or newer).
- A Flutter project using easy_localization with JSON locale files
  (`en.json`, `en-US.json`, ...). The default `RootBundleAssetLoader` and
  `JsonAssetLoader` layouts are supported.
- No Flutter dependency: `l10n_sweep` is a pure Dart CLI and does not need
  `pub get` to have been run in the analyzed project.

## Installation

Add it as a dev dependency of your Flutter app:

```bash
dart pub add --dev l10n_sweep
```

```yaml
dev_dependencies:
  l10n_sweep: ^0.1.0
```

`l10n_sweep` depends on `package:analyzer` (13.x–14.x). If that conflicts
with other dev dependencies (for example an older `build_runner` setup),
install it globally instead:

```bash
dart pub global activate l10n_sweep
l10n_sweep analyze        # instead of: dart run l10n_sweep analyze
```

## Quick start

```bash
# 1. Create l10n_sweep.yaml from the detected project layout.
dart run l10n_sweep init

# 2. Check the setup and find patterns the analyzer cannot follow.
dart run l10n_sweep doctor

# 3. See which keys are unused. Never modifies files.
dart run l10n_sweep analyze --verbose

# 4. Preview the removal.
dart run l10n_sweep clean --dry-run

# 5. Pick keys interactively and confirm.
dart run l10n_sweep clean
```

Interactive cleanup looks like this:

```text
Found 7 unused keys and 1 that need review.

? Select keys to remove: (6/8 selected)
> [x] home.description
  [x] profile.edit_button
  [ ] settings.experimental_feature
  [x] errors.timeout
  [x] unused_message
  [x] old.banner
  [x] old.footer
  [ ] ur_only  not in primary locale
  up/down move, space toggle, a all, enter confirm, q cancel

Files to modify:
  assets/translations/en.json: 6 keys
  assets/translations/ur.json: 6 keys

? Remove 6 selected keys from 2 files? (y/N) y
Removed 6 keys from 2 files.
Backup: /path/to/app/.l10n_sweep/backups/20261102-153012-118
Undo with: dart run l10n_sweep restore --id 20261102-153012-118
```

Add `.l10n_sweep/` to your `.gitignore`.

## Removing unused keys, step by step

The commands below use the global install (`l10n_sweep ...`). With a dev
dependency, write `dart run l10n_sweep ...` instead. Run them from the root
of your Flutter app (the folder with `pubspec.yaml`), or pass `-C <path>`.

**1. Install and commit.**

```bash
dart pub global activate l10n_sweep
git commit -am "Before l10n_sweep"   # so you can always roll back
```

**2. See the summary.**

```bash
l10n_sweep analyze
```

This prints the counts and the list of unused keys. Add `--verbose` only
when you want the reason and location for every key; the output is long.

**3. Remove the keys.**

Pick one:

```bash
# A. Remove every key proven unused, without questions.
l10n_sweep clean --yes

# B. Choose from a checklist that shows only removable keys.
l10n_sweep clean
```

In the checklist, keys proven unused are already ticked and keys that need
review are not. Press `a` to select all, `space` to toggle one key, `Enter`
to continue, then `y` to confirm. Each key is removed from every locale
file, and a backup is written first.

**4. Run the app**, open the screens whose texts were removed, and check
that no raw keys (such as `home.title`) appear.

**5. Undo if needed.**

```bash
l10n_sweep restore
```

### `clean --yes` says "Nothing to remove"

```text
Warning: 20 translation calls have keys that cannot be determined, so no key
is classified as definitely unused.
No definitely unused keys found. Nothing to remove.
```

Some `.tr()` calls use a key held in a variable the analyzer cannot follow,
such as `item.title.tr()` or `json['label'].tr()`. Any of them could use any
key, so nothing is proven unused. You have three options:

1. **Annotate the calls (recommended).** List them with
   `l10n_sweep doctor`, then mark each one:

   ```dart
   Text(item.titleKey.tr()); // l10n_sweep:keys menu.*, common.ok

   // l10n_sweep:ignore
   Text(serverMessage.tr());
   ```

   When every call is resolved or annotated, `clean --yes` works.

2. **Use the checklist.** `l10n_sweep clean`, press `a`, `Enter`, `y`. You
   review the keys instead of the analyzer.

3. **Turn the protection off.** In `l10n_sweep.yaml`:

   ```yaml
   l10n_sweep:
     safety:
       allow_unresolved_references: true
   ```

   `clean --yes` then removes keys that no resolved call uses. A key that
   one of the unresolved calls builds at run time would be removed too, so
   commit first and test the app afterwards.

### Keys marked "needs review"

```text
? Continue_Offline   uncertain: the string "Continue_Offline" appears in
                     source code outside a translation call
```

The key's text appears in your code, but not inside a translation call the
analyzer recognizes: for example a map of labels, a custom widget from
another package, or dead code. `clean --yes` never removes these. Either:

- find the string (`grep -rn "Continue_Offline" lib`, or in PowerShell
  `Get-ChildItem lib -Recurse -Filter *.dart | Select-String "Continue_Offline"`);
- if it is translated through your own wrapper, add the wrapper under
  `translation_functions`;
- if the code is dead, delete it and run `analyze` again;
- or select the key in the `clean` checklist.

### Keys only in some locales

Keys that exist in another locale but not in the primary one (shown as
`not in primary locale`) are never removed by `clean --yes`. Select them in
the `clean` checklist.

## How keys are classified

| Status | Meaning | Removed by `clean --yes` | Offered by `clean` |
| --- | --- | --- | --- |
| `used` | Referenced by a resolved translation call, linked from a used translation (`@:key`), or listed in `ignored_keys` / `dynamic_key_patterns` | never | never |
| `dynamic` | May be produced by a dynamic key such as `'home.$section'.tr()` | never | only with `--include-uncertain` |
| `potentially_unused` | No resolved reference, but the analyzer cannot rule one out (see below) | never | yes, not pre-selected |
| `unused` | No reference, and every translation call in the project was resolved | yes | yes, pre-selected |
| `excluded` | Listed in `excluded_keys` | never | never |

A key is **potentially unused** instead of unused when:

- its exact string appears elsewhere in the code (for example
  `MenuItem(label: 'profile.title')`), or a constant holding it is referenced
  outside a translation call;
- some translation call in the project has a key the analyzer cannot
  determine, such as `apiResponse.labelKey.tr()` — that call could reference
  any key;
- no translation calls were found at all, no Dart files were scanned, or the
  primary locale file is invalid.

## Supported patterns

All easy_localization call forms:

```dart
Text('home.title'.tr());
Text('items_count'.plural(count));
Text('message'.tr(args: ['John']));
Text('message'.tr(namedArgs: {'name': 'John'}));
Text('pronoun'.tr(gender: 'female'));
Text(tr('home.title'));
Text(plural('items_count', count));
Text(context.tr('home.title'));
Text(context.plural('items_count', count));
Text('home.title').tr();                 // Text widget extension
LocaleKeys.home_title.tr();              // generated keys (codegen -f keys)
```

Keys are followed through:

```dart
// Constants, static fields and getters
const titleKey = 'home.title';
Text(titleKey.tr());

// Collections
const tabs = ['tabs.home', 'tabs.settings'];
for (final key in tabs) Text(key.tr());
Text(tabs.first.tr());
tabs.map((key) => Text(key.tr()));
const labels = {Tab.home: 'tabs.home', Tab.settings: 'tabs.settings'};
Text(labels[tab]!.tr());

// Conditionals and switch expressions
Text((isEditing ? 'profile.save' : 'profile.edit').tr());
Text(switch (status) { Status.ok => 'status.ok', Status.error => 'status.error' }.tr());

// Helper functions (resolved at every call site, including default values)
String translate(String key, {List<String>? args}) => key.tr(args: args);
translate('errors.network', args: ['500']);

// Wrapper widgets (constructor parameters stored in fields)
class LocalizedText extends StatelessWidget {
  const LocalizedText(this.textKey, {super.key});
  final String textKey;
  @override
  Widget build(BuildContext context) => Text(textKey.tr());
}
const LocalizedText('settings.language');

// StatefulWidget fields read through `widget.`
Text(widget.titleKey.tr());

// Extension members on String
extension on String {
  String get localized => tr();
}
Text('home.title'.localized);
```

JSON features:

- Nested objects (`home.title`) and flat dotted keys (`"home.title": ...`).
- Plural and gender groups (`zero/one/two/few/many/other`,
  `male/female/other`) are treated as one key.
- Linked translations (`@:app_name`, `@.upper:(app_name)`) keep their targets.
- JSONC comments and trailing commas are understood (and reported, because
  easy_localization's JSON loader rejects them in `.json` files).

## Dynamic keys and their limitations

Dynamic keys are handled conservatively:

```dart
Text('home.$section'.tr());          // pattern home.*      -> matching keys kept
Text('${category}_title'.tr());      // pattern *_title     -> matching keys kept
Text(('errors.' + code).tr());       // pattern errors.*    -> matching keys kept
final key = edit ? 'edit' : 'view';
Text('profile.$key'.tr());           // resolved exactly: profile.edit, profile.view
```

A key with fewer than two known characters (`'$a.$b'.tr()`) or one coming
from outside the code (`json['label'].tr()`, a parameter of a framework
callback, a function passed as a value) is **unresolved**. While any
unresolved call exists, no key is reported as definitely unused.

The analyzer lists every unresolved call with its location
(`analyze --verbose` or `doctor`). Resolve each one in one of these ways:

```dart
// Declare the keys this call can produce (globs allowed):
Text(item.labelKey.tr()); // l10n_sweep:keys menu.*, common.ok

// Or accept that the keys used here are covered elsewhere:
// l10n_sweep:ignore
Text(serverMessage.tr());
```

Or list the patterns in `dynamic_key_patterns` in `l10n_sweep.yaml`.
Setting `safety.allow_unresolved_references: true` disables the protection
entirely and is not recommended.

**Known limitations.** The analysis is syntactic: it does not use the Dart
type system. Names are matched by identifier, so two unrelated fields with
the same name share their values (this only ever keeps more keys). Keys used
outside the scanned source paths — in tests, other packages of a monorepo
(add them to `source_paths`), native code, remote config, or server
responses — are invisible to the analyzer. Flutter's `gen-l10n` / ARB files
and GetX's `.tr` getter are not supported; `doctor` reports them.

## Cleanup safety

- `analyze`, `report`, `doctor` and `clean --dry-run` never write locale files.
- `clean` without `--yes` requires an interactive terminal, shows the plan and
  asks `Remove selected keys? (y/N)` (configurable with
  `safety.require_confirmation`).
- `clean --yes` removes **only** keys classified as `unused` that exist in the
  primary locale, and prints a warning. Dynamic, potentially unused,
  excluded, ignored and orphan keys are never touched, even when named with
  `--keys`.
- Used and excluded keys are refused by the cleanup engine itself, whatever
  the caller asks for.
- If any locale file is invalid JSON, cleanup stops before touching any file
  and prints the file, line and column of the error.
- Every change is computed in memory first, by deleting the exact text of
  the removed members. The result is re-parsed and verified: exactly the
  selected keys are gone and every other value is byte-for-byte unchanged.
  Indentation, key order, line endings (LF/CRLF), byte order marks, escapes,
  Unicode and RTL text (Urdu, Arabic, ...) and JSONC comments are preserved.
- Objects emptied by the removal are removed too
  (`cleanup.remove_empty_parents`); objects that were already empty stay.
- Before writing, each file is compared with the analyzed version and the
  cleanup stops if it changed in the meantime.
- Backups of every affected file are written and verified first
  (`.l10n_sweep/backups/<id>/`), then each file is replaced through a temporary
  file and a rename. If a write fails, the files already written are restored.
- `restore` brings back any backup. Running `clean` again is a no-op.

## Commands

All commands accept `-C, --project <path>`, `-c, --config <file>` and
`--[no-]color` (colors are disabled automatically when output is not a
terminal or `NO_COLOR` is set).

| Command | Description |
| --- | --- |
| `init [--force] [--stdout]` | Generate `l10n_sweep.yaml` from the detected project. |
| `analyze` | Print the analysis. Options: `-v, --verbose`, `-f, --format console\|json\|markdown`, `-o, --output <file>`, `--fail-on-unused`, `--fail-on-missing`, `--fail-on-uncertain`, `--fail-on-undefined`. |
| `clean` | Interactive cleanup. Options: `-n, --dry-run`, `-y, --yes`, `-k, --keys a,b`, `--include-uncertain`, `--[no-]backup`. |
| `report` | Write a report file. Options: `-f, --format`, `-o, --output`, `--stdout`. |
| `doctor` | Check the project setup. |
| `restore` | Restore from a backup. Options: `--list`, `--id <id>`, `-y, --yes`. |

Exit codes: `0` success, `1` a `--fail-on-*` check or `doctor` failed,
`2` the project could not be analyzed or cleaned (invalid configuration,
invalid JSON, refused cleanup), `64` invalid arguments.

## Configuration

`l10n_sweep.yaml` in the project root (or an `l10n_sweep:` section in
`pubspec.yaml`). Every option is optional; without a file, values are
detected from `pubspec.yaml` and the `EasyLocalization(path:,
fallbackLocale:)` widget.

```yaml
l10n_sweep:
  # Directory containing <locale>.json files.
  translations_path: assets/translations

  # Keys are removed based on this locale.
  primary_locale: en

  source_paths:
    - lib

  file_extensions:
    - dart

  # Not scanned for translation calls. Constants declared here (such as the
  # generated LocaleKeys class) are still resolved.
  excluded_paths:
    - lib/generated
    - '**/*.g.dart'

  # Never reported and never removed. Globs: * matches any characters.
  excluded_keys:
    - app.version
    - debug.*

  # Always treated as used.
  ignored_keys:
    - legacy.translation

  # Keys built at run time that must be kept.
  dynamic_key_patterns:
    - 'onboarding.step_*'

  # Wrappers the analyzer cannot follow automatically (for example,
  # functions from another package).
  translation_functions:
    - name: translate        # function, method or class name
      key_argument: 0        # positional index...
    - name: AppText
      key_argument: textKey  # ...or named argument

  output:
    format: console          # console | json | markdown (used by `report`)
    path: build/l10n_sweep_report.json

  safety:
    create_backup: true
    backup_path: .l10n_sweep/backups
    require_confirmation: true
    preserve_uncertain_keys: true       # hide dynamic keys from `clean`
    allow_unresolved_references: false  # keep false; see above

  cleanup:
    remove_empty_parents: true
```

## Multiple locales

```text
assets/translations/
  en.json   <- primary locale
  ur.json
  fr.json
  ar.json
```

- Usage is determined from the code, so a key is used or unused in every
  locale at once.
- Removal is driven by the primary locale: a key is removed from **every**
  locale file that contains it, keeping locales in sync. Locale-specific
  values of all other keys are untouched.
- Keys that exist only in some locales are reported before cleanup
  (`settings.experimental_feature: only in en`).
- Keys missing from a locale (`missing_keys`) and keys a locale has that the
  primary locale lacks (`extra_keys`) are reported per file. Unused extra
  keys are only removed when selected interactively.

## Reports

### JSON

`dart run l10n_sweep report` (or `analyze --format json`) produces a
versioned, machine-readable report:

```json
{
  "schema_version": 1,
  "tool": "l10n_sweep",
  "primary_locale": "en",
  "summary": {
    "translation_files": 2,
    "total_keys": 24,
    "used_keys": 13,
    "unused_keys": 7,
    "orphan_unused_keys": 1,
    "potentially_unused_keys": 0,
    "dynamic_keys": 2,
    "excluded_keys": 1,
    "missing_translations": 1,
    "undefined_keys": 0,
    "unresolved_references": 0,
    "blocking_unresolved_references": 0
  },
  "files": [
    {
      "locale": "ur",
      "path": "assets/translations/ur.json",
      "primary": false,
      "valid": true,
      "keys": 23,
      "unused": 7,
      "missing_keys": ["settings.experimental_feature"],
      "extra_keys": ["ur_only"]
    }
  ],
  "unused_keys": [
    {
      "key": "old.banner",
      "status": "unused",
      "in_primary_locale": true,
      "locales": ["en", "ur"],
      "reasons": ["no reference found"]
    }
  ],
  "dynamic_patterns": [
    {
      "pattern": "sections.*",
      "matched_keys": 2,
      "locations": [
        {"path": "lib/screens/home_screen.dart", "line": 33, "column": 16}
      ]
    }
  ],
  "unresolved_references": [],
  "undefined_keys": [],
  "warnings": [],
  "errors": [],
  "stats": {"dart_files": 4, "usage_files": 3, "translation_calls": 10, "elapsed_ms": 344}
}
```

(Abbreviated: the full report also lists `orphan_unused_keys`,
`potentially_unused_keys`, `dynamic_keys`, `excluded_keys` and `used_keys`.)

### Markdown

`dart run l10n_sweep report --format markdown` writes a summary table,
per-locale table and collapsible key lists, ready for a pull request comment
or `$GITHUB_STEP_SUMMARY`.

## CI/CD integration

Analysis never fails by default. Opt in to the checks you want:

```bash
dart run l10n_sweep analyze --fail-on-unused      # unused keys exist
dart run l10n_sweep analyze --fail-on-missing     # a locale lacks keys
dart run l10n_sweep analyze --fail-on-uncertain   # unresolved calls or keys needing review
dart run l10n_sweep analyze --fail-on-undefined   # code uses keys not in the primary locale
```

GitHub Actions:

```yaml
name: Localization

on:
  pull_request:

jobs:
  l10n:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - run: flutter pub get
      - name: Check translation keys
        run: |
          dart run l10n_sweep analyze --fail-on-unused --fail-on-missing \
            --output build/l10n_sweep_report.md
      - name: Publish summary
        if: always()
        run: cat build/l10n_sweep_report.md >> "$GITHUB_STEP_SUMMARY"
```

`--output` picks the format from the file extension (`.json`, `.md`, `.txt`).

## Programmatic use

The engine has no CLI dependencies and can be used from other tools:

```dart
import 'package:l10n_sweep/l10n_sweep.dart';

void main() {
  final config = const ConfigLoader().load('path/to/flutter_app').config;
  final result = LocalizationAnalyzer(config).analyze();

  for (final key in result.report.unusedKeys) {
    print('${key.key}: ${key.reasons.first}');
  }

  // Optional: remove them, with a backup.
  final engine = CleanupEngine(
    config: config,
    catalog: result.catalog,
    report: result.report,
  );
  final plan = engine.plan(result.report.unusedKeys.map((k) => k.key));
  engine.apply(plan);
}
```

`LocalizationAnalyzer.analyzeSources(...)` analyzes in-memory files (for
editors), and a long-lived `DartSourceParser` only re-parses files whose
contents changed. The JSON report shape is stable within a
`schema_version`.

## Troubleshooting

**Every key is "potentially unused".** Some translation call has a key the
analyzer cannot determine. Run `dart run l10n_sweep doctor` to list them,
then annotate each call (`// l10n_sweep:keys ...` or `// l10n_sweep:ignore`)
or add `dynamic_key_patterns`.

**`clean --yes` removes nothing.** See
[`clean --yes` says "Nothing to remove"](#clean---yes-says-nothing-to-remove).

**The `--verbose` output is too long.** Use `analyze` without `--verbose`
for the summary, `clean` for only the removable keys, or
`report --format markdown` to write everything to a file.

**`l10n_sweep` is not recognized.** Add the pub cache `bin` folder to your
`PATH` (`dart pub global activate` prints it; on Windows it is
`%LOCALAPPDATA%\Pub\Cache\bin`), or run
`dart pub global run l10n_sweep <command>`.

**"No translation calls were found".** Check `source_paths` and
`excluded_paths`. If the app only translates through functions from another
package, list them under `translation_functions`.

**A key I use is reported as unused.** Run `analyze --verbose` to see the
reasons. Common causes: the call is in a file outside `source_paths` or under
`excluded_paths`, or it uses a wrapper from another package. Please open an
issue with a minimal snippet — a false "unused" is treated as a bug.

**"Invalid JSON ... (line X, column Y)".** Fix the file; cleanup refuses to
run while any locale file is invalid. easy_localization's default loader
also rejects comments and trailing commas in `.json` files.

**"Primary locale ... has no file".** Set `primary_locale` to one of the
listed locales, matching the file name (`en-US` matches `en-US.json` and
`en_US.json`).

**Dependency conflict on `analyzer`.** Use
`dart pub global activate l10n_sweep` instead of a dev dependency.

**Undo a cleanup.** `dart run l10n_sweep restore --list`, then
`dart run l10n_sweep restore --id <id>`.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
development setup, architecture and the safety rule every change must keep.

```bash
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

## License

MIT. See [LICENSE](LICENSE).
