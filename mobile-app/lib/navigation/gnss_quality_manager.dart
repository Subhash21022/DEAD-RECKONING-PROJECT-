import 'dart:async';
import 'dart:math';
import '../services/gnss_service.dart';

enum GnssState {
  good,
  degraded,
  lost,
  recovering;

  String get label {
    switch (this) {
      case GnssState.good:
        return 'GOOD';
      case GnssState.degraded:
        return 'DEGRADED';
      case GnssState.lost:
        return 'LOST';
      case GnssState.recovering:
        return 'RECOVERING';
    }
  }

  bool get isUsable => this == GnssState.good || this == GnssState.degraded || this == GnssState.recovering;
}

class GnssQualityReport {
  final GnssState state;
  final double updateAgeS;
  final double accuracyM;
  final double speedMps;
  final double bearingDeg;
  final int consecutiveGoodFixes;
  final int estimatedSatellites;
  final bool isServiceEnabled;
  final String stateReason;
  final GnssReading? latestReading;

  const GnssQualityReport({
    required this.state,
    required this.updateAgeS,
    required this.accuracyM,
    required this.speedMps,
    required this.bearingDeg,
    required this.consecutiveGoodFixes,
    required this.estimatedSatellites,
    required this.isServiceEnabled,
    required this.stateReason,
    this.latestReading,
  });
}

/// GNSSQualityManager independently monitors hardware satellite fixes.
/// 
/// ARCHITECTURAL RULE:
/// GNSS status is evaluated ONLY from satellite fix age, accuracy, freshness,
/// and geometric jumps with temporal hysteresis. It is 100% INDEPENDENT of network.
class GnssQualityManager {
  final GnssService _gnssService;

  StreamSubscription<GnssReading>? _gnssSub;
  StreamSubscription<bool>? _serviceStatusSub;
  Timer? _watchdogTimer;

  GnssState _state = GnssState.lost;
  GnssState get state => _state;

  GnssReading? _latestReading;
  GnssReading? get latestReading => _latestReading;

  DateTime? _lastFixTime;
  double? _prevLat;
  double? _prevLon;
  DateTime? _prevFixTime;

  // Hysteresis counters
  int _consecutiveGoodFixes = 0;
  DateTime? _degradedStartTime;
  DateTime? _staleStartTime;

  final _controller = StreamController<GnssQualityReport>.broadcast();
  Stream<GnssQualityReport> get reportStream => _controller.stream;

  GnssQualityManager({required GnssService gnssService})
      : _gnssService = gnssService;

