import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/waterfall_settings.dart';
import '../providers/radio_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/aero_provider.dart';
import '../services/sdr_ffi.dart';
import '../services/sdr_service.dart';
import '../widgets/frequency_display.dart';
import '../widgets/acars_panel.dart';
import '../widgets/constellation_view.dart';
import '../widgets/radio_controls.dart';
import '../utils/responsive.dart';

class WaterfallTab extends StatelessWidget {
  const WaterfallTab({super.key});

  void _connect(BuildContext context) async {
    final sdr = context.read<SdrService>();
    final radio = context.read<RadioProvider>();
    final aero = context.read<AeroProvider>();
    final rs = ResponsiveScale(context);
    try {
      sdr.resetState();
      await sdr.scanDevices();
      final devs = sdr.devices;
      if (devs.isEmpty) {
        _snackErr(context, 'No RTL-SDR found');
        return;
      }
      _snack(context, 'Found ${devs.length} device, connecting...');
      await sdr.connect(devs.first);
      if (!sdr.isRunning) {
        _snackErr(context, 'Not running after connect. SDR error: ${sdr.error}');
        return;
      }
      radio.attachBackend(sdr);
      radio.setFrequency(1545052985);
      radio.updateWaterfallSettings(
        const WaterfallSettings().copyWith(sampleRateHz: 1024000));
      sdr.setSampleRate(1024000);
      _snack(context, '1.024 Msps, 49.6dB');
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_REQUESTED') {
        _snack(context, 'USB permission needed — retrying after grant...');
        Future.delayed(const Duration(seconds: 2), () => _connect(context));
      } else {
        _snackErr(context, 'USB: ${e.message}');
      }
    } catch (e) {
      _snackErr(context, 'Error: $e');
    }
  }

  void _snack(BuildContext context, String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  void _snackErr(BuildContext context, String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg),
        backgroundColor: Colors.red.shade800,
        duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final radio = context.watch<RadioProvider>();
    final aero = context.watch<AeroProvider>();
    final running = radio.backend?.isRunning ?? false;
    final rs = ResponsiveScale(context);
    final cs = Theme.of(context).colorScheme;
    final isTablet = Breakpoints.isTablet(context);

    final freqSize   = rs.fontSize(isTablet ? 18 : 14);
    final labelSize  = rs.fontSize(11);

    Widget pad4 = SizedBox(height: rs.spacing(4));
    Widget pad6 = SizedBox(height: rs.spacing(6));

    Widget controlPanel = SingleChildScrollView(
      padding: EdgeInsets.only(right: rs.spacing(isTablet ? 8 : 4)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${(radio.frequencyHz / 1e6).toStringAsFixed(6)} MHz',
            style: TextStyle(fontFamily: 'monospace', fontSize: freqSize,
              fontWeight: FontWeight.w700, color: cs.onSurface, letterSpacing: 1.5)),
          pad6,

          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: running
                ? () {
                    radio.backend?.disconnect();
                    aero.stopAero(context);
                  }
                : () => _connect(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: running ? Colors.red : Colors.green,
                padding: EdgeInsets.symmetric(vertical: isTablet ? 12 : 6),
              ),
              child: Text(running ? 'STOP' : 'CONNECT',
                style: TextStyle(fontSize: rs.fontSize(isTablet ? 13 : 11)))),
          ),
          pad6,

          _toggleChip(context,
            icon: aero.aeroActive ? Icons.flight : Icons.flight_takeoff,
            label: aero.aeroActive ? 'DECODE ON' : 'DECODE OFF',
            active: aero.aeroActive,
            activeColor: Colors.greenAccent, activeBg: Colors.green.shade800,
            rs: rs, onPressed: running ? () => aero.toggleAero(context) : null),
          pad4,
          _toggleChip(context,
            icon: aero.biasTeeOn ? Icons.power : Icons.power_off,
            label: aero.biasTeeOn ? 'BIAS ON' : 'BIAS OFF',
            active: aero.biasTeeOn,
            activeColor: Colors.redAccent, activeBg: Colors.red.shade800,
            rs: rs, onPressed: running ? () => aero.toggleBiasTee(context) : null),
          pad6,

          if (isTablet) ...[
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
            pad6,
          ],

          Text('BAUD', style: TextStyle(fontSize: labelSize,
            color: Colors.grey[600], fontWeight: FontWeight.w600, letterSpacing: 1.2)),
          pad4,
          Wrap(spacing: 4, runSpacing: 4, children: [
            for (final b in [600.0, 1200.0, 8400.0, 10500.0])
              _baudChip(context, b, aero, rs),
          ]),
          pad6,

          const SpectrumControls(),
        ],
      ),
    );

    final wfWidget = aero.aeroActive
        ? WaterfallDisplay(
            zoomBandwidthHz: 50000,
            ncoOffsetHz: aero.symbolRate > 1200 ? aero.ncoOffset : 0,
            onNcoDrag: aero.symbolRate > 1200 ? (hz) => aero.setNcoOffset(hz) : null,
            onNcoDragEnd: aero.symbolRate > 1200 ? () => aero.commitNcoOffset() : null,
          )
        : const WaterfallDisplay();

    if (isTablet) {
      return Row(children: [
        SizedBox(width: MediaQuery.of(context).size.width * 0.32,
          child: controlPanel),
        SizedBox(width: rs.spacing(8)),
        Expanded(child: Column(children: [
          Expanded(flex: 5, child: wfWidget),
          SizedBox(height: rs.spacing(4)),
          Expanded(flex: 3, child: AcarsPanel(service: aero.service, ffi: SdrFfi.instance)),
        ])),
      ]);
    }

    // ── Phone layout: waterfall fills area, constellation + stats overlay ──
    return Row(children: [
      SizedBox(width: MediaQuery.of(context).size.width * 0.26,
        child: controlPanel),
      SizedBox(width: rs.spacing(4)),
      Expanded(child: Stack(children: [
        wfWidget,
        Positioned(bottom: 28, right: 20,
          width: 120, height: 120,
          child: ConstellationView(ffi: SdrFfi.instance,
              active: aero.aeroActive)),
        if (aero.aeroActive)
          const Positioned(bottom: 0, left: 0, right: 0,
            child: _AeroStatsBar()),
      ])),
    ]);
  }

  Widget _toggleChip(BuildContext context, {
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
        fontSize: rs.fontSize(stretch ? 11 : 9), color: active ? activeColor : inactiveText)),
      onPressed: onPressed,
      backgroundColor: active ? activeBg : cs.surfaceContainerHighest,
      materialTapTargetSize: stretch ? MaterialTapTargetSize.padded : MaterialTapTargetSize.shrinkWrap,
      visualDensity: stretch ? VisualDensity.standard : VisualDensity.compact,
    );
  }

  Widget _baudChip(BuildContext context, double baud, AeroProvider aero, ResponsiveScale rs) {
    final active = aero.symbolRate == baud;
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
        avatar: Icon(chipIcon, size: rs.iconSize(14), color: chipColor),
        label: Text('${baud.toInt()}', style: TextStyle(
          fontSize: rs.fontSize(stretch ? 11 : 9), color: active ? Colors.white : cs.onSurface)),
        onPressed: () => aero.setSymbolRate(baud, context),
        backgroundColor: chipBg,
        materialTapTargetSize: stretch ? MaterialTapTargetSize.padded : MaterialTapTargetSize.shrinkWrap,
        visualDensity: stretch ? VisualDensity.standard : VisualDensity.compact,
      ),
    );
  }
}

