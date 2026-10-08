import 'dart:math';
import 'dart:collection';
import 'phone_calibration_service.dart';

/// Result returned by [ZuptDetector.addSample] on each IMU update.
///
/// Contains the stationary decision, confidence score, current estimated
/// gravity-down unit vector, and the gyroscope yaw-bias estimate accumulated
/// during stationary periods.
class ZuptResult {
  /// Whether the device is currently classified as stationary.
  final bool isStationary;

  /// Confidence in the stationary decision (0.0 when moving, 0.95 when
  /// stationary for at least [ZuptDetector.minConsecutive] samples).
  final double confidence;

  /// Unit vector pointing in the gravity (down) direction in the sensor frame.
  /// Length-3 list: [x, y, z].
  final List<double> gDown;

  /// Running low-pass estimate of the gyroscope yaw-rate bias (rad/s),
  /// updated only during confirmed stationary periods.
  final double gyroBiasRads;

  const ZuptResult({
    required this.isStationary,
    required this.confidence,
    required this.gDown,
    required this.gyroBiasRads,
  });

  @override
  String toString() =>
      'ZuptResult(still=$isStationary, conf=${confidence.toStringAsFixed(2)}, '
      'bias=${gyroBiasRads.toStringAsFixed(6)})';
}

/// Zero-velocity update (ZUPT) detector for pedestrian / vehicle inertial
/// navigation.
///
/// Consumes raw accelerometer and gyroscope samples at a fixed rate and
/// determines whether the device is stationary by checking smoothed
/// accelerometer standard deviation, gyroscope norm, and proximity to 1 g.
///
/// Ported faithfully from `edge-engine/engine/zupt.py`.
///
/// Usage:
/// ```dart
/// final zupt = ZuptDetector();
/// // optionally: zupt.initFromCalibration(profile);
/// for (final sample in imuStream) {
///   final result = zupt.addSample(
///     sample.ax, sample.ay, sample.az,
///     sample.gx, sample.gy, sample.gz,
///   );
///   if (result != null && result.isStationary) { /* apply ZUPT */ }
/// }
/// ```
class ZuptDetector {
  // ---- configuration ----

  /// IMU sample rate (Hz). Used for documentation; the detector is
  /// sample-count-driven, not time-driven.
  final double sampleRateHz;

  /// Number of samples in the sliding analysis window.
  final int windowSize;

  /// Threshold on the maximum component of the smoothed accelerometer
  /// standard-deviation vector. Below this the accelerometer is considered
  /// quiet.
  final double lpAccStdThresh;

  /// Threshold on the mean smoothed-gyroscope norm (rad/s). Below this the
  /// gyroscope is considered quiet.
  final double lpGyroNormThresh;

  /// Allowed deviation of the mean accelerometer magnitude from 9.80665 m/s^2.
  final double gravityMargin;

  /// Minimum consecutive still-instant samples before declaring stationary.
  final int minConsecutive;

  // ---- ring buffers ----

  final Queue<List<double>> _rawAccBuf;
  final Queue<List<double>> _rawGyrBuf;
  final Queue<List<double>> _smoothedAccBuf;
  final Queue<List<double>> _smoothedGyrBuf;

  // ---- low-pass smoothed state ----

  List<double> _sAcc;
  List<double> _sGyr;

  // ---- outputs / running estimates ----

  int _stationaryCounter = 0;
  bool _isStationary = false;
  double _currentGyroBiasRads = 0.0;
  bool _gDownInitialized = false;
  List<double> _gDown;

  /// Creates a ZUPT detector with the given tuning parameters.
  ///
  /// All thresholds default to the values validated in the Python reference
  /// implementation.
  ZuptDetector({
    this.sampleRateHz = 100.0,
    this.windowSize = 50,
    this.lpAccStdThresh = 0.35,
    this.lpGyroNormThresh = 0.045,
    this.gravityMargin = 1.8,
    this.minConsecutive = 15,
    CalibrationProfile? calibration,
  })  : _rawAccBuf = Queue<List<double>>(),
        _rawGyrBuf = Queue<List<double>>(),
        _smoothedAccBuf = Queue<List<double>>(),
        _smoothedGyrBuf = Queue<List<double>>(),
        _sAcc = <double>[0.0, 9.81, 0.0],
        _sGyr = <double>[0.0, 0.0, 0.0],
        _gDown = _normalizeVec3(<double>[-0.0602, 0.9098, 0.4106]) {
    if (calibration != null) {
      initFromCalibration(calibration);
    }
  }

