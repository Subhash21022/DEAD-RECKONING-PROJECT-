import 'dart:math';

/// Earth radius in metres (WGS-84 semi-major axis).
const double _rEarth = 6378137.0;

/// Result returned by [MapMatcher.match].
///
/// When the EKF position was successfully snapped to a trail segment,
/// [isSnapped] is `true` and [lat]/[lon] contain the corrected coordinates.
/// Otherwise [lat]/[lon] echo the input and [isSnapped] is `false`.
class MatchResult {
  /// Latitude in degrees (snapped or original).
  final double lat;

  /// Longitude in degrees (snapped or original).
  final double lon;

  /// Whether the position was snapped to a road/trail segment.
  final bool isSnapped;

  const MatchResult({
    required this.lat,
    required this.lon,
    required this.isSnapped,
  });
}

/// Internal representation of one straight trail segment in local ENU metres.
class _RoadSegment {
  /// Segment start point [East, North] in metres from the local origin.
  final List<double> p1;

  /// Segment end point [East, North] in metres from the local origin.
  final List<double> p2;

  /// Bearing of the segment in degrees clockwise from north (0-360).
  final double bearing;

  /// Axis-aligned bounding box inflated by the snap distance:
  /// [minE, maxE, minN, maxN].
  final List<double> bbox;

  const _RoadSegment({
    required this.p1,
    required this.p2,
    required this.bearing,
    required this.bbox,
  });
}

/// Snaps EKF-fused positions to a previously recorded trail.
///
/// The matcher converts WGS-84 coordinates to a local East-North plane,
/// projects the query point onto every candidate segment that passes both a
/// bounding-box pre-filter and a heading compatibility check, and returns the
/// closest projection if it falls within [maxSnapDist] metres.
///
/// ### Typical usage
/// ```dart
/// final mm = MapMatcher();
/// mm.loadTrajectoryAsTrail(recordedLats, recordedLons);
/// final result = mm.match(ekfLat, ekfLon, headingDeg);
/// if (result.isSnapped) { /* use result.lat, result.lon */ }
/// ```
class MapMatcher {
  /// Maximum perpendicular distance (m) to snap to a segment.
  final double maxSnapDist;

  /// Maximum heading difference (deg) to consider a segment compatible.
  final double maxHeadingDiff;

  /// Minimum spacing (m) used to simplify the loaded trajectory.
  final double minSpacing;

  List<_RoadSegment> _roadSegments = [];
  double? _originLat;
  double? _originLon;
  double _cosLat0 = 1.0;

  MapMatcher({
    double maxSnapDistanceM = 30.0,
    double maxHeadingDiffDeg = 55.0,
    double minSegmentSpacingM = 15.0,
  })  : maxSnapDist = maxSnapDistanceM,
        maxHeadingDiff = maxHeadingDiffDeg,
        minSpacing = minSegmentSpacingM;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Haversine distance in metres between two WGS-84 points.
  static double haversineM(
      double lat1, double lon1, double lat2, double lon2) {
    final phi1 = lat1 * pi / 180.0;
    final phi2 = lat2 * pi / 180.0;
    final dphi = (lat2 - lat1) * pi / 180.0;
    final dlam = (lon2 - lon1) * pi / 180.0;
    final a = sin(dphi / 2.0) * sin(dphi / 2.0) +
        cos(phi1) * cos(phi2) * sin(dlam / 2.0) * sin(dlam / 2.0);
    return 2.0 * _rEarth * atan2(sqrt(a), sqrt(1.0 - a));
  }

  /// Projects point [p] onto the segment [a]--[b] (all in 2-D metres).
  ///
  /// Returns `(projection, distance)` where *projection* is the closest point
  /// on the segment and *distance* is the Euclidean distance from [p] to that
  /// point.
  static (List<double>, double) _pointToSegmentProjection(
      List<double> p, List<double> a, List<double> b) {
    final abE = b[0] - a[0];
    final abN = b[1] - a[1];
    final abLenSq = abE * abE + abN * abN;

    if (abLenSq < 1e-4) {
      final dE = p[0] - a[0];
      final dN = p[1] - a[1];
      return (List<double>.of(a), sqrt(dE * dE + dN * dN));
    }

    final paE = p[0] - a[0];
    final paN = p[1] - a[1];
    var t = (paE * abE + paN * abN) / abLenSq;
    t = t.clamp(0.0, 1.0);

    final projE = a[0] + t * abE;
    final projN = a[1] + t * abN;
    final dE = p[0] - projE;
    final dN = p[1] - projN;
    return ([projE, projN], sqrt(dE * dE + dN * dN));
  }

