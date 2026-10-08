import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

class ClassifierResult {
  final List<double> probabilities;
  final int predictedClass;
  final double maxProb;
  final double normalizedEntropy;
  final bool isOod;

  const ClassifierResult({
    required this.probabilities,
    required this.predictedClass,
    required this.maxProb,
    required this.normalizedEntropy,
    required this.isOod,
  });
}

class SpeedResult {
  final double speedMps;

  const SpeedResult({required this.speedMps});
}

class OnnxInferenceService {
  static const String _classifierAsset = 'assets/models/motion_classifier.onnx';
  static const String _vehicleSpeedAsset = 'assets/models/universal_speed_estimator.onnx';
  static const String _pedestrianSpeedAsset = 'assets/models/pedestrian_speed_estimator.onnx';

  OrtSession? _classifierSession;
  OrtSession? _vehicleSpeedSession;
  OrtSession? _pedestrianSpeedSession;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  Future<void> initialize() async {
    if (_initialized) return;

    OrtEnv.instance.init();

    final sessionOptions = OrtSessionOptions()
      ..setIntraOpNumThreads(1)
      ..setInterOpNumThreads(1);

    try {
      final clsBytes = await rootBundle.load(_classifierAsset);
      _classifierSession = OrtSession.fromBuffer(
        clsBytes.buffer.asUint8List(),
        sessionOptions,
      );

      final vehBytes = await rootBundle.load(_vehicleSpeedAsset);
      _vehicleSpeedSession = OrtSession.fromBuffer(
        vehBytes.buffer.asUint8List(),
        sessionOptions,
      );

      final pedBytes = await rootBundle.load(_pedestrianSpeedAsset);
      _pedestrianSpeedSession = OrtSession.fromBuffer(
        pedBytes.buffer.asUint8List(),
        sessionOptions,
      );

      _initialized = true;
    } catch (e) {
      _initialized = false;
      rethrow;
    } finally {
      sessionOptions.release();
    }
  }

  ClassifierResult? classifyMotion(List<List<double>> window) {
    if (_classifierSession == null || window.length != 100) return null;

    // Build (1, 100, 6) tensor in row-major order
    final data = Float32List(1 * 100 * 6);
    for (int t = 0; t < 100; t++) {
      final row = window[t];
      for (int c = 0; c < 6; c++) {
        data[t * 6 + c] = row[c];
      }
    }

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      data,
      [1, 100, 6],
    );

    final inputs = {'imu_sequence': inputTensor};
    final outputNames = _classifierSession!.outputNames;

    List<OrtValue?>? outputs;
    try {
      outputs = _classifierSession!.run(
        OrtRunOptions(),
        inputs,
        outputNames,
      );

      if (outputs.isEmpty || outputs[0] == null) return null;

      final rawLogits = (outputs[0]!.value as List).cast<double>();

      // Softmax (numerically stable)
      final maxLogit = rawLogits.reduce(max);
      final exps = rawLogits.map((l) => exp(l - maxLogit)).toList();
      final sumExps = exps.reduce((a, b) => a + b);
      final probs = exps.map((e) => e / (sumExps > 0 ? sumExps : 1.0)).toList();

      // Argmax
      int bestClass = 0;
      double bestProb = probs[0];
      for (int i = 1; i < probs.length; i++) {
        if (probs[i] > bestProb) {
          bestProb = probs[i];
          bestClass = i;
        }
      }

      // Normalized Shannon entropy: H in [0, 1] for K classes
      final k = probs.length;
      double entropy = 0.0;
      for (final p in probs) {
        if (p > 1e-9) entropy -= p * log(p);
      }
      entropy /= log(k.toDouble());

      final isOod = bestProb < 0.60 || entropy > 0.85;

      return ClassifierResult(
        probabilities: probs,
        predictedClass: bestClass,
        maxProb: bestProb,
        normalizedEntropy: entropy,
        isOod: isOod,
      );
    } finally {
      inputTensor.release();
      if (outputs != null) {
        for (final o in outputs) {
          o?.release();
        }
      }
    }
  }

  SpeedResult? estimateVehicleSpeed(List<List<double>> window) {
    return _estimateSpeed(_vehicleSpeedSession, window);
  }

  SpeedResult? estimatePedestrianSpeed(List<List<double>> window) {
    return _estimateSpeed(_pedestrianSpeedSession, window);
  }

  SpeedResult? _estimateSpeed(OrtSession? session, List<List<double>> window) {
    if (session == null || window.length != 100) return null;

    // Build (1, 6, 100) tensor - channels first (TCN convention)
    final data = Float32List(1 * 6 * 100);
    for (int c = 0; c < 6; c++) {
      for (int t = 0; t < 100; t++) {
        data[c * 100 + t] = window[t][c];
      }
    }

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      data,
      [1, 6, 100],
    );

    final inputs = {'imu_window': inputTensor};
    final outputNames = session.outputNames;

    List<OrtValue?>? outputs;
    try {
      outputs = session.run(
        OrtRunOptions(),
        inputs,
        outputNames,
      );

      if (outputs.isEmpty || outputs[0] == null) return null;

      final rawOutput = outputs[0]!.value;
      double speedMps;
      if (rawOutput is List) {
        final flat = rawOutput.expand((e) => e is List ? e : [e]).toList();
        speedMps = (flat.first as num).toDouble();
      } else {
        speedMps = (rawOutput as num).toDouble();
      }

      return SpeedResult(speedMps: max(0.0, speedMps));
    } finally {
      inputTensor.release();
      if (outputs != null) {
        for (final o in outputs) {
          o?.release();
        }
      }
    }
  }

  void dispose() {
    _classifierSession?.release();
    _vehicleSpeedSession?.release();
    _pedestrianSpeedSession?.release();
    _classifierSession = null;
    _vehicleSpeedSession = null;
    _pedestrianSpeedSession = null;
    _initialized = false;
    OrtEnv.instance.release();
  }
}
