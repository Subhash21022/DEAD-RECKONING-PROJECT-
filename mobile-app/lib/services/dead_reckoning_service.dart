import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../core/constants.dart';
import 'sensor_stream_service.dart';
import 'gnss_service.dart';
import '../connectivity/network_manager.dart';
import '../navigation/gnss_quality_manager.dart';
import '../navigation/phone_calibration_service.dart';
import '../navigation/sensor_resampler.dart';
import '../navigation/motion_classifier_manager.dart';
import '../navigation/local_dead_reckoning_engine.dart';
import '../navigation/onnx_inference_service.dart';

class NavigationState {
  final double timestampS;
  final double lat;
  final double lon;
  final double matchedLat;
  final double matchedLon;
  final bool isSnapped;
  final double posEastM;
  final double posNorthM;
  final double speedMps;
  final double speedKmh;
  final double headingDeg;
  final double gyroBiasRads;
  final double speedScaleFactor;
  final double confidenceRadiusM;
  final bool isStationary;
  final bool isOod;
  final double oodEntropy;
  final String mode;
  final String gnssQuality;
  final bool isOutage;
  final String navSystemState;
  final String lastTransition;
  final int satellitesCount;
  final double gnssAccuracyM;
  final bool modelRunning;
  final double modelSpeedMps;
  final bool zuptActive;
  final double drLat;
  final double drLon;
  final double? rawGnssLat;
  final double? rawGnssLon;
  final String networkState;
  final String navPipeline;
  final double measuredAccelHz;
  final double measuredGyroHz;
  final double pStationary;
  final double pVehicle;
  final double pWalking;
  final List<double> gravityVector;
  final String calibrationStatus;

  const NavigationState({
    required this.timestampS,
    required this.lat,
    required this.lon,
    required this.matchedLat,
    required this.matchedLon,
    required this.isSnapped,
    required this.posEastM,
    required this.posNorthM,
    required this.speedMps,
    required this.speedKmh,
    required this.headingDeg,
    required this.gyroBiasRads,
    required this.speedScaleFactor,
    required this.confidenceRadiusM,
    required this.isStationary,
    required this.isOod,
    required this.oodEntropy,
    required this.mode,
    required this.gnssQuality,
    required this.isOutage,
    this.navSystemState = 'GNSS_LOST',
    this.lastTransition = '',
    this.satellitesCount = 0,
    this.gnssAccuracyM = 999.0,
    this.modelRunning = false,
    this.modelSpeedMps = 0.0,
    this.zuptActive = false,
    this.drLat = 0.0,
    this.drLon = 0.0,
    this.rawGnssLat,
    this.rawGnssLon,
    this.networkState = 'OFFLINE',
    this.navPipeline = 'DEAD RECKONING',
    this.measuredAccelHz = 100.0,
    this.measuredGyroHz = 100.0,
    this.pStationary = 0.0,
    this.pVehicle = 0.0,
    this.pWalking = 0.0,
    this.gravityVector = const [0.0, 9.81, 0.0],
    this.calibrationStatus = 'UNCALIBRATED',
  });

