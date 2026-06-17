import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'models/app_theme.dart';
import 'models/waterfall_settings.dart';
import 'providers/radio_provider.dart';
import 'providers/theme_provider.dart';
import 'services/sdr_service.dart';
import 'services/aero_service.dart';
import 'services/version_check.dart';
import 'services/sdr_ffi.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ffi/ffi.dart';
import 'widgets/frequency_display.dart';
import 'widgets/radio_controls.dart';
import 'widgets/acars_panel.dart';
import 'utils/responsive.dart';

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
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SdrService>.value(value: sdr),
        ChangeNotifierProvider<RadioProvider>(create: (_) => RadioProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
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

class _HomeScreenState extends State<HomeScreen> {
  final _aeroService = AeroService(SdrFfi.instance);
  bool _aeroActive = false;
  bool _biasTeeOn  = false;
  bool _recording  = false;
  bool _recordingRaw = false;
  double _ncoOffset = 0;
  double _symbolRate = 10500;

  bool _voiceFollow = true;   /* auto-tune to voice when VASSIGN received */
  double _prevPchanFreq = 0;  /* frequency to return to after voice call ends */
  StreamSubscription<AeroMessage>? _msgSub;

  @override void initState() {
    super.initState();
    _msgSub = _aeroService.messages.listen(_onAeroMessage);
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
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    });
  }

  void _onAeroMessage(AeroMessage msg) {
    if (!mounted || !_aeroActive) return;
    if (msg.suType == 'VASSIGN' && msg.callType == 'C_ASSIGN' && _voiceFollow && _symbolRate <= 1200.0) {
      final radio = context.read<RadioProvider>();
      final sdr = context.read<SdrService>();
      if (!sdr.isRunning) return;
      _prevPchanFreq = radio.frequencyHz;
      _aeroService.onVoiceAssign(msg, radio.frequencyHz.round(), 1200.0);
      setState(() {
        _symbolRate = 8400.0;
        SdrFfi.instance.setAeroSymbolRate(8400.0);
      });
      radio.setFrequency(msg.callRxFreq.toDouble());
      _msg('Voice: tuning to ${(msg.callRxFreq / 1e6).toStringAsFixed(4)} MHz');
    } else if (msg.suType == 'REVERT' && _voiceFollow) {
      final radio = context.read<RadioProvider>();
      if (_prevPchanFreq > 0) {
        radio.setFrequency(_prevPchanFreq);
        _prevPchanFreq = 0;
      }
      _aeroService.revertVoiceFollow();
      setState(() {
        _symbolRate = 1200.0;
        SdrFfi.instance.setAeroSymbolRate(1200.0);
      });
      _msg('Voice call ended, returning to P-channel');
    }
  }

  @override void dispose() {
    _msgSub?.cancel();
    _aeroService.dispose();
    super.dispose();
  }

  void _msg(String s, {bool error = false}) {
    debugPrint(s);
    if (mounted) {
      ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s),
          backgroundColor: error ? Colors.red.shade800 : null,
          duration: const Duration(seconds: 2)));
    }
  }

  Future<void> _connect() async {
    final sdr = context.read<SdrService>();
    final radio = context.read<RadioProvider>();
    try {
      sdr.resetState();
      await sdr.scanDevices();
      final devs = sdr.devices;
      if (devs.isEmpty) { _msg('No RTL-SDR found', error: true); return; }
      _msg('Found ${devs.length} device, connecting...');
      await sdr.connect(devs.first);
      if (!sdr.isRunning) {
        _msg('Not running after connect. SDR error: ${sdr.error}', error: true);
        return;
      }
      radio.attachBackend(sdr);
      radio.setFrequency(1545052985);
      radio.updateWaterfallSettings(
        const WaterfallSettings().copyWith(sampleRateHz: 1024000));
      sdr.setSampleRate(1024000);
      _msg('1.024 Msps, 49.6dB');
      setState(() {});
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_REQUESTED') {
        _msg('USB permission needed — retrying after grant...');
        Future.delayed(const Duration(seconds: 2), _connect);
      } else {
        _msg('USB: ${e.message}', error: true);
      }
    } catch (e) {
      _msg('Error: $e', error: true);
    }
  }

  void _adjustNco(double delta) {
    setState(() {
      _ncoOffset += delta;
      if (_ncoOffset < 0) _ncoOffset = 0;
      if (_ncoOffset > 30000) _ncoOffset = 30000;
      SdrFfi.instance.setAeroOffset(_ncoOffset);
      _msg('NCO offset: ${_ncoOffset.toInt()} Hz');
    });
  }

  void _toggleAero() {
    setState(() {
      _aeroActive = !_aeroActive;
      if (_aeroActive) {
        _aeroService.start();
        SdrFfi.instance.setAeroOffset(_ncoOffset);
        SdrFfi.instance.setAeroSymbolRate(_symbolRate);
        _msg('AERO decoder started');
      } else {
        _aeroService.stop();
        _prevPchanFreq = 0;
        _msg('AERO decoder stopped');
      }
    });
  }

  void _toggleBiasTee() {
    setState(() {
      _biasTeeOn = !_biasTeeOn;
      SdrFfi.instance.setBiasTee(_biasTeeOn);
      _msg('Bias Tee ${_biasTeeOn ? "ON" : "OFF"}');
    });
  }

  void _toggleRecording() {
    setState(() {
      _recording = !_recording;
      if (_recording) {
        final ts = DateTime.now().millisecondsSinceEpoch;
        final path = '/storage/emulated/0/Download/aero_iq_$ts.wav';
        final pathPtr = path.toNativeUtf8();
        final r = SdrFfi.instance.startAeroRecording(pathPtr);
        malloc.free(pathPtr);
        if (r == 0) {
          _msg('Recording IQ to Downloads...');
        } else {
          _recording = false;
          _msg('Recording failed (permissions?)', error: true);
        }
      } else {
        SdrFfi.instance.stopAeroRecording();
        _msg('Recording saved to Downloads');
      }
    });
  }

  void _toggleRecordingRaw() {
    setState(() {
      _recordingRaw = !_recordingRaw;
      if (_recordingRaw) {
        final radio = context.read<RadioProvider>();
        final ts = DateTime.now().millisecondsSinceEpoch;
        final mhz = (radio.frequencyHz / 1e6).toStringAsFixed(3);
        final path = '/storage/emulated/0/Download/aero_raw_${mhz}MHz_$ts.wav';
        final pathPtr = path.toNativeUtf8();
        final r = SdrFfi.instance.startAeroRecordingRaw(pathPtr);
        malloc.free(pathPtr);
        if (r == 0) {
          _msg('Recording RAW at $mhz MHz...');
        } else {
          _recordingRaw = false;
          _msg('RAW recording failed', error: true);
        }
      } else {
        SdrFfi.instance.stopAeroRecordingRaw();
        _msg('RAW recording saved to Downloads');
      }
    });
  }

  Future<void> _loadWavFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;

      final path = result.files.first.path;
      if (path == null) { _msg('No path', error: true); return; }

      _msg('Loading: $path');

      _aeroService.stop();
      _aeroService.start();
      setState(() { _aeroActive = true; });

      final pathPtr = path.toNativeUtf8();
      SdrFfi.instance.loadWavAero(pathPtr);
      malloc.free(pathPtr);

      _msg('WAV decode complete');
    } catch (e) {
      _msg('Error: $e', error: true);
    }
  }

  // ── widget builders ────────────────────────────────────────────────────────

  Widget _ncoChip(double delta, ResponsiveScale rs) {
    final stretch = rs.stretchTapTarget;
    return Padding(
      padding: EdgeInsets.zero,
      child: ActionChip(
        label: Text('${delta > 0 ? "+" : ""}${delta.toInt()}',
          style: TextStyle(fontSize: rs.fontSize(stretch ? 11 : 9), color: Colors.black)),
        onPressed: _aeroActive ? () => _adjustNco(delta) : null,
        materialTapTargetSize: stretch ? MaterialTapTargetSize.padded : MaterialTapTargetSize.shrinkWrap,
        visualDensity: stretch ? VisualDensity.standard : VisualDensity.compact,
      ),
    );
  }

  Widget _toggleChip({
    required IconData icon, required String label, required bool active,
    Color activeColor = Colors.greenAccent, required Color activeBg,
    required ResponsiveScale rs, required VoidCallback? onPressed,
  }) {
    final stretch = rs.stretchTapTarget;
    final cs = Theme.of(context).colorScheme;
    final inactiveText = cs.onSurface.withValues(alpha: 0.7);
    return ActionChip(
      avatar: Icon(icon, size: rs.iconSize(16), color: active ? activeColor : cs.onSurface.withValues(alpha: 0.5)),
      label: Text(label, style: TextStyle(
        fontSize: rs.fontSize(11), color: active ? activeColor : inactiveText)),
      onPressed: onPressed,
      backgroundColor: active ? activeBg : cs.surfaceContainerHighest,
      materialTapTargetSize: stretch ? MaterialTapTargetSize.padded : MaterialTapTargetSize.shrinkWrap,
      visualDensity: stretch ? VisualDensity.standard : VisualDensity.compact,
    );
  }

  Widget _baudChip(double baud, ResponsiveScale rs) {
    final active = _symbolRate == baud;
    final isVoice = baud == 8400;
    final isPchan = baud == 1200 || baud == 600;
    final stretch = rs.stretchTapTarget;
    final cs = Theme.of(context).colorScheme;
    final IconData chipIcon = isPchan ? Icons.settings_input_antenna
        : isVoice ? Icons.phone_in_talk : Icons.text_snippet;
    final Color chipColor = active
        ? (isPchan ? Colors.blueAccent : isVoice ? Colors.purpleAccent : Colors.greenAccent)
        : cs.onSurface.withValues(alpha: 0.5);
    final Color chipBg = active
        ? (isPchan ? Colors.blue.shade800 : isVoice ? Colors.purple.shade800 : Colors.green.shade800)
        : cs.surfaceContainerHighest;
    return Padding(
      padding: EdgeInsets.zero,
      child: ActionChip(
        avatar: Icon(chipIcon,
          size: rs.iconSize(14), color: chipColor),
        label: Text('${baud.toInt()}', style: TextStyle(
          fontSize: rs.fontSize(stretch ? 11 : 9), color: active ? Colors.white : cs.onSurface)),
        onPressed: () {
          setState(() {
            _symbolRate = baud;
            SdrFfi.instance.setAeroSymbolRate(_symbolRate);
            _msg('Symbol rate: ${baud.toInt()} baud');
          });
        },
        backgroundColor: chipBg,
        materialTapTargetSize: stretch ? MaterialTapTargetSize.padded : MaterialTapTargetSize.shrinkWrap,
        visualDensity: stretch ? VisualDensity.standard : VisualDensity.compact,
      ),
    );
  }

  Widget _recChip({
    required IconData icon, required String label, required bool recording,
    Color activeColor = Colors.redAccent,
    required ResponsiveScale rs, required VoidCallback? onPressed,
  }) {
    final stretch = rs.stretchTapTarget;
    final cs = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(recording ? Icons.stop : icon,
        size: rs.iconSize(16), color: recording ? cs.onSurface.withValues(alpha: 0.5) : activeColor),
      label: Text(recording ? 'STOP' : label, style: TextStyle(
        fontSize: rs.fontSize(11), color: recording ? cs.onSurface : activeColor)),
      onPressed: onPressed,
      backgroundColor: cs.surfaceContainerHighest,
      materialTapTargetSize: stretch ? MaterialTapTargetSize.padded : MaterialTapTargetSize.shrinkWrap,
      visualDensity: stretch ? VisualDensity.standard : VisualDensity.compact,
    );
  }

  // ── Layout: controls left, waterfall right, decoded bottom-right ────────

  Widget _buildLayout(RadioProvider radio, bool running, ResponsiveScale rs) {
    final freqSize   = rs.fontSize(18);
    final toggleSize = rs.fontSize(12);
    final labelSize  = rs.fontSize(11);

    Widget pad4 = SizedBox(height: rs.spacing(4));
    Widget pad8 = SizedBox(height: rs.spacing(8));

    Widget controlPanel = SingleChildScrollView(
      padding: EdgeInsets.only(right: rs.spacing(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Frequency display
          Text('${(radio.frequencyHz / 1e6).toStringAsFixed(6)} MHz',
            style: TextStyle(fontFamily: 'monospace', fontSize: freqSize,
              fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurface, letterSpacing: 1.5)),
          pad8,

          // CONNECT/STOP
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: running
                ? () { radio.backend?.disconnect(); _aeroService.stop(); setState(() { _aeroActive = false; }); }
                : _connect,
              style: ElevatedButton.styleFrom(backgroundColor: running ? Colors.red : Colors.green),
              child: Text(running ? 'STOP' : 'CONNECT',
                style: TextStyle(fontSize: rs.fontSize(13)))),
          ),
          pad8,

          // Decode / Bias toggles (no section header)
          _toggleChip(
            icon: _aeroActive ? Icons.flight : Icons.flight_takeoff,
            label: _aeroActive ? 'DECODE ON' : 'DECODE OFF', active: _aeroActive,
            activeColor: Colors.greenAccent, activeBg: Colors.green.shade800,
            rs: rs, onPressed: running ? _toggleAero : null),
          pad4,
          _toggleChip(
            icon: _biasTeeOn ? Icons.power : Icons.power_off,
            label: _biasTeeOn ? 'BIAS ON' : 'BIAS OFF', active: _biasTeeOn,
            activeColor: Colors.redAccent, activeBg: Colors.red.shade800,
            rs: rs, onPressed: running ? _toggleBiasTee : null),
          pad4,
          // Theme toggle
          Builder(builder: (ctx) {
            final isDark = ctx.watch<ThemeProvider>().isDark;
            final cs2 = Theme.of(ctx).colorScheme;
            return ActionChip(
              avatar: Icon(isDark ? Icons.dark_mode : Icons.light_mode,
                size: rs.iconSize(16), color: isDark ? Colors.amberAccent : Colors.orangeAccent),
              label: Text(isDark ? 'DARK' : 'LIGHT',
                style: TextStyle(fontSize: rs.fontSize(11), color: cs2.onSurface)),
              onPressed: () => ctx.read<ThemeProvider>().toggle(),
              backgroundColor: cs2.surfaceContainerHighest,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact);
          }),
          pad8,

          // Baud rate
          Text('BAUD', style: TextStyle(fontSize: labelSize,
            color: Colors.grey[600], fontWeight: FontWeight.w600, letterSpacing: 1.2)),
          pad4,
          Wrap(spacing: 4, runSpacing: 4, children: [for (final b in [600.0, 1200.0, 8400.0, 10500.0]) _baudChip(b, rs)]),
          pad8,

          // Recording (debug only)
          if (kDebugMode) ...[
            Text('RECORD', style: TextStyle(fontSize: labelSize,
              color: Colors.grey[600], fontWeight: FontWeight.w600, letterSpacing: 1.2)),
            pad4,
            Row(children: [
              ActionChip(
                avatar: Icon(Icons.folder_open, size: rs.iconSize(16), color: Colors.black54),
                label: Text('WAV', style: TextStyle(fontSize: toggleSize, color: Colors.black87)),
                onPressed: _loadWavFile, backgroundColor: Colors.grey.shade200),
              _recChip(icon: Icons.fiber_manual_record, label: 'REC', recording: _recording,
                rs: rs, onPressed: running && _aeroActive ? _toggleRecording : null),
              _recChip(icon: Icons.raw_on, label: 'RAW', recording: _recordingRaw,
                activeColor: Colors.purpleAccent, rs: rs,
                onPressed: running ? _toggleRecordingRaw : null),
            ]),
            pad8,
          ],

          // NCO offset (debug only)
          if (kDebugMode) ...[
            Text('NCO OFFSET', style: TextStyle(fontSize: labelSize,
              color: Colors.grey[600], fontWeight: FontWeight.w600, letterSpacing: 1.2)),
            pad4,
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final d in [-5000.0, -1000.0, -100.0, 100.0, 1000.0, 5000.0])
                _ncoChip(d, rs),
            ]),
            pad4,
            Text('${_ncoOffset.toInt()} Hz', style: TextStyle(
              fontSize: toggleSize, color: Colors.black87, fontFamily: 'monospace')),
            pad8,
          ],

          // Spectrum controls at bottom of left panel
          SpectrumControls(),
        ],
      ),
    );

    return Row(children: [
      // Left control panel (~32% wide)
      SizedBox(width: MediaQuery.of(context).size.width * 0.32,
        child: controlPanel),
      SizedBox(width: rs.spacing(8)),
      // Right side: waterfall + decoded (vertical split)
      Expanded(child: Column(children: [
        Expanded(flex: 5, child: _aeroActive
          ? const WaterfallDisplay(zoomBandwidthHz: 50000)
          : const WaterfallDisplay()),
        SizedBox(height: rs.spacing(4)),
        Expanded(flex: 3, child: AcarsPanel(service: _aeroService, ffi: SdrFfi.instance)),
      ])),
    ]);
  }

  // ── top-level build ────────────────────────────────────────────────────────

  @override Widget build(BuildContext context) {
    final radio = context.watch<RadioProvider>();
    final running = radio.backend?.isRunning ?? false;
    final rs = ResponsiveScale(context);

    return Scaffold(body: SafeArea(child: Padding(
      padding: EdgeInsets.all(rs.spacing(6)), child:
      _buildLayout(radio, running, rs),
    )));
  }
}
