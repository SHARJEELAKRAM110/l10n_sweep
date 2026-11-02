import 'dart:convert';

import '../models/analysis_report.dart';

/// Renders an [AnalysisReport] as machine-readable JSON.
///
/// The structure is versioned by `schema_version`; fields are only added in
/// minor releases.
class JsonReporter {
  const JsonReporter();

  String render(AnalysisReport report) =>
      '${const JsonEncoder.withIndent('  ').convert(report.toJson())}\n';
}