  /// Initialise the gravity-down vector from a [CalibrationProfile].
  ///
  /// Call this once before feeding samples if a recent calibration is
  /// available. The profile's `gDown` is expected to be a normalised
  /// unit vector of length 3.
  void initFromCalibration(CalibrationProfile profile) {
    final gd = profile.gDown;
    if (gd.length == 3) {
      final norm = _vecNorm(gd);
      if (norm > 1e-9) {
        _gDown = _scaleVec3(gd, 1.0 / norm);
        _gDownInitialized = true;
      }
    }
  }

  /// Feed one raw IMU sample and obtain the ZUPT decision.
  ///
  /// [ax], [ay], [az] are accelerometer readings in m/s^2 (sensor frame).
  /// [gx], [gy], [gz] are gyroscope readings in rad/s (sensor frame).
  ///
  /// Optional [neuralSpeedMps] and [neuralClass] allow a neural motion
  /// classifier to relax the physical-stillness check when the classifier
  /// reports standing-still (class 0) or very low speed.
  ///
  /// Returns `null` until the analysis window is full (first [windowSize] - 1
  /// samples), then returns a [ZuptResult] every sample thereafter.
  ZuptResult? addSample(
    double ax,
    double ay,
    double az,
    double gx,
    double gy,
    double gz, {
    double? neuralSpeedMps,
    int? neuralClass,
  }) {
    final a = <double>[ax, ay, az];
    final g = <double>[gx, gy, gz];

    // ---- low-pass smoothing ----
    if (_rawAccBuf.isEmpty) {
      _sAcc = List<double>.from(a);
      _sGyr = List<double>.from(g);
    } else {
      const double alpha = 0.15;
      _sAcc = _lerpVec3(_sAcc, a, alpha);
      _sGyr = _lerpVec3(_sGyr, g, alpha);
    }

    // ---- append to ring buffers (capped at windowSize) ----
    _pushCapped(_rawAccBuf, a);
    _pushCapped(_rawGyrBuf, g);
    _pushCapped(_smoothedAccBuf, List<double>.from(_sAcc));
    _pushCapped(_smoothedGyrBuf, List<double>.from(_sGyr));

    // ---- wait for full window ----
    if (_smoothedAccBuf.length < windowSize) {
      return null;
    }

    // ---- statistics over smoothed window ----
    final accSArr = _smoothedAccBuf.toList();
    final gyrSArr = _smoothedGyrBuf.toList();

    final lpAccStd = _colStd(accSArr);
    final maxLpAccStd = _maxOf3(lpAccStd);

    final meanGyrS = _colMean(gyrSArr);
    final meanGyrNorm = _vecNorm(meanGyrS);

    final lpGyrStd = _colStd(gyrSArr);
    final maxLpGyrStd = _maxOf3(lpGyrStd);

    final meanAccS = _colMean(accSArr);
    final meanAccNorm = _vecNorm(meanAccS);

    final bool gravityOk = (meanAccNorm - 9.80665).abs() < gravityMargin;

    // ---- statistics over raw accelerometer magnitudes ----
    final rawAArr = _rawAccBuf.toList();
    final rawAmagStd = _magnitudeStd(rawAArr);

    // ---- stillness decision ----
    final bool gyrStill = (maxLpGyrStd < 0.09) && (meanGyrNorm < 0.22);

    final bool physicalStill =
        (maxLpAccStd < lpAccStdThresh || rawAmagStd < 0.45) &&
            gyrStill &&
            gravityOk;

    bool isStillInstant;
    if (physicalStill) {
      isStillInstant = true;
    } else if (neuralClass != null && neuralClass == 0) {
      isStillInstant = gyrStill && (rawAmagStd < 0.60);
    } else if (neuralSpeedMps != null && neuralSpeedMps < 0.50) {
      isStillInstant = gyrStill && (rawAmagStd < 0.60);
    } else {
      isStillInstant = false;
    }

    // ---- consecutive-sample counter & bias estimation ----
    if (isStillInstant) {
      _stationaryCounter += 1;
      if (_stationaryCounter >= minConsecutive) {
        _isStationary = true;

        // Update gravity-down estimate
        final meanA = _colMean(accSArr);
        final meanANorm = _vecNorm(meanA);
        final meanAU = _scaleVec3(meanA, 1.0 / meanANorm);

        if (!_gDownInitialized) {
          _gDown = List<double>.from(meanAU);
          _gDownInitialized = true;
        } else {
          const double gAlpha = 0.02;
          _gDown = _lerpVec3(_gDown, meanAU, gAlpha);
          final gNorm = _vecNorm(_gDown);
          _gDown = _scaleVec3(_gDown, 1.0 / gNorm);
        }

        // Estimate yaw-rate bias along gravity
        final instYawRate = -_dot3(meanGyrS, _gDown);
        const double bAlpha = 0.01;
        _currentGyroBiasRads =
            (1.0 - bAlpha) * _currentGyroBiasRads + bAlpha * instYawRate;
      }
    } else {
      _stationaryCounter = 0;
      _isStationary = false;
    }

    final double confidence = _isStationary ? 0.95 : 0.0;

    return ZuptResult(
      isStationary: _isStationary,
      confidence: confidence,
      gDown: List<double>.from(_gDown),
      gyroBiasRads: _currentGyroBiasRads,
    );
  }

