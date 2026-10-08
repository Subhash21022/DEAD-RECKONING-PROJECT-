import 'dart:async';
import 'dart:collection';
import 'package:sensors_plus/sensors_plus.dart';
import '../core/constants.dart';

class ImuSample {
  final double timestampS;
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;

  const ImuSample({
    required this.timestampS,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
  });

  List<double> toVector() => [ax, ay, az, gx, gy, gz];
}

class SensorStreamService {
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  final _controller = StreamController<ImuSample>.broadcast();
  Stream<ImuSample> get imuStream => _controller.stream;

  final Queue<ImuSample> _windowBuffer = Queue<ImuSample>();
  int get windowSize => _windowBuffer.length;
  bool get windowReady => _windowBuffer.length >= AppConstants.imuWindowSize;

  double _lastAx = 0.0, _lastAy = 0.0, _lastAz = 9.81;
  double _lastGx = 0.0, _lastGy = 0.0, _lastGz = 0.0;
  bool _accelReady = false;
  bool _gyroReady = false;
  bool _running = false;

  int _sampleCounter = 0;
  int get sampleCounter => _sampleCounter;

  Timer? _samplingTimer;

  void start() {
    if (_running) return;
    _running = true;
    _sampleCounter = 0;

    _accelSub = accelerometerEventStream(
      samplingPeriod: Duration(
          microseconds: (1000000.0 / AppConstants.imuSampleRateHz).round()),
    ).listen((event) {
      _lastAx = event.x;
      _lastAy = event.y;
      _lastAz = event.z;
      _accelReady = true;
    });

    _gyroSub = gyroscopeEventStream(
      samplingPeriod: Duration(
          microseconds: (1000000.0 / AppConstants.imuSampleRateHz).round()),
    ).listen((event) {
      _lastGx = event.x;
      _lastGy = event.y;
      _lastGz = event.z;
      _gyroReady = true;
    });

    _samplingTimer = Timer.periodic(
      Duration(microseconds: (1000000.0 / AppConstants.imuSampleRateHz).round()),
      (_) => _emitSample(),
    );
  }

  void _emitSample() {
    if (!_accelReady || !_gyroReady) return;

    final now = DateTime.now().microsecondsSinceEpoch / 1e6;
    final sample = ImuSample(
      timestampS: now,
      ax: _lastAx,
      ay: _lastAy,
      az: _lastAz,
      gx: _lastGx,
      gy: _lastGy,
      gz: _lastGz,
    );

    _windowBuffer.addLast(sample);
    if (_windowBuffer.length > AppConstants.imuWindowSize) {
      _windowBuffer.removeFirst();
    }

    _sampleCounter++;
    _controller.add(sample);
  }

  List<ImuSample> getWindow() => _windowBuffer.toList();

  List<List<double>> getClassifierWindow() {
    return _windowBuffer.map((s) => s.toVector()).toList();
  }

  void stop() {
    _running = false;
    _samplingTimer?.cancel();
    _samplingTimer = null;
    _accelSub?.cancel();
    _accelSub = null;
    _gyroSub?.cancel();
    _gyroSub = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
