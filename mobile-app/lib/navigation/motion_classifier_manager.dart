import 'dart:math';
import 'sensor_resampler.dart';
import 'phone_calibration_service.dart';

enum MotionMode {
  stationary,
  vehicle,
  walking,
  unknown;

  String get label {
    switch (this) {
      case MotionMode.stationary:
        return 'STATIONARY';
      case MotionMode.vehicle:
        return 'VEHICLE';
      case MotionMode.walking:
        return 'WALKING';
      case MotionMode.unknown:
        return 'UNKNOWN';
    }
  }
}

class MotionClassificationResult {
  final MotionMode mode;
  final double pStationary;
  final double pVehicle;
  final double pWalking;
  final bool physicalStillness;
  final double stepCadenceHz;
  final double accelVariance;
  final double gyroNorm;
  final String rationale;

  const MotionClassificationResult({
    required this.mode,
    required this.pStationary,
    required this.pVehicle,
    required this.pWalking,
    required this.physicalStillness,
    required this.stepCadenceHz,
    required this.accelVariance,
    required this.gyroNorm,
    required this.rationale,
  });
}

/// MotionClassifierManager fuses neural network logits, temporal smoothing,
/// human walking cadence analysis, and physical stillness gating.
class MotionClassifierManager {
  static const int historyLen = 15; // ~1.5s rolling average

  final List<List<double>> _probHistory = []; // list of [p0, p1, p2]
  MotionMode _currentMode = MotionMode.stationary;
  MotionMode get currentMode => _currentMode;

  DateTime _modeHoldStartTime = DateTime.now();
  MotionMode _candidateMode = MotionMode.stationary;

  // Physical gating thresholds
  static const double stillAccelVarThresh = 0.35; // m/s^2
  static const double stillGyroNormThresh = 0.045; // rad/s

  /// Classify 100 Hz resampled window
  MotionClassificationResult classify({
    required ResampledWindow resampled,
    required CalibrationProfile calibration,
    List<double>? rawModelLogits, // Optional from ONNX model
    double? gnssSpeedMps,
    double? neuralVehicleSpeedMps,
  }) {
    final window = resampled.window; // 100 x 6

    // 1. Compute Physical Metrics from window
    final stats = _computeWindowStats(window);
    final accelVar = stats.maxAccelVariance;
    final gyroNorm = stats.meanGyroNorm;
    final stepCadence = _estimateStepCadence(window);

    // 2. Physical Stillness Gate: Strictly takes precedence over AI predictions
    final bool physicalStill = (accelVar < stillAccelVarThresh &&
        gyroNorm < stillGyroNormThresh &&
        (stats.meanAccelMagnitude - 9.80665).abs() < 1.8);

    // 3. Compute Probabilities (From Model or Analytical Fusion)
    List<double> frameProbs;
    if (rawModelLogits != null && rawModelLogits.isNotEmpty) {
      frameProbs = _modelLogitsToProbs(rawModelLogits);
    } else {
      frameProbs = _heuristicProbabilityEstimation(
        accelVar: accelVar,
        gyroNorm: gyroNorm,
        stepCadence: stepCadence,
        gnssSpeedMps: gnssSpeedMps,
        neuralVehicleSpeedMps: neuralVehicleSpeedMps,
        physicalStill: physicalStill,
      );
    }

    // 4. Physical stillness clamp on probabilities (normalized to sum to 1)
    if (physicalStill) {
      frameProbs = [0.92, 0.05, 0.03];
    }

    // 5. Temporal Smoothing (Rolling average over last ~1.5s)
    _probHistory.add(frameProbs);
    if (_probHistory.length > historyLen) {
      _probHistory.removeAt(0);
    }

    double avgPStat = 0.0, avgPVeh = 0.0, avgPWalk = 0.0;
    for (var p in _probHistory) {
      avgPStat += p[0];
      avgPVeh += p[1];
      avgPWalk += p[2];
    }
    final n = _probHistory.length;
    avgPStat /= n;
    avgPVeh /= n;
    avgPWalk /= n;

    // 6. Gated Mode Decision & Temporal Hysteresis
    final decision = _evaluateHysteresis(
      pStat: avgPStat,
      pVeh: avgPVeh,
      pWalk: avgPWalk,
      physicalStill: physicalStill,
      stepCadence: stepCadence,
      gnssSpeed: gnssSpeedMps,
    );

    return MotionClassificationResult(
      mode: decision.mode,
      pStationary: avgPStat,
      pVehicle: avgPVeh,
      pWalking: avgPWalk,
      physicalStillness: physicalStill,
      stepCadenceHz: stepCadence,
      accelVariance: accelVar,
      gyroNorm: gyroNorm,
      rationale: decision.rationale,
    );
  }

