import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';

enum NetworkState {
  online,
  offline;

  String get label => this == NetworkState.online ? 'ONLINE' : 'OFFLINE';
  bool get isOnline => this == NetworkState.online;
  bool get isOffline => this == NetworkState.offline;
}

/// NetworkManager tracks strictly Internet and local network connectivity.
/// 
/// ARCHITECTURAL RULE:
/// Internet connectivity and GNSS availability are NOT the same thing.
/// Turning off Wi-Fi or mobile data updates NetworkState to OFFLINE, but MUST
/// never affect GNSSState or Dead Reckoning navigation.
class NetworkManager {
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _heartbeatTimer;

  NetworkState _state = NetworkState.offline;
  NetworkState get state => _state;
  bool get isOnline => _state == NetworkState.online;

  final _controller = StreamController<NetworkState>.broadcast();
  Stream<NetworkState> get stateStream => _controller.stream;

  bool _initialized = false;

  Future<void> start() async {
    if (_initialized) return;
    _initialized = true;

    // Check initial status
    try {
      final results = await _connectivity.checkConnectivity();
      await _evaluateConnectivity(results);
    } catch (_) {
      _setState(NetworkState.offline);
    }

    // Listen to OS network interface transitions
    _subscription = _connectivity.onConnectivityChanged.listen((results) {
      _evaluateConnectivity(results);
    });

    // Periodic reachability probe (every 8s) to confirm internet access
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 8), (_) async {
      await _checkReachability();
    });
  }

  Future<void> _evaluateConnectivity(List<ConnectivityResult> results) async {
    final hasInterface = results.any((r) =>
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.ethernet);

    if (!hasInterface) {
      _setState(NetworkState.offline);
      return;
    }

    await _checkReachability();
  }

  Future<void> _checkReachability() async {
    try {
      final result = await InternetAddress.lookup('8.8.8.8')
          .timeout(const Duration(milliseconds: 1500));
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        _setState(NetworkState.online);
        return;
      }
    } catch (_) {}

    // Fallback probe
    try {
      final socket = await Socket.connect('1.1.1.1', 53,
              timeout: const Duration(milliseconds: 1200))
          .then((s) {
        s.destroy();
        return true;
      }).catchError((_) => false);

      _setState(socket ? NetworkState.online : NetworkState.offline);
    } catch (_) {
      _setState(NetworkState.offline);
    }
  }

  void _setState(NetworkState newState) {
    if (_state != newState) {
      _state = newState;
      _controller.add(newState);
    }
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _initialized = false;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