  factory NavigationState.fromJson(Map<String, dynamic> json) => NavigationState(
        timestampS: (json['timestamp_s'] as num).toDouble(),
        lat: (json['lat'] as num).toDouble(),
        lon: (json['lon'] as num).toDouble(),
        matchedLat: (json['matched_lat'] as num).toDouble(),
        matchedLon: (json['matched_lon'] as num).toDouble(),
        isSnapped: json['is_snapped'] as bool? ?? false,
        posEastM: (json['pos_east_m'] as num).toDouble(),
        posNorthM: (json['pos_north_m'] as num).toDouble(),
        speedMps: (json['speed_mps'] as num).toDouble(),
        speedKmh: (json['speed_kmh'] as num).toDouble(),
        headingDeg: (json['heading_deg'] as num).toDouble(),
        gyroBiasRads: (json['gyro_bias_rads'] as num?)?.toDouble() ?? 0.0,
        speedScaleFactor: (json['speed_scale_factor'] as num?)?.toDouble() ?? 1.0,
        confidenceRadiusM: (json['confidence_radius_m'] as num).toDouble(),
        isStationary: json['is_stationary'] as bool? ?? false,
        isOod: json['is_ood'] as bool? ?? false,
        oodEntropy: (json['ood_entropy'] as num?)?.toDouble() ?? 0.0,
        mode: json['mode'] as String? ?? 'UNKNOWN',
        gnssQuality: json['gnss_quality'] as String? ?? 'LOST',
        isOutage: json['is_outage'] as bool? ?? true,
        navSystemState: json['nav_system_state'] as String? ?? 'GNSS_LOST',
        lastTransition: json['last_transition'] as String? ?? '',
        satellitesCount: (json['satellites_count'] as num?)?.toInt() ?? 0,
        gnssAccuracyM: (json['gnss_accuracy_m'] as num?)?.toDouble() ?? 999.0,
        modelRunning: json['model_running'] as bool? ?? false,
        modelSpeedMps: (json['model_speed_mps'] as num?)?.toDouble() ?? 0.0,
        zuptActive: json['zupt_active'] as bool? ?? false,
        drLat: (json['dr_lat'] as num?)?.toDouble() ?? (json['lat'] as num).toDouble(),
        drLon: (json['dr_lon'] as num?)?.toDouble() ?? (json['lon'] as num).toDouble(),
        rawGnssLat: (json['raw_gnss_lat'] as num?)?.toDouble(),
        rawGnssLon: (json['raw_gnss_lon'] as num?)?.toDouble(),
        networkState: json['network_state'] as String? ?? 'OFFLINE',
        navPipeline: json['nav_pipeline'] as String? ?? 'DEAD RECKONING',
        measuredAccelHz: (json['measured_accel_hz'] as num?)?.toDouble() ?? 100.0,
        measuredGyroHz: (json['measured_gyro_hz'] as num?)?.toDouble() ?? 100.0,
        pStationary: (json['p_stationary'] as num?)?.toDouble() ?? 0.0,
        pVehicle: (json['p_vehicle'] as num?)?.toDouble() ?? 0.0,
        pWalking: (json['p_walking'] as num?)?.toDouble() ?? 0.0,
        gravityVector: (json['gravity_vector'] as List<dynamic>?)
                ?.map((e) => (e as num).toDouble())
                .toList() ??
            const [0.0, 9.81, 0.0],
        calibrationStatus: json['calibration_status'] as String? ?? 'CALIBRATED',
      );
}

enum EdgeConnectionState { disconnected, connecting, connected, error }

class DeadReckoningService {
  final SensorStreamService _sensorService;

  late final NetworkManager networkManager;
  late final GnssQualityManager gnssQualityManager;
  late final PhoneCalibrationService calibrationService;
  late final SensorResampler _resampler;
  late final MotionClassifierManager _motionManager;
  late final LocalDeadReckoningEngine _localEngine;
  late final OnnxInferenceService _onnxService;

  final _stateController = StreamController<NavigationState>.broadcast();
  Stream<NavigationState> get navigationStream => _stateController.stream;

  final _connectionController = StreamController<EdgeConnectionState>.broadcast();
  Stream<EdgeConnectionState> get connectionStream => _connectionController.stream;

  NavigationState? _lastState;
  NavigationState? get lastState => _lastState;

  EdgeConnectionState _connectionState = EdgeConnectionState.disconnected;
  EdgeConnectionState get connectionState => _connectionState;

  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSub;
  StreamSubscription<ImuSample>? _imuSub;
  StreamSubscription<GnssQualityReport>? _gnssQualitySub;
  StreamSubscription<NetworkState>? _networkSub;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _running = false;
  int _imuCounter = 0;

  MotionClassificationResult? _latestMotion;
  ClassifierResult? _latestOnnxClassification;
  double? _latestNeuralVehicleSpeedMps;
  double? _latestNeuralPedestrianSpeedMps;
  bool _onnxReady = false;

  GnssQualityReport _latestGnssReport = const GnssQualityReport(
    state: GnssState.lost,
    updateAgeS: 999.0,
    accuracyM: 999.0,
    speedMps: 0.0,
    bearingDeg: 0.0,
    consecutiveGoodFixes: 0,
    estimatedSatellites: 0,
    isServiceEnabled: true,
    stateReason: 'Initializing',
  );

