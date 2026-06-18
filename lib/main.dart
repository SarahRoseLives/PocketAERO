import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'models/app_theme.dart';
import 'providers/radio_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/aero_provider.dart';
import 'services/sdr_service.dart';
import 'services/aero_service.dart';
import 'services/version_check.dart';
import 'services/sdr_ffi.dart';
import 'tabs/waterfall_tab.dart';
import 'tabs/sus_tab.dart';
import 'tabs/acars_tab.dart';
import 'tabs/aircraft_tab.dart';
import 'tabs/cchannel_tab.dart';
import 'tabs/settings_tab.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const PaeroApp());
}

class PaeroApp extends StatelessWidget {
  const PaeroApp({super.key});
  @override Widget build(BuildContext context) {
    final sdr = SdrService();
    final aeroSvc = AeroService(SdrFfi.instance);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SdrService>.value(value: sdr),
        ChangeNotifierProvider<RadioProvider>(create: (_) => RadioProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
        ChangeNotifierProvider<AeroProvider>(create: (_) => AeroProvider(service: aeroSvc)),
      ],
      child: Builder(builder: (context) {
        final themeMode = context.watch<ThemeProvider>().mode;
        return MaterialApp(title: 'PAERO', debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: themeMode,
          home: const HomeScreen());
      }),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late final TabController _tabController;
  StreamSubscription<AeroMessage>? _msgSub;

  @override void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
    final aero = context.read<AeroProvider>();
    _msgSub = aero.service.messages.listen((msg) => _onAeroMessage(msg, aero));
    _checkForUpdate();
  }

  void _checkForUpdate() async {
    final vc = VersionCheckService();
    await vc.check();
    if (!mounted || !vc.updateAvailable) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.system_update, color: Colors.blue),
            SizedBox(width: 8),
            Text('Update Available'),
          ]),
          content: Text('PocketAERO v${vc.remoteVersion} is available.\n'
              'You are running v${vc.localVersion}.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    });
  }

  void _onAeroMessage(AeroMessage msg, AeroProvider aero) {
    if (!mounted || !aero.aeroActive) return;
    final sdr = context.read<SdrService>();
    final radio = context.read<RadioProvider>();
    if (!sdr.isRunning) return;

    if (msg.suType == 'VASSIGN' && msg.callType == 'C_ASSIGN' && aero.voiceFollow) {
      aero.handleVoiceAssign(msg, radio);
      _snack('Voice: tuning to ${(msg.callRxFreq / 1e6).toStringAsFixed(4)} MHz');
    } else if (msg.suType == 'REVERT' && aero.voiceFollow) {
      aero.handleVoiceRevert(radio);
      _snack('Voice call ended, returning to P-channel');
    }
  }

  void _snack(String s) {
    if (!kDebugMode || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  @override void dispose() {
    _msgSub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final aero = context.watch<AeroProvider>();

    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: IndexedStack(
              index: _tabController.index,
              children: const [
                WaterfallTab(),
                SUsTab(),
                AcarsTab(),
                AircraftTab(),
                CChannelTab(),
                SettingsTab(),
              ],
            ),
          ),
          TabBar(
            controller: _tabController,
            isScrollable: false,
            tabAlignment: TabAlignment.fill,
            labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 11),
            indicatorWeight: 3,
            indicatorColor: cs.primary,
            labelColor: cs.primary,
            unselectedLabelColor: cs.onSurface.withValues(alpha: 0.5),
            tabs: [
              const Tab(icon: Icon(Icons.water_drop, size: 18), text: 'WFALL'),
              Tab(icon: Badge(
                label: Text('${aero.totalPchan}', style: const TextStyle(fontSize: 9)),
                isLabelVisible: aero.totalPchan > 0,
                child: const Icon(Icons.settings_input_antenna, size: 18),
              ), text: 'SUs'),
              Tab(icon: Badge(
                label: Text('${aero.totalAcars}', style: const TextStyle(fontSize: 9)),
                isLabelVisible: aero.totalAcars > 0,
                child: const Icon(Icons.text_snippet, size: 18),
              ), text: 'ACARS'),
              Tab(icon: Badge(
                label: Text('${aero.aircraft.length}', style: const TextStyle(fontSize: 9)),
                isLabelVisible: aero.aircraft.isNotEmpty,
                child: const Icon(Icons.flight, size: 18),
              ), text: 'A/C'),
              Tab(icon: Badge(
                label: Text('${aero.totalCalls}', style: const TextStyle(fontSize: 9)),
                isLabelVisible: aero.totalCalls > 0,
                child: const Icon(Icons.phone_in_talk, size: 18),
              ), text: 'C-CH'),
              const Tab(icon: Icon(Icons.settings, size: 18), text: 'SET'),
            ],
          ),
        ]),
      ),
    );
  }
}
