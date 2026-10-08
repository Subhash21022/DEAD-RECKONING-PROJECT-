import 'dart:async';
import 'dart:math';
import '../services/sensor_stream_service.dart';

enum CalibrationStatus {
  uncalibrated,
  calibratingStationary,
  calibratedStationary,
  calibratingVehicle,
  fullyCalibrated;

  String get label {
    switch (this) {
      case CalibrationStatus.uncalibrated:
        return 'UNCALIBRATED';
      case CalibrationStatus.calibratingStationary:
        return 'CALIBRATING (HOLD STILL)';
      case CalibrationStatus.calibratedStationary:
        return 'STATIONARY READY';
      case CalibrationStatus.calibratingVehicle:
        return 'ALIGNING VEHICLE';
      case CalibrationStatus.fullyCalibrated:
        return 'CALIBRATED';
    }
  }
}

class CalibrationProfile {
  final List<double> gravityVector; // [gx, gy, gz]
  final List<double> gDown;         // Normalized unit gravity vector
  final List<double> gyroBias;       // [bx, by, bz] rad/s
  final double accelVariance;
  final double gyroVariance;
  final double phoneToVehicleYawOffsetRad;
  final DateTime timestamp;

  const CalibrationProfile({
    required this.gravityVector,
    required this.gDown,
    required this.gyroBias,
    required this.accelVariance,
    required this.gyroVariance,
    required this.phoneToVehicleYawOffsetRad,
    required this.timestamp,
  });

  /// Factory default if calibration hasn't run yet
  factory CalibrationProfile.defaultProfile() {
    return CalibrationProfile(
      gravityVector: [0.0, 9.80665, 0.0],
      gDown: [0.0, 1.0, 0.0],
      gyroBias: [0.0, 0.0, 0.0],
      accelVariance: 0.05,
      gyroVariance: 0.005,
      phoneToVehicleYawOffsetRad: 0.0,
      timestamp: DateTime.now(),
    );
  }

  /// Projects raw 3-axis gyro onto true vertical gravity vector
  /// Eliminates tilt and orientation distortion (Arbitrary Mounting)
  double projectYawRate(double gx, double gy, double gz) {
    // omega_yaw = -(gyro_raw dot g_down)
    final dot = gx * gDown[0] + gy * gDown[1] + gz * gDown[2];
    final biasProj = gyroBias[0] * gDown[0] + gyroBias[1] * gDown[1] + gyroBias[2] * gDown[2];
    return -(dot - biasProj);
  }
}

/// PhoneCalibrationService executes a high-precision IMU calibration at mission start.
class PhoneCalibrationService {
  final SensorStreamService _sensorService;

  CalibrationStatus _status = CalibrationStatus.uncalibrated;
  CalibrationStatus get status => _status;

  CalibrationProfile _profile = CalibrationProfile.defaultProfile();
  CalibrationProfile get profile => _profile;

  StreamSubscription<ImuSample>? _sub;
  final List<ImuSample> _samples = [];
  Timer? _countdownTimer;
  int _secondsRemaining = 0;
  int get secondsRemaining => _secondsRemaining;

  final _statusController = StreamController<CalibrationStatus>.broadcast();
  Stream<CalibrationStatus> get statusStream => _statusController.stream;

  final _progressController = StreamController<double>.broadcast();
  Stream<double> get progressStream => _progressController.stream;

  PhoneCalibrationService({required SensorStreamService sensorService})
      : _sensorService = sensorService;

  /// Starts 3.5-second stationary calibration.
  /// Phone must remain still on mount or hand.
  Future<bool> startStationaryCalibration({int durationSeconds = 4}) async {
    _status = CalibrationStatus.calibratingStationary;
    _statusController.add(_status);
    _samples.clear();
    _secondsRemaining = durationSeconds;
    _progressController.add(0.0);

    final totalMillis = durationSeconds * 1000;
    int elapsedMillis = 0;

    final completer = Completer<bool>();

    _sub?.cancel();
    _sub = _sensorService.imuStream.listen((sample) {
      if (_status == CalibrationStatus.calibratingStationary) {
        _samples.add(sample);
      }
    });

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      elapsedMillis += 100;
      final progress = min(1.0, elapsedMillis / totalMillis);
      _progressController.add(progress);
      _secondsRemaining = max(0, ((totalMillis - elapsedMillis) / 1000).ceil());

      if (elapsedMillis >= totalMillis) {
        timer.cancel();
        _sub?.cancel();
        _sub = null;
        _finalizeStationaryCalibration();
        completer.complete(true);
      }
    });

    return completer.future;
  }

  void _finalizeStationaryCalibration() {
    if (_samples.isEmpty) {
      _status = CalibrationStatus.uncalibrated;
      _statusController.add(_status);
      return;
    }

    int n = _samples.length;
    double sumAx = 0, sumAy = 0, sumAz = 0;
    double sumGx = 0, sumGy = 0, sumGz = 0;

    for (var s in _samples) {
      sumAx += s.ax;
      sumAy += s.ay;
      sumAz += s.az;
      sumGx += s.gx;
      sumGy += s.gy;
      sumGz += s.gz;
    }

    final meanAx = sumAx / n;
    final meanAy = sumAy / n;
    final meanAz = sumAz / n;
    final meanGx = sumGx / n;
    final meanGy = sumGy / n;
    final meanGz = sumGz / n;

    // Variance calculation
    double varAx = 0, varAy = 0, varAz = 0;
    double varGx = 0, varGy = 0, varGz = 0;
    for (var s in _samples) {
      varAx += (s.ax - meanAx) * (s.ax - meanAx);
      varAy += (s.ay - meanAy) * (s.ay - meanAy);
      varAz += (s.az - meanAz) * (s.az - meanAz);
      varGx += (s.gx - meanGx) * (s.gx - meanGx);
      varGy += (s.gy - meanGy) * (s.gy - meanGy);
      varGz += (s.gz - meanGz) * (s.gz - meanGz);
    }
    final maxAccVar = max(varAx / n, max(varAy / n, varAz / n));
    final gyroVar = sqrt((varGx + varGy + varGz) / n);

    // Gravity vector & downward unit vector
    final gravNorm = sqrt(meanAx * meanAx + meanAy * meanAy + meanAz * meanAz);
    final safeNorm = gravNorm > 1.0 ? gravNorm : 9.80665;
    final gDown = [meanAx / safeNorm, meanAy / safeNorm, meanAz / safeNorm];

    _profile = CalibrationProfile(
      gravityVector: [meanAx, meanAy, meanAz],
      gDown: gDown,
      gyroBias: [meanGx, meanGy, meanGz],
      accelVariance: maxAccVar,
      gyroVariance: gyroVar,
      phoneToVehicleYawOffsetRad: 0.0,
      timestamp: DateTime.now(),
    );

    _status = CalibrationStatus.calibratedStationary;
    _statusController.add(_status);
    _progressController.add(1.0);
  }

  /// Sets vehicle yaw alignment offset (comparing COG to phone integrated heading)
  void setVehicleAlignmentOffset(double offsetRad) {
    _profile = CalibrationProfile(
      gravityVector: _profile.gravityVector,
      gDown: _profile.gDown,
      gyroBias: _profile.gyroBias,
      accelVariance: _profile.accelVariance,
      gyroVariance: _profile.gyroVariance,
      phoneToVehicleYawOffsetRad: offsetRad,
      timestamp: DateTime.now(),
    );
    _status = CalibrationStatus.fullyCalibrated;
    _statusController.add(_status);
  }

  void dispose() {
    _countdownTimer?.cancel();
    _sub?.cancel();
    _statusController.close();
    _progressController.close();
  }
}