  static const List<String> _candidateHosts = ['127.0.0.1', '192.168.1.8'];
  int _activeHostIndex = 0;
  String get _currentHost => _candidateHosts[_activeHostIndex];

  String? _prevNavState;

  DeadReckoningService({
    required SensorStreamService sensorService,
    required GnssService gnssService,
  }) : _sensorService = sensorService {
    networkManager = NetworkManager();
    gnssQualityManager = GnssQualityManager(gnssService: gnssService);
    calibrationService = PhoneCalibrationService(sensorService: sensorService);
    _resampler = SensorResampler();
    _motionManager = MotionClassifierManager();
    _localEngine = LocalDeadReckoningEngine();
    _onnxService = OnnxInferenceService();
  }

  Future<void> start({bool preferWebSocket = true}) async {
    if (_running) return;
    _running = true;

    await networkManager.start();
    gnssQualityManager.start();

    try {
      await _onnxService.initialize();
      _onnxReady = true;
    } catch (_) {
      _onnxReady = false;
    }

    _gnssQualitySub = gnssQualityManager.reportStream.listen((report) {
      _latestGnssReport = report;
    });

    _networkSub = networkManager.stateStream.listen((netState) {
      // Network state does NOT affect GNSS or navigation
      if (_lastState != null) {
        _emitWithNetworkUpdate(netState.label);
      }
    });

    // Edge engine is optional telemetry only
    if (preferWebSocket) _connectWebSocket();

    _imuSub = _sensorService.imuStream.listen(_onImuSample);
  }

  void _onImuSample(ImuSample sample) {
    _imuCounter++;

    // 1. Feed resampler (every sample)
    final resampled = _resampler.addSample(sample);

    // 2. Run EKF on every sample for heading/position integration
    //    Run classification at 10 Hz (when resampler produces a full window)
    if (resampled != null) {
      // 10 Hz: run ONNX inference + classify motion from the full 100-sample window
      List<double>? rawModelLogits;

      if (_onnxReady) {
        final clsResult = _onnxService.classifyMotion(resampled.window);
        if (clsResult != null) {
          _latestOnnxClassification = clsResult;
          rawModelLogits = clsResult.probabilities;

          // Run speed estimator matching the classified mode
          if (clsResult.predictedClass == 1 || clsResult.predictedClass == 2) {
            final spd = _onnxService.estimateVehicleSpeed(resampled.window);
            _latestNeuralVehicleSpeedMps = spd?.speedMps;
            _latestNeuralPedestrianSpeedMps = null;
          } else if (clsResult.predictedClass == 3) {
            final spd = _onnxService.estimatePedestrianSpeed(resampled.window);
            _latestNeuralPedestrianSpeedMps = spd?.speedMps;
            _latestNeuralVehicleSpeedMps = null;
          } else {
            _latestNeuralVehicleSpeedMps = null;
            _latestNeuralPedestrianSpeedMps = null;
          }
        }
      }

      _latestMotion = _motionManager.classify(
        resampled: resampled,
        calibration: calibrationService.profile,
        rawModelLogits: rawModelLogits,
        gnssSpeedMps: _latestGnssReport.speedMps,
        neuralVehicleSpeedMps: _latestNeuralVehicleSpeedMps,
      );
    }

    // Run EKF at 10 Hz (every 10th raw sample, when we have a classification)
    if (_imuCounter % 10 == 0 && _latestMotion != null) {
      _runLocalNavigation(sample);
    }

    // 3. Parallel telemetry to edge engine (if connected, send-only)
    if (_connectionState == EdgeConnectionState.connected && _wsChannel != null) {
      if (_imuCounter % AppConstants.samplesPerInference == 0) {
        _sendWsBatch(sample);
      }
    }
  }