/// Phone-only compact stats bar: MSE + EbNo overlay at bottom of waterfall.
class _AeroStatsBar extends StatefulWidget {
  const _AeroStatsBar();
  @override State<_AeroStatsBar> createState() => _AeroStatsBarState();
}

class _AeroStatsBarState extends State<_AeroStatsBar> {
  double _mse = 1.0;
  double _ebNo = 0.0;

  @override void initState() {
    super.initState();
    _poll();
  }

  void _poll() async {
    if (!mounted) return;
    try {
      final mse = SdrFfi.instance.getAeroMse();
      final ebNo = SdrFfi.instance.getAeroEbNo();
      setState(() { _mse = mse; _ebNo = ebNo; });
    } catch (_) {}
    Future.delayed(const Duration(milliseconds: 500), _poll);
  }

  @override
  Widget build(BuildContext context) {
    final locked = _mse < 0.5;
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: (locked ? Colors.green.shade900 : Colors.red.shade900)
            .withValues(alpha: 0.75),
      ),
      child: Row(children: [
        Icon(locked ? Icons.lock : Icons.lock_open, size: 12,
          color: locked ? Colors.greenAccent : Colors.redAccent),
        const SizedBox(width: 4),
        Text('MSE ${_mse.toStringAsFixed(3)}',
          style: TextStyle(fontSize: 10, fontFamily: 'monospace',
            color: locked ? Colors.greenAccent : Colors.yellowAccent)),
        Text('  Eb/No ${_ebNo.toStringAsFixed(1)} dB',
          style: TextStyle(fontSize: 10, fontFamily: 'monospace',
            color: locked ? Colors.greenAccent : Colors.yellowAccent)),
      ]),
    );
  }
}
