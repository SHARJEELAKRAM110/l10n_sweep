# l10n_sweep examples

## Command line

From a Flutter project that uses easy_localization:

```bash
dart pub add --dev l10n_sweep
dart run l10n_sweep init
dart run l10n_sweep doctor
dart run l10n_sweep analyze
dart run l10n_sweep clean --dry-run
dart run l10n_sweep clean
```

## Programmatic use

[`l10n_sweep_example.dart`](l10n_sweep_example.dart) runs the analysis engine
directly and previews a cleanup:

```bash
dart run example/l10n_sweep_example.dart path/to/flutter_app
```

A complete sample Flutter app lives in
[`test/fixtures/sample_flutter_app`](../test/fixtures/sample_flutter_app).