  void _runLocalNavigation(ImuSample raw) {
    final motion = _latestMotion!;

    // Execute full 5-state EKF step (with ZUPT, PDR, map matching inside)
    final onnxCls = _latestOnnxClassification;
    final navOut = _localEngine.step(
      timestampS: raw.timestampS,
      ax: raw.ax, ay: raw.ay, az: raw.az,
      gx: raw.gx, gy: raw.gy, gz: raw.gz,
      calibration: calibrationService.profile,
      motion: motion,
      gnssReport: _latestGnssReport,
      neuralVehicleSpeedMps: _latestNeuralVehicleSpeedMps,
      isOod: onnxCls?.isOod ?? false,
      oodEntropy: onnxCls?.normalizedEntropy ?? 0.0,
    );

    // Track state transitions
    final newNavState = _toNavSystemState(navOut.gnssState, navOut.isSnapped);
    String lastTransition = motion.rationale;
    if (_prevNavState != null && _prevNavState != newNavState) {
      lastTransition = '$_prevNavState -> $newNavState';
    }
    _prevNavState = newNavState;

    final rawGnssReading = gnssQualityManager.latestReading;
    final state = NavigationState(
      timestampS: navOut.timestampS,
      lat: navOut.lat,
      lon: navOut.lon,
      matchedLat: navOut.matchedLat,
      matchedLon: navOut.matchedLon,
      isSnapped: navOut.isSnapped,
      posEastM: navOut.posEastM,
      posNorthM: navOut.posNorthM,
      speedMps: navOut.speedMps,
      speedKmh: navOut.speedKmh,
      headingDeg: navOut.headingDeg,
      gyroBiasRads: navOut.gyroBiasRads,
      speedScaleFactor: navOut.speedScaleFactor,
      confidenceRadiusM: navOut.confidenceRadiusM,
      isStationary: navOut.isStationary,
      isOod: navOut.isOod,
      oodEntropy: navOut.oodEntropy,
      mode: navOut.motionMode.label,
      gnssQuality: navOut.gnssState.label,
      isOutage: navOut.gnssState == GnssState.lost,
      navSystemState: newNavState,
      lastTransition: lastTransition,
      satellitesCount: _latestGnssReport.estimatedSatellites,
      gnssAccuracyM: _latestGnssReport.accuracyM,
      modelRunning: _onnxReady && calibrationService.status != CalibrationStatus.uncalibrated,
      modelSpeedMps: navOut.modelSpeedMps,
      zuptActive: navOut.zuptActive,
      drLat: navOut.drLat,
      drLon: navOut.drLon,
      rawGnssLat: _latestGnssReport.state != GnssState.lost ? rawGnssReading?.lat : null,
      rawGnssLon: _latestGnssReport.state != GnssState.lost ? rawGnssReading?.lon : null,
      networkState: networkManager.state.label,
      navPipeline: navOut.navPipeline,
      measuredAccelHz: _resampler.measuredAccelHz,
      measuredGyroHz: _resampler.measuredGyroHz,
      pStationary: motion.pStationary,
      pVehicle: motion.pVehicle,
      pWalking: motion.pWalking,
      gravityVector: calibrationService.profile.gravityVector,
      calibrationStatus: calibrationService.status.label,
    );

    _lastState = state;
    _stateController.add(state);
  }

  String _toNavSystemState(GnssState gnss, bool isSnapped) {
    switch (gnss) {
      case GnssState.good:
        return 'GNSS_AVAILABLE';
      case GnssState.degraded:
        return 'GNSS_DEGRADED';
      case GnssState.lost:
        return isSnapped ? 'MAP_MATCHING_ACTIVE' : 'DEAD_RECKONING_ACTIVE';
      case GnssState.recovering:
        return 'RECOVERY_TO_GNSS';
    }
  }