  ({MotionMode mode, String rationale}) _evaluateHysteresis({
    required double pStat,
    required double pVeh,
    required double pWalk,
    required bool physicalStill,
    required double stepCadence,
    required double? gnssSpeed,
  }) {
    final now = DateTime.now();

    // Strict Rule: Physical Stillness overrides everything
    if (physicalStill) {
      if (_currentMode != MotionMode.stationary) {
        _candidateMode = MotionMode.stationary;
        final elapsed = now.difference(_modeHoldStartTime).inMilliseconds / 1000.0;
        if (elapsed >= 1.0) {
          _currentMode = MotionMode.stationary;
          _modeHoldStartTime = now;
          return (mode: MotionMode.stationary, rationale: 'Physical stillness confirmed (accel var < 0.35)');
        }
      } else {
        return (mode: MotionMode.stationary, rationale: 'Physical stillness sustained');
      }
    }

    // Check for UNKNOWN state (ambiguous signals or low confidence)
    final maxP = max(pStat, max(pVeh, pWalk));
    if (maxP < 0.55 && !physicalStill) {
      return (mode: _currentMode, rationale: 'Low confidence ($maxP < 0.55) -> Holding $_currentMode');
    }

    MotionMode targetMode = _currentMode;

    if (pVeh > 0.78) {
      targetMode = MotionMode.vehicle;
    } else if (pWalk > 0.75 && stepCadence >= 0.8 && stepCadence <= 3.2) {
      targetMode = MotionMode.walking;
    } else if (pStat > 0.75) {
      targetMode = MotionMode.stationary;
    }

    if (targetMode != _currentMode) {
      if (_candidateMode != targetMode) {
        _candidateMode = targetMode;
        _modeHoldStartTime = now;
      }

      final holdTimeS = now.difference(_modeHoldStartTime).inMilliseconds / 1000.0;
      double requiredS = 1.5;

      if (_currentMode == MotionMode.stationary && targetMode == MotionMode.vehicle) {
        requiredS = 1.5;
      } else if (_currentMode == MotionMode.stationary && targetMode == MotionMode.walking) {
        requiredS = 1.2;
      } else if (_currentMode == MotionMode.walking && targetMode == MotionMode.stationary) {
        requiredS = 1.0;
      }

      if (holdTimeS >= requiredS) {
        _currentMode = targetMode;
        _modeHoldStartTime = now;
        return (mode: _currentMode, rationale: 'Hysteresis met ($holdTimeS s >= $requiredS s)');
      } else {
        return (mode: _currentMode, rationale: 'Transitioning to $targetMode (${holdTimeS.toStringAsFixed(1)}/$requiredS s)');
      }
    } else {
      _candidateMode = _currentMode;
      _modeHoldStartTime = now;
    }

    return (mode: _currentMode, rationale: 'Steady state $_currentMode');
  }