  // ---------------------------------------------------------------------------
  // Trail loading
  // ---------------------------------------------------------------------------

  /// Loads a recorded trajectory as the reference trail for snapping.
  ///
  /// The trajectory is simplified by dropping points closer than [minSpacing]
  /// metres to the last accepted point (except for the final point, which is
  /// always kept). Each surviving pair of consecutive points becomes a
  /// [_RoadSegment].
  void loadTrajectoryAsTrail(List<double> lats, List<double> lons) {
    if (lats.length < 2) return;

    _originLat = lats[0];
    _originLon = lons[0];
    _cosLat0 = cos(lats[0] * pi / 180.0);
    _roadSegments = [];

    // -- Simplify by minimum spacing ------------------------------------------
    final simpLats = <double>[lats[0]];
    final simpLons = <double>[lons[0]];

    for (var i = 1; i < lats.length; i++) {
      final d = haversineM(simpLats.last, simpLons.last, lats[i], lons[i]);
      if (d >= minSpacing || i == lats.length - 1) {
        simpLats.add(lats[i]);
        simpLons.add(lons[i]);
      }
    }

    // -- Convert to local East-North metres -----------------------------------
    final pts = <List<double>>[];
    for (var i = 0; i < simpLats.length; i++) {
      final pN = (simpLats[i] - _originLat!) * pi / 180.0 * _rEarth;
      final pE = (simpLons[i] - _originLon!) * pi / 180.0 * _rEarth * _cosLat0;
      pts.add([pE, pN]);
    }

    // -- Build segments -------------------------------------------------------
    for (var i = 0; i < pts.length - 1; i++) {
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final dE = p2[0] - p1[0];
      final dN = p2[1] - p1[1];
      final segLen = sqrt(dE * dE + dN * dN);
      if (segLen < 1.0) continue;

      final bearing = (atan2(dE, dN) * 180.0 / pi + 360.0) % 360.0;

      _roadSegments.add(_RoadSegment(
        p1: p1,
        p2: p2,
        bearing: bearing,
        bbox: [
          min(p1[0], p2[0]) - maxSnapDist,
          max(p1[0], p2[0]) + maxSnapDist,
          min(p1[1], p2[1]) - maxSnapDist,
          max(p1[1], p2[1]) + maxSnapDist,
        ],
      ));
    }
  }

  // ---------------------------------------------------------------------------
  // Matching
  // ---------------------------------------------------------------------------

  /// Attempts to snap the given EKF position to the closest compatible trail
  /// segment.
  ///
  /// [ekfLat] and [ekfLon] are WGS-84 degrees from the EKF fusion output.
  /// [headingDeg] is the device heading in degrees clockwise from north.
  ///
  /// Returns a [MatchResult] whose [MatchResult.isSnapped] flag indicates
  /// whether the position was corrected.
  MatchResult match(double ekfLat, double ekfLon, double headingDeg) {
    if (_roadSegments.isEmpty || _originLat == null) {
      return MatchResult(lat: ekfLat, lon: ekfLon, isSnapped: false);
    }

    final pN = (ekfLat - _originLat!) * pi / 180.0 * _rEarth;
    final pE = (ekfLon - _originLon!) * pi / 180.0 * _rEarth * _cosLat0;

    var bestDist = double.infinity;
    List<double>? bestProj;

    for (final seg in _roadSegments) {
      final bb = seg.bbox;
      // Bounding-box pre-filter: [minE, maxE, minN, maxN]
      if (!(bb[0] <= pE && pE <= bb[1] && bb[2] <= pN && pN <= bb[3])) {
        continue;
      }

      // Heading compatibility (works for both travel directions)
      final hDiff =
          ((headingDeg - seg.bearing + 180.0) % 360.0 - 180.0).abs();
      if (hDiff > maxHeadingDiff && (180.0 - hDiff) > maxHeadingDiff) {
        continue;
      }

      final (proj, dist) =
          _pointToSegmentProjection([pE, pN], seg.p1, seg.p2);
      if (dist < bestDist) {
        bestDist = dist;
        bestProj = proj;
      }
    }

    if (bestDist <= maxSnapDist && bestProj != null) {
      final lat =
          _originLat! + bestProj[1] / _rEarth * 180.0 / pi;
      final lon =
          _originLon! + bestProj[0] / (_rEarth * _cosLat0) * 180.0 / pi;
      return MatchResult(lat: lat, lon: lon, isSnapped: true);
    }

    return MatchResult(lat: ekfLat, lon: ekfLon, isSnapped: false);
  }
}