  void _emitWithNetworkUpdate(String netLabel) {
    if (_lastState == null) return;
    final s = _lastState!;
    final updated = NavigationState(
      timestampS: s.timestampS,
      lat: s.lat, lon: s.lon,
      matchedLat: s.matchedLat, matchedLon: s.matchedLon,
      isSnapped: s.isSnapped,
      posEastM: s.posEastM, posNorthM: s.posNorthM,
      speedMps: s.speedMps, speedKmh: s.speedKmh,
      headingDeg: s.headingDeg,
      gyroBiasRads: s.gyroBiasRads,
      speedScaleFactor: s.speedScaleFactor,
      confidenceRadiusM: s.confidenceRadiusM,
      isStationary: s.isStationary,
      isOod: s.isOod, oodEntropy: s.oodEntropy,
      mode: s.mode, gnssQuality: s.gnssQuality,
      isOutage: s.isOutage,
      navSystemState: s.navSystemState,
      lastTransition: s.lastTransition,
      satellitesCount: s.satellitesCount,
      gnssAccuracyM: s.gnssAccuracyM,
      modelRunning: s.modelRunning,
      modelSpeedMps: s.modelSpeedMps,
      zuptActive: s.zuptActive,
      drLat: s.drLat, drLon: s.drLon,
      rawGnssLat: s.rawGnssLat, rawGnssLon: s.rawGnssLon,
      networkState: netLabel,
      navPipeline: s.navPipeline,
      measuredAccelHz: s.measuredAccelHz, measuredGyroHz: s.measuredGyroHz,
      pStationary: s.pStationary, pVehicle: s.pVehicle, pWalking: s.pWalking,
      gravityVector: s.gravityVector,
      calibrationStatus: s.calibrationStatus,
    );
    _lastState = updated;
    _stateController.add(updated);
  }

  // --- Edge Engine (optional telemetry, does NOT control navigation) ---

  void _sendWsBatch(ImuSample sample) {
    final gnss = gnssQualityManager.latestReading;
    final payload = {
      'timestamp_s': sample.timestampS,
      'ax': sample.ax, 'ay': sample.ay, 'az': sample.az,
      'gx': sample.gx, 'gy': sample.gy, 'gz': sample.gz,
      'gnss_quality': _latestGnssReport.state.label,
      'network_state': networkManager.state.label,
    };

    if (gnss != null && _latestGnssReport.state != GnssState.lost) {
      payload['lat'] = gnss.lat;
      payload['lon'] = gnss.lon;
      payload['gnss_speed'] = gnss.speedMps;
      payload['gnss_acc'] = gnss.accuracyM;
      payload['gnss_bearing'] = gnss.bearingDeg;
    }

    try {
      _wsChannel?.sink.add(jsonEncode(payload));
    } catch (_) {
      _onWsDisconnect();
    }
  }

  void _connectWebSocket() {
    _setConnectionState(EdgeConnectionState.connecting);
    final wsUri = Uri.parse('ws://$_currentHost:8001/ws/stream');
    try {
      _wsChannel = WebSocketChannel.connect(wsUri);
      _wsSub = _wsChannel!.stream.listen(
        (_) {
          // Server responses are logged/ignored — navigation is local-only
        },
        onError: (_) {
          _activeHostIndex = (_activeHostIndex + 1) % _candidateHosts.length;
          _onWsDisconnect();
        },
        onDone: _onWsDisconnect,
      );
      _setConnectionState(EdgeConnectionState.connected);
      _reconnectAttempts = 0;
    } catch (_) {
      _activeHostIndex = (_activeHostIndex + 1) % _candidateHosts.length;
      _onWsDisconnect();
    }
  }

  void _onWsDisconnect() {
    _setConnectionState(EdgeConnectionState.disconnected);
    _wsSub?.cancel();
    _wsSub = null;
    _wsChannel = null;

    final delay = Duration(seconds: min(10, (1 << min(_reconnectAttempts, 3))));
    _reconnectAttempts++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (_running) _connectWebSocket();
    });
  }

  void _setConnectionState(EdgeConnectionState s) {
    if (_connectionState != s) {
      _connectionState = s;
      _connectionController.add(s);
    }
  }

  void stop() {
    _running = false;
    _imuSub?.cancel();
    _imuSub = null;
    _gnssQualitySub?.cancel();
    _gnssQualitySub = null;
    _networkSub?.cancel();
    _networkSub = null;
    _wsSub?.cancel();
    _wsSub = null;
    _wsChannel?.sink.close();
    _wsChannel = null;
    _reconnectTimer?.cancel();
    networkManager.stop();
    gnssQualityManager.stop();
  }

  void dispose() {
    stop();
    _stateController.close();
    _connectionController.close();
    networkManager.dispose();
    gnssQualityManager.dispose();
    calibrationService.dispose();
    _onnxService.dispose();
  }
}
