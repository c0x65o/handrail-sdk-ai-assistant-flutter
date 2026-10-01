import 'package:flutter/widgets.dart';

/// Distinguish reader movement from layout corrections and our own tail/anchor
/// movement. Once reading history, only reaching the tail resumes following.
class HandrailTranscriptScrollFollow {
  double? _pixels, _extent, _viewport;

  void capture(ScrollMetrics metrics) {
    _pixels = metrics.pixels;
    _extent = metrics.maxScrollExtent;
    _viewport = metrics.viewportDimension;
  }

  bool update(ScrollMetrics metrics, bool following, {bool hasNewer = false}) {
    final previous = _pixels;
    final layoutChanged =
        _extent != metrics.maxScrollExtent ||
        _viewport != metrics.viewportDimension;
    capture(metrics);
    if (previous == null || layoutChanged || metrics.pixels == previous) {
      return following;
    }
    if (metrics.pixels < previous && metrics.extentAfter > 2) return false;
    if (metrics.pixels > previous && metrics.extentAfter <= 2 && !hasNewer) {
      return true;
    }
    return following;
  }
}
