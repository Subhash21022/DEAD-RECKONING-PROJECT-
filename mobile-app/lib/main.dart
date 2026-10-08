import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/sensor_stream_service.dart';
import 'services/gnss_service.dart';
import 'services/dead_reckoning_service.dart';
import 'services/dead_ranger_service.dart';
import 'services/emergency_sos_service.dart';
import 'services/sync_service.dart';
import 'screens/patrol_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  final notifications = FlutterLocalNotificationsPlugin();
  await notifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );

  runApp(const ForestRangerApp());
}

class ForestRangerApp extends StatelessWidget {
  const ForestRangerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final sensorService = SensorStreamService();
    final gnssService = GnssService();

    return MultiProvider(
      providers: [
        Provider<SensorStreamService>.value(value: sensorService),
        Provider<GnssService>.value(value: gnssService),
        Provider<DeadReckoningService>(
          create: (_) => DeadReckoningService(
            sensorService: sensorService,
            gnssService: gnssService,
          ),
          dispose: (_, s) => s.dispose(),
        ),
        Provider<DeadRangerService>(
          create: (_) => DeadRangerService(
            onAlert: (level, elapsed) {},
          ),
          dispose: (_, s) => s.dispose(),
        ),
        Provider<EmergencySosService>(
          create: (_) => EmergencySosService(),
          dispose: (_, s) => s.dispose(),
        ),
        Provider<SyncService>(
          create: (_) => SyncService(),
          dispose: (_, s) => s.dispose(),
        ),
      ],
      child: MaterialApp(
        title: 'Forest Ranger Nav',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          primaryColor: const Color(0xFF2E7D32),
          scaffoldBackgroundColor: const Color(0xFF0D1B0D),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF2E7D32),
            secondary: Color(0xFFFFB300),
            surface: Color(0xFF1B2A1B),
            error: Color(0xFFD32F2F),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF1B2A1B),
            foregroundColor: Color(0xFFFFB300),
            elevation: 0,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2E7D32),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
          textTheme: const TextTheme(
            bodyMedium: TextStyle(color: Colors.white70),
            bodySmall: TextStyle(color: Colors.white38),
          ),
          fontFamily: 'Roboto',
        ),
        home: const PermissionGate(),
      ),
    );
  }
}

class PermissionGate extends StatefulWidget {
  const PermissionGate({super.key});

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  bool _checking = true;
  bool _granted = false;
  String _statusMessage = 'Requesting permissions...';

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    var locationStatus = await Permission.location.status;
    if (!locationStatus.isGranted) {
      locationStatus = await Permission.location.request();
    }

    await Permission.notification.request();

    if (locationStatus.isGranted) {
      final bgStatus = await Permission.locationAlways.status;
      if (!bgStatus.isGranted) {
        await Permission.locationAlways.request();
      }
    }

    if (locationStatus.isGranted) {
      setState(() {
        _checking = false;
        _granted = true;
      });
    } else {
      setState(() {
        _checking = false;
        _granted = false;
        _statusMessage = 'Location permission is required for navigation. '
            'Please grant location access in Settings.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forest, size: 64, color: Color(0xFF2E7D32)),
              SizedBox(height: 16),
              CircularProgressIndicator(color: Color(0xFFFFB300)),
              SizedBox(height: 16),
              Text('Initializing...', style: TextStyle(color: Colors.white54)),
            ],
          ),
        ),
      );
    }

    if (_granted) {
      return const PatrolScreen();
    }

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_off, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(_statusMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 15)),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() => _checking = true);
                  _requestPermissions();
                },
                child: const Text('Retry'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: openAppSettings,
                child: const Text('Open Settings',
                    style: TextStyle(color: Color(0xFFFFB300))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
