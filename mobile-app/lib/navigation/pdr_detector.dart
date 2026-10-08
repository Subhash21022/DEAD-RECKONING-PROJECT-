import 'dart:math';
import 'dart:collection';

/// Represents a single detected step from the PDR algorithm.
///
/// Returned by [PDRDetector.addSample] when a valid step peak is detected
/// in the accelerometer magnitude signal.
class StepEvent {
  /// Estimated length of the step in metres, clamped to [0.35, 1.15].
  final double stepLengthM;

  /// Timestamp (in seconds) at which the step peak occurred.
  final double timestampS;

  const StepEvent({required this.stepLengthM, required this.timestampS});

  @override
  String toString() =>
      'StepEvent(stepLengthM: ${stepLengthM.toStringAsFixed(3)}, '
      'timestampS: ${timestampS.toStringAsFixed(4)})';
}

/// Pedestrian Dead Reckoning (PDR) step detector.
///
/// Detects steps from raw tri-axis accelerometer data using a peak-detection
/// algorithm on the acceleration magnitude signal.  Step length is estimated
/// with the Weinberg model:
///
///     step_length = k * (a_max - a_min) ^ 0.25
///
/// The Weinberg gain [kWeinberg] can be refined at runtime via
/// [updateGnssCalibration] when GNSS fixes of sufficient quality are
/// available.
///
/// This is a faithful Dart port of `edge-engine/engine/pdr_detector.py`.
class PDRDetector {
  /// Sampling rate of the accelerometer in Hz.
  final double fs;

  /// Minimum time between two consecutive steps, in seconds.
  final double minStepInterval;

  /// Minimum bounce above the running mean required to accept a peak.
  final double peakThreshold;

  /// Current Weinberg gain factor. Exposed for monitoring / logging.
  double kWeinberg;

  /// Length of the circular buffer (in samples), covering 1 second of data.
  final int bufferLen;

  /// Timestamp of the most recently detected step (-1.0 if none yet).
  double lastStepTime;

  /// Running total of detected steps since construction.
  int totalSteps;

  // ---- internal calibration accumulators ----
  double _calibDistanceM;
  double _calibWeinbergSum;
  int _calibStepCount;

  // ---- circular buffers ----
  final Queue<double> _accMagBuffer;
  final Queue<double> _timeBuffer;

  /// Creates a [PDRDetector] with the given configuration.
  ///
  /// * [sampleRateHz] - expected accelerometer sampling rate (default 100 Hz).
  /// * [minStepIntervalS] - minimum interval between steps (default 0.35 s).
  /// * [peakThreshold] - acceleration bounce above mean to qualify as a step
  ///   peak (default 0.65 m/s^2).
  /// * [initialKWeinberg] - initial Weinberg gain factor (default 0.42).
  PDRDetector({
    double sampleRateHz = 100.0,
    double minStepIntervalS = 0.35,
    double peakThreshold = 0.65,
    double initialKWeinberg = 0.42,
  })  : fs = sampleRateHz,
        minStepInterval = minStepIntervalS,
        peakThreshold = peakThreshold,
        kWeinberg = initialKWeinberg,
        bufferLen = (sampleRateHz * 1.0).toInt(),
        lastStepTime = -1.0,
        totalSteps = 0,
        _calibDistanceM = 0.0,
        _calibWeinbergSum = 0.0,
        _calibStepCount = 0,
        _accMagBuffer = Queue<double>(),
        _timeBuffer = Queue<double>();

  /// Feeds a single accelerometer sample into the detector.
  ///
  /// [timestampS] is the sample timestamp in seconds.
  /// [ax], [ay], [az] are the three accelerometer axes (m/s^2).
  ///
  /// Returns a [StepEvent] when a step is detected, or `null` otherwise.
  StepEvent? addSample(double timestampS, double ax, double ay, double az) {
    final double mag = sqrt(ax * ax + ay * ay + az * az);

    // Append to circular buffers, enforcing maxlen.
    _accMagBuffer.add(mag);
    _timeBuffer.add(timestampS);
    if (_accMagBuffer.length > bufferLen) {
      _accMagBuffer.removeFirst();
      _timeBuffer.removeFirst();
    }

    // Need at least 20 samples before attempting detection.
    if (_accMagBuffer.length < 20) {
      return null;
    }

    // Enforce minimum step interval.
    if (lastStepTime > 0 &&
        (timestampS - lastStepTime) < minStepInterval) {
      return null;
    }

    final List<double> m = _accMagBuffer.toList();

    if (m.length >= 3) {
      final double curr = m[m.length - 2];
      final double prev = m[m.length - 3];
      final double nxt = m[m.length - 1];

      // Running mean of the entire buffer as baseline.
      final double meanBaseline = _mean(m);
      final double bounce = curr - meanBaseline;

      // Peak detection: local maximum that exceeds the threshold.
      if (curr > prev && curr > nxt && bounce > peakThreshold) {
        // Timestamp corresponding to the peak sample (second-to-last).
        final List<double> timeList = _timeBuffer.toList();
        final double stepTime = timeList[timeList.length - 2];
        lastStepTime = stepTime;
        totalSteps += 1;

        // Recent window for Weinberg delta-a calculation.
        final int windowLen = (minStepInterval * fs).toInt();
        final int start = m.length > windowLen ? m.length - windowLen : 0;
        final List<double> recentWindow = m.sublist(start);

        final double aMax = recentWindow.reduce(max);
        final double aMin = recentWindow.reduce(min);
        final double deltaA = max(0.1, aMax - aMin);

        double stepLength = kWeinberg * pow(deltaA, 0.25);
        stepLength = stepLength.clamp(0.35, 1.15);

        _calibWeinbergSum += pow(deltaA, 0.25);
        _calibStepCount += 1;

        return StepEvent(stepLengthM: stepLength, timestampS: stepTime);
      }
    }

    return null;
  }

  /// Refines the Weinberg gain [kWeinberg] using a GNSS distance segment.
  ///
  /// [segmentGnssDistM] is the GNSS-measured distance for the recent walking
  /// segment (in metres).  [gnssQuality] must be `"GOOD"` for the update to
  /// proceed.  At least 10 calibration steps and a minimum segment distance
  /// of 5 m are required.
  ///
  /// The gain is blended with a 90/10 exponential moving average to avoid
  /// abrupt jumps, and is clamped to [0.32, 0.55].
  void updateGnssCalibration(double segmentGnssDistM, String gnssQuality) {
    if (gnssQuality != 'GOOD' || _calibStepCount < 10) {
      return;
    }

    if (_calibWeinbergSum > 1e-3 && segmentGnssDistM > 5.0) {
      double kObserved = segmentGnssDistM / _calibWeinbergSum;
      kObserved = kObserved.clamp(0.32, 0.55);
      kWeinberg = 0.90 * kWeinberg + 0.10 * kObserved;

      _calibDistanceM = 0.0;
      _calibWeinbergSum = 0.0;
      _calibStepCount = 0;
    }
  }

  // ---------- private helpers ----------

  /// Arithmetic mean of a non-empty list of doubles.
  static double _mean(List<double> values) {
    double sum = 0.0;
    for (final double v in values) {
      sum += v;
    }
    return sum / values.length;
  }
}
