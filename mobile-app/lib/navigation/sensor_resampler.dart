import 'dart:collection';
import '../services/sensor_stream_service.dart';

class ResampledWindow {
  final double timestampS;
  final List<List<double>> window; // 100 samples x 6 channels
  final double measuredAccelHz;
  final double measuredGyroHz;

  const ResampledWindow({
    required this.timestampS,
    required this.window,
    required this.measuredAccelHz,
    required this.measuredGyroHz,
  });
}

/// SensorResampler consumes raw timestamped IMU samples from Android hardware,
/// measures the actual delivered sample frequency, and linearly resamples the stream
/// onto a strict 100 Hz (10.0 ms period) grid matching neural network training.
class SensorResampler {
  static const double targetDt = 0.01; // 100 Hz -> 10 ms grid
  static const int windowSize = 100;    // 100 samples = 1.0 second

  final Queue<ImuSample> _rawBuffer = Queue<ImuSample>();
  final List<List<double>> _gridWindow = []; // 100 x 6
  double _nextGridTime = 0.0;

  // Rate measurement
  int _rawSampleCount = 0;
  DateTime _lastHzCheckTime = DateTime.now();
  double _measuredAccelHz = 100.0;
  double _measuredGyroHz = 100.0;

  double get measuredAccelHz => _measuredAccelHz;
  double get measuredGyroHz => _measuredGyroHz;

  /// Ingests a raw sample from Android sensors
  ResampledWindow? addSample(ImuSample sample) {
    _rawSampleCount++;

    // Measure live hardware Hz every 1 second
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastHzCheckTime).inMilliseconds;
    if (elapsedMs >= 1000) {
      _measuredAccelHz = (_rawSampleCount * 1000.0) / elapsedMs;
      _measuredGyroHz = _measuredAccelHz; // Coupled stream
      _rawSampleCount = 0;
      _lastHzCheckTime = now;
    }

    _rawBuffer.addLast(sample);

    // Keep buffer bounded (~3.0 seconds max)
    while (_rawBuffer.length > 350) {
      _rawBuffer.removeFirst();
    }

    if (_rawBuffer.length < 2) {
      _nextGridTime = sample.timestampS;
      return null;
    }

    if (_nextGridTime == 0.0) {
      _nextGridTime = _rawBuffer.first.timestampS;
    }

    // Process all grid points that fall within our available timestamp range
    final newestTime = _rawBuffer.last.timestampS;

    while (_nextGridTime + targetDt <= newestTime) {
      _nextGridTime += targetDt;

      // Find bracketing samples in the buffer for linear interpolation
      final interpolated = _interpolateAt(_nextGridTime);
      if (interpolated != null) {
        _gridWindow.add(interpolated);
        if (_gridWindow.length > windowSize) {
          _gridWindow.removeAt(0);
        }

        // Emit full window if ready
        if (_gridWindow.length == windowSize) {
          // Return copy of the 100x6 window
          return ResampledWindow(
            timestampS: _nextGridTime,
            window: List.generate(
              windowSize,
              (i) => List<double>.from(_gridWindow[i]),
            ),
            measuredAccelHz: _measuredAccelHz,
            measuredGyroHz: _measuredGyroHz,
          );
        }
      }
    }

    return null;
  }

  List<double>? _interpolateAt(double targetTime) {
    ImuSample? s0;
    ImuSample? s1;

    for (var s in _rawBuffer) {
      if (s.timestampS <= targetTime) {
        s0 = s;
      } else if (s.timestampS > targetTime) {
        s1 = s;
        break;
      }
    }

    if (s0 == null || s1 == null) return null;

    final dt = s1.timestampS - s0.timestampS;
    if (dt <= 0.0) return [s0.ax, s0.ay, s0.az, s0.gx, s0.gy, s0.gz];

    final alpha = (targetTime - s0.timestampS) / dt;
    final clampedAlpha = alpha.clamp(0.0, 1.0);

    return [
      s0.ax + clampedAlpha * (s1.ax - s0.ax),
      s0.ay + clampedAlpha * (s1.ay - s0.ay),
      s0.az + clampedAlpha * (s1.az - s0.az),
      s0.gx + clampedAlpha * (s1.gx - s0.gx),
      s0.gy + clampedAlpha * (s1.gy - s0.gy),
      s0.gz + clampedAlpha * (s1.gz - s0.gz),
    ];
  }

  void reset() {
    _rawBuffer.clear();
    _gridWindow.clear();
    _nextGridTime = 0.0;
    _rawSampleCount = 0;
  }
}
