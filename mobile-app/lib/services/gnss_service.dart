import 'dart:async';
import 'package:geolocator/geolocator.dart';
import '../core/constants.dart';

class GnssReading {
  final double lat;
  final double lon;
  final double speedMps;
  final double accuracyM;
  final double bearingDeg;
  final double timestampS;

  const GnssReading({
    required this.lat,
    required this.lon,
    required this.speedMps,
    required this.accuracyM,
    required this.bearingDeg,
    required this.timestampS,
  });

  bool get isGood => accuracyM <= AppConstants.gnssGoodAccuracyM;
  bool get isDegraded =>
      accuracyM > AppConstants.gnssGoodAccuracyM &&
      accuracyM <= AppConstants.gnssDegradedAccuracyM;
  bool get isLost => accuracyM > AppConstants.gnssDegradedAccuracyM;

  String get qualityLabel {
    if (isGood) return 'GOOD';
    if (isDegraded) return 'DEGRADED';
    return 'LOST';
  }
}

class GnssService {
  StreamSubscription<Position>? _positionSub;
  StreamSubscription<ServiceStatus>? _serviceStatusSub;
  Timer? _servicePollTimer;
  final _controller = StreamController<GnssReading>.broadcast();
  Stream<GnssReading> get gnssStream => _controller.stream;

  final _serviceStatusController = StreamController<bool>.broadcast();
  Stream<bool> get serviceStatusStream => _serviceStatusController.stream;

  GnssReading? _lastReading;
  GnssReading? get lastReading => _lastReading;

  bool _isServiceEnabled = true;
  bool get isServiceEnabled => _isServiceEnabled;

  bool _running = false;
  String? _permissionError;
  String? get permissionError => _permissionError;

  Future<bool> checkPermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    _isServiceEnabled = serviceEnabled;
    if (!serviceEnabled) {
      _permissionError = 'Location services are disabled';
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _permissionError = 'Location permission denied';
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      _permissionError = 'Location permission permanently denied';
      return false;
    }

    _permissionError = null;
    return true;
  }

  Future<void> start() async {
    if (_running) return;

    final hasPermission = await checkPermissions();
    if (!hasPermission) return;

    _running = true;

    // Listen to real-time Android location toggle changes (On/Off)
    _serviceStatusSub = Geolocator.getServiceStatusStream().listen((status) {
      final enabled = (status == ServiceStatus.enabled);
      _isServiceEnabled = enabled;
      if (!enabled) {
        _lastReading = null;
      }
      _serviceStatusController.add(enabled);
    });

    // Active polling fallback: Some Android OEMs do not broadcast ServiceStatusStream reliably
    _servicePollTimer?.cancel();
    _servicePollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final enabled = await Geolocator.isLocationServiceEnabled();
        if (enabled != _isServiceEnabled) {
          _isServiceEnabled = enabled;
          if (!enabled) {
            _lastReading = null;
          }
          _serviceStatusController.add(enabled);
        }
      } catch (_) {}
    });

    // 1. Instant Calibration: Grab cached last known position in <10ms
    try {
      final lastPos = await Geolocator.getLastKnownPosition();
      if (lastPos != null && _running) {
        _onPosition(lastPos);
      }
    } catch (_) {}

    // 2. Active Fix Request: Wake up GNSS hardware immediately
    Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.bestForNavigation,
      timeLimit: const Duration(seconds: 4),
    ).then((pos) {
      if (_running) _onPosition(pos);
    }).catchError((_) {});

    // 3. High-frequency position stream (500ms intervals)
    final locationSettings = AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
      intervalDuration: const Duration(milliseconds: 500),
      forceLocationManager: false,
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationText: 'Forest Ranger Nav tracking location',
        notificationTitle: 'Active Navigation',
        enableWakeLock: true,
      ),
    );

    _positionSub = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      _onPosition,
      onError: (error) {
        _permissionError = error.toString();
      },
    );
  }

  void _onPosition(Position position) {
    if (position.accuracy > 200.0) return;

    _isServiceEnabled = true;

    // Clamp sub-0.5 m/s GPS speed to 0.0 (Android GPS noise when stationary)
    final double speed = position.speed >= 0.5 ? position.speed : 0.0;

    final reading = GnssReading(
      lat: position.latitude,
      lon: position.longitude,
      speedMps: speed,
      accuracyM: position.accuracy,
      bearingDeg: position.heading >= 0 ? position.heading : 0.0,
      timestampS: position.timestamp.microsecondsSinceEpoch / 1e6,
    );

    _lastReading = reading;
    _controller.add(reading);
  }

  void stop() {
    _running = false;
    _positionSub?.cancel();
    _positionSub = null;
    _serviceStatusSub?.cancel();
    _serviceStatusSub = null;
    _servicePollTimer?.cancel();
    _servicePollTimer = null;
    _lastReading = null;
  }

  void dispose() {
    stop();
    _controller.close();
    _serviceStatusController.close();
  }
}