  void start() {
    _gnssSub = _gnssService.gnssStream.listen(_onReading);
    _serviceStatusSub = _gnssService.serviceStatusStream.listen((enabled) {
      if (!enabled) {
        _setImmediateLost('Location service disabled on device');
      }
    });

    // 250ms periodic watchdog evaluates fix age and time-based hysteresis
    _watchdogTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _evaluateWatchdog();
    });
  }

  void _onReading(GnssReading reading) {
    final now = DateTime.now();

    // 1. Sanity check: detect impossible coordinate jumps (> 55 m/s or ~200 km/h)
    if (_prevLat != null && _prevLon != null && _prevFixTime != null) {
      final dt = now.difference(_prevFixTime!).inMilliseconds / 1000.0;
      if (dt > 0.05) {
        final distM = _haversineM(_prevLat!, _prevLon!, reading.lat, reading.lon);
        final impliedSpeed = distM / dt;
        if (impliedSpeed > 60.0 && reading.accuracyM > 15.0) {
          // Reject wild single-sample multipath jump
          return;
        }
      }
    }

    _prevLat = reading.lat;
    _prevLon = reading.lon;
    _prevFixTime = now;
    _lastFixTime = now;
    _latestReading = reading;

    // Reset stale timer on fresh fix
    _staleStartTime = null;

    final acc = reading.accuracyM;

    if (acc <= 15.0) {
      _consecutiveGoodFixes++;
      _degradedStartTime = null;

      if (_state == GnssState.lost || _state == GnssState.recovering) {
        if (_consecutiveGoodFixes >= 4) {
          _transitionTo(GnssState.good, 'Acquired 4+ reliable consecutive fixes');
        } else {
          _transitionTo(GnssState.recovering, 'Recovering GNSS: $_consecutiveGoodFixes/4 fixes');
        }
      } else if (_state == GnssState.degraded) {
        if (_consecutiveGoodFixes >= 3) {
          _transitionTo(GnssState.good, 'Restored high-accuracy fix (<=15m)');
        }
      } else {
        _emitReport('Good continuous fix (±${acc.toStringAsFixed(1)}m)');
      }
    } else if (acc <= 40.0) {
      _consecutiveGoodFixes = 0;
      _degradedStartTime ??= now;

      // Hysteresis: require sustained degradation for >= 1.2s before leaving GOOD
      if (_state == GnssState.good) {
        if (now.difference(_degradedStartTime!).inMilliseconds >= 1200) {
          _transitionTo(GnssState.degraded, 'Accuracy degraded to ${acc.toStringAsFixed(1)}m for >1.2s');
        }
      } else if (_state == GnssState.lost || _state == GnssState.recovering) {
        _transitionTo(GnssState.degraded, 'Intermittent fix acquired (±${acc.toStringAsFixed(1)}m)');
      } else {
        _emitReport('Degraded accuracy (±${acc.toStringAsFixed(1)}m)');
      }
    } else {
      // Poor accuracy (> 40m)
      _consecutiveGoodFixes = 0;
      _degradedStartTime ??= now;
      if (now.difference(_degradedStartTime!).inMilliseconds >= 2500) {
        _transitionTo(GnssState.lost, 'Accuracy sustained >40m for >2.5s');
      } else {
        _transitionTo(GnssState.degraded, 'Poor accuracy (±${acc.toStringAsFixed(1)}m)');
      }
    }
  }

  void _evaluateWatchdog() {
    if (!_gnssService.isServiceEnabled) {
      if (_state != GnssState.lost) {
        _setImmediateLost('Location service disabled');
      }
      return;
    }

    final now = DateTime.now();
    if (_lastFixTime == null) {
      if (_state != GnssState.lost) {
        _transitionTo(GnssState.lost, 'No initial fix');
      }
      return;
    }

    final ageS = now.difference(_lastFixTime!).inMilliseconds / 1000.0;

    // Timeout-based State Transitions
    if (ageS > 4.5) {
      _consecutiveGoodFixes = 0;
      if (_state != GnssState.lost) {
        _transitionTo(GnssState.lost, 'No fix for ${ageS.toStringAsFixed(1)}s (>4.5s)');
      }
    } else if (ageS > 2.0) {
      _consecutiveGoodFixes = 0;
      if (_state == GnssState.good) {
        _transitionTo(GnssState.degraded, 'Fix stale (${ageS.toStringAsFixed(1)}s age)');
      }
    }

    _emitReport('Watchdog tick (age: ${ageS.toStringAsFixed(1)}s)');
  }

  void _setImmediateLost(String reason) {
    _consecutiveGoodFixes = 0;
    _degradedStartTime = null;
    _staleStartTime = null;
    _transitionTo(GnssState.lost, reason);
  }

  void _transitionTo(GnssState newState, String reason) {
    if (_state != newState) {
      _state = newState;
      _emitReport(reason);
    }
  }

  static int _estimateSatellites(double? accuracyM) {
    if (accuracyM == null || accuracyM > 900) return 0;
    if (accuracyM <= 4.0) return 14;
    if (accuracyM <= 8.0) return 11;
    if (accuracyM <= 15.0) return 8;
    if (accuracyM <= 30.0) return 6;
    if (accuracyM <= 100.0) return 4;
    return 2;
  }

  void _emitReport(String reason) {
    final now = DateTime.now();
    final ageS = _lastFixTime != null
        ? now.difference(_lastFixTime!).inMilliseconds / 1000.0
        : 999.0;

    final acc = _latestReading?.accuracyM;
    final report = GnssQualityReport(
      state: _state,
      updateAgeS: ageS,
      accuracyM: acc ?? 999.0,
      speedMps: _latestReading?.speedMps ?? 0.0,
      bearingDeg: _latestReading?.bearingDeg ?? 0.0,
      consecutiveGoodFixes: _consecutiveGoodFixes,
      estimatedSatellites: _state == GnssState.lost ? 0 : _estimateSatellites(acc),
      isServiceEnabled: _gnssService.isServiceEnabled,
      stateReason: reason,
      latestReading: _latestReading,
    );

    _controller.add(report);
  }

  static double _haversineM(double lat1, double lon1, double lat2, double lon2) {
    const rEarth = 6378137.0;
    final phi1 = lat1 * (pi / 180.0);
    final phi2 = lat2 * (pi / 180.0);
    final dphi = (lat2 - lat1) * (pi / 180.0);
    final dlam = (lon2 - lon1) * (pi / 180.0);

    final a = sin(dphi / 2.0) * sin(dphi / 2.0) +
        cos(phi1) * cos(phi2) * sin(dlam / 2.0) * sin(dlam / 2.0);
    return 2.0 * rEarth * asin(sqrt(min(1.0, a)));
  }

  void stop() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _gnssSub?.cancel();
    _gnssSub = null;
    _serviceStatusSub?.cancel();
    _serviceStatusSub = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