  /// Converts raw ONNX logits to 3-class probabilities [stationary, vehicle, walking].
  /// Handles both 4-class (0=Stationary, 1=VehicleCruise, 2=VehicleTurn, 3=Walking)
  /// and 3-class (0=Stationary, 1=Vehicle, 2=Walking) model outputs.
  List<double> _modelLogitsToProbs(List<double> logits) {
    final probs = _softmax(logits);
    if (probs.length == 4) {
      // Merge vehicle cruising + turning into single vehicle probability
      return [probs[0], probs[1] + probs[2], probs[3]];
    } else if (probs.length == 3) {
      return probs;
    }
    // Fallback: unknown model output size
    return [0.34, 0.33, 0.33];
  }

  List<double> _softmax(List<double> logits) {
    final maxL = logits.reduce(max);
    final exps = logits.map((l) => exp(l - maxL)).toList();
    final sumExps = exps.reduce((a, b) => a + b);
    return exps.map((e) => e / (sumExps > 0 ? sumExps : 1.0)).toList();
  }

  List<double> _heuristicProbabilityEstimation({
    required double accelVar,
    required double gyroNorm,
    required double stepCadence,
    required double? gnssSpeedMps,
    required double? neuralVehicleSpeedMps,
    required bool physicalStill,
  }) {
    if (physicalStill) {
      return [0.95, 0.03, 0.02];
    }

    // Walking cadence between 0.9 and 2.6 Hz
    if (stepCadence >= 0.9 && stepCadence <= 2.6) {
      return [0.05, 0.15, 0.80];
    }

    // High vibration + speed evidence -> Vehicle
    final spd = max(gnssSpeedMps ?? 0.0, neuralVehicleSpeedMps ?? 0.0);
    if (spd >= 1.5 || accelVar > 0.8) {
      return [0.04, 0.88, 0.08];
    }

    return [0.34, 0.33, 0.33];
  }

  _WindowStats _computeWindowStats(List<List<double>> w) {
    int n = w.length;
    double sumAx = 0, sumAy = 0, sumAz = 0;
    double sumGx = 0, sumGy = 0, sumGz = 0;

    for (var s in w) {
      sumAx += s[0]; sumAy += s[1]; sumAz += s[2];
      sumGx += s[3]; sumGy += s[4]; sumGz += s[5];
    }

    final mAx = sumAx / n, mAy = sumAy / n, mAz = sumAz / n;
    final mGx = sumGx / n, mGy = sumGy / n, mGz = sumGz / n;

    double varAx = 0, varAy = 0, varAz = 0;
    for (var s in w) {
      varAx += (s[0] - mAx) * (s[0] - mAx);
      varAy += (s[1] - mAy) * (s[1] - mAy);
      varAz += (s[2] - mAz) * (s[2] - mAz);
    }

    return _WindowStats(
      maxAccelVariance: max(varAx / n, max(varAy / n, varAz / n)),
      meanGyroNorm: sqrt(mGx * mGx + mGy * mGy + mGz * mGz),
      meanAccelMagnitude: sqrt(mAx * mAx + mAy * mAy + mAz * mAz),
    );
  }

  double _estimateStepCadence(List<List<double>> w) {
    // Count acceleration magnitude peaks across 100 samples (1.0 second)
    int peaks = 0;
    for (int i = 1; i < w.length - 1; i++) {
      final aPrev = sqrt(w[i-1][0]*w[i-1][0] + w[i-1][1]*w[i-1][1] + w[i-1][2]*w[i-1][2]);
      final aCurr = sqrt(w[i][0]*w[i][0] + w[i][1]*w[i][1] + w[i][2]*w[i][2]);
      final aNext = sqrt(w[i+1][0]*w[i+1][0] + w[i+1][1]*w[i+1][1] + w[i+1][2]*w[i+1][2]);

      if (aCurr > aPrev && aCurr > aNext && aCurr > 10.8) {
        peaks++;
      }
    }
    // 1-second window -> peaks = Hz
    return peaks.toDouble();
  }
}

class _WindowStats {
  final double maxAccelVariance;
  final double meanGyroNorm;
  final double meanAccelMagnitude;

  const _WindowStats({
    required this.maxAccelVariance,
    required this.meanGyroNorm,
    required this.meanAccelMagnitude,
  });
}