  // =========================================================================
  //  Private helpers – vector math that replaces NumPy operations
  // =========================================================================

  /// Push [v] onto the back of [q], dropping the front element if the queue
  /// has reached [windowSize].
  void _pushCapped(Queue<List<double>> q, List<double> v) {
    if (q.length >= windowSize) {
      q.removeFirst();
    }
    q.add(v);
  }

  /// Column-wise mean of a list of 3-element vectors.
  static List<double> _colMean(List<List<double>> rows) {
    final int n = rows.length;
    double s0 = 0.0, s1 = 0.0, s2 = 0.0;
    for (final r in rows) {
      s0 += r[0];
      s1 += r[1];
      s2 += r[2];
    }
    return <double>[s0 / n, s1 / n, s2 / n];
  }

  /// Column-wise population standard deviation of a list of 3-element vectors.
  ///
  /// Matches NumPy's `np.std(arr, axis=0)` which uses the population (N)
  /// denominator.
  static List<double> _colStd(List<List<double>> rows) {
    final int n = rows.length;
    double s0 = 0.0, s1 = 0.0, s2 = 0.0;
    for (final r in rows) {
      s0 += r[0];
      s1 += r[1];
      s2 += r[2];
    }
    final double m0 = s0 / n, m1 = s1 / n, m2 = s2 / n;
    double v0 = 0.0, v1 = 0.0, v2 = 0.0;
    for (final r in rows) {
      final d0 = r[0] - m0;
      final d1 = r[1] - m1;
      final d2 = r[2] - m2;
      v0 += d0 * d0;
      v1 += d1 * d1;
      v2 += d2 * d2;
    }
    return <double>[sqrt(v0 / n), sqrt(v1 / n), sqrt(v2 / n)];
  }

  /// Population standard deviation of the Euclidean norms of each row.
  ///
  /// Equivalent to `np.std(np.linalg.norm(arr, axis=1))`.
  static double _magnitudeStd(List<List<double>> rows) {
    final int n = rows.length;
    double sum = 0.0;
    final mags = List<double>.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      final r = rows[i];
      final m = sqrt(r[0] * r[0] + r[1] * r[1] + r[2] * r[2]);
      mags[i] = m;
      sum += m;
    }
    final double mean = sum / n;
    double variance = 0.0;
    for (int i = 0; i < n; i++) {
      final d = mags[i] - mean;
      variance += d * d;
    }
    return sqrt(variance / n);
  }

  /// Euclidean norm of a 3-element vector.
  static double _vecNorm(List<double> v) =>
      sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);

  /// Dot product of two 3-element vectors.
  static double _dot3(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

  /// Scale a 3-element vector by a scalar, returning a new list.
  static List<double> _scaleVec3(List<double> v, double s) =>
      <double>[v[0] * s, v[1] * s, v[2] * s];

  /// Linear interpolation between two 3-element vectors:
  /// `(1 - alpha) * a + alpha * b`.
  static List<double> _lerpVec3(List<double> a, List<double> b, double alpha) {
    final double oneMinusAlpha = 1.0 - alpha;
    return <double>[
      oneMinusAlpha * a[0] + alpha * b[0],
      oneMinusAlpha * a[1] + alpha * b[1],
      oneMinusAlpha * a[2] + alpha * b[2],
    ];
  }

  /// Normalise a 3-element vector in place.
  static List<double> _normalizeVec3(List<double> v) {
    final double n = _vecNorm(v);
    if (n < 1e-15) return v;
    return _scaleVec3(v, 1.0 / n);
  }

  /// Maximum of the three components of a 3-element vector.
  static double _maxOf3(List<double> v) => max(v[0], max(v[1], v[2]));
}
