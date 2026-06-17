// lib/widgets/acars_panel.dart
//
// Scrollable Decoded Output message list widget.
// Shows ACARS text, CALL assignments, with AES/GES metadata.
// Compact layout: fits below the waterfall on a tablet screen.

import 'dart:async';
import 'package:flutter/material.dart';
import '../services/aero_service.dart';
import '../services/sdr_ffi.dart';
import 'constellation_view.dart';

class AcarsPanel extends StatefulWidget {
  final AeroService service;
  final SdrFfi? ffi;
  const AcarsPanel({super.key, required this.service, this.ffi});

  @override State<AcarsPanel> createState() => _AcarsPanelState();
}

class _AcarsPanelState extends State<AcarsPanel> {
  final _messages    = <AeroMessage>[];
  final _scrollCtrl  = ScrollController();
  AeroStatus? _status;
  bool _autoScroll   = true;

  StreamSubscription<AeroMessage>? _msgSub;
  StreamSubscription<AeroStatus>?  _stsSub;

  @override void initState() {
    super.initState();
    _msgSub = widget.service.messages.listen((m) {
      setState(() {
        _messages.add(m);
        if (_messages.length > 500) _messages.removeRange(0, 200);
      });
      if (_autoScroll) _scrollToBottom();
    });
    _stsSub = widget.service.status.listen((s) {
      setState(() { _status = s; });
    });
  }

  @override void dispose() {
    _msgSub?.cancel();
    _stsSub?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  Color _rowColor(AeroMessage m) {
    if (m.suType == 'CALL') return Colors.blue.shade900.withOpacity(0.35);
    return m.crcOk ? Colors.green.shade900.withOpacity(0.3) : Colors.transparent;
  }

  @override Widget build(BuildContext context) {
    final locked = _status?.isLocked ?? false;
    final mse    = _status?.mse ?? 1.0;
    final ebNo   = _status?.ebNo ?? 0.0;
    final freq   = _status?.freqHz ?? 0.0;

    return Row(children: [
      // Left: status + messages
      Expanded(flex: 3, child: Column(children: [
        // Status bar
        Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          color: locked ? Colors.green.shade900 : Colors.red.shade900,
          child: Row(children: [
            Icon(locked ? Icons.lock : Icons.lock_open, size: 14,
              color: locked ? Colors.greenAccent : Colors.redAccent),
            const SizedBox(width: 4),
            const Text('Decoded Output', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            const Spacer(),
            Text('MSE ${mse.toStringAsFixed(3)}  ',
                style: TextStyle(fontSize: 10, color: locked ? Colors.greenAccent : Colors.yellowAccent)),
            Text('Eb/No ${ebNo.toStringAsFixed(1)} dB  ',
                style: TextStyle(fontSize: 10, color: locked ? Colors.greenAccent : Colors.yellowAccent)),
            Text('${freq.toStringAsFixed(0)} Hz',
                style: const TextStyle(fontSize: 10, color: Colors.white54)),
            const SizedBox(width: 8),
            Text('${_messages.length} msgs',
                style: const TextStyle(fontSize: 10, color: Colors.white54)),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => setState(() { _messages.clear(); }),
              child: const Icon(Icons.delete_outline, size: 16, color: Colors.white38)),
          ],),),

        // Message list
        Expanded(child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollEndNotification) {
              _autoScroll = n.metrics.pixels >= n.metrics.maxScrollExtent - 20;
            }
            return false;
          },
          child: ListView.builder(controller: _scrollCtrl, itemCount: _messages.length,
            itemBuilder: (ctx, i) {
            final m = _messages[i];
            final isCall = m.suType == 'CALL';

            return Container(
              color: _rowColor(m),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  if (isCall)
                    const Text('📞 ', style: TextStyle(fontSize: 10))
                  else
                    const Text('✈ ', style: TextStyle(fontSize: 10)),
                  Text('${m.suType}  ', style: TextStyle(fontSize: 10, fontFamily: 'monospace',
                    color: isCall ? Colors.lightBlueAccent : Colors.greenAccent,
                    fontWeight: FontWeight.bold)),
                  if (m.aesId.isNotEmpty) ...[
                    Text('AES=${m.aesId}  ', style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.cyanAccent)),
                    Text('GES=${m.gesId}  ', style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.yellowAccent)),
                  ],
                  if (isCall) ...[
                    Text('CH=${m.callChannel}  ', style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.white70)),
                    Text(m.callType, style: TextStyle(fontSize: 10, fontFamily: 'monospace',
                      color: m.callType == 'distress' ? Colors.redAccent : Colors.white54)),
                  ],
                  if (isCall) ...[
                    const Spacer(),
                    Text('RX=${(m.callRxFreq / 1e6).toStringAsFixed(3)}MHz  ',
                      style: const TextStyle(fontSize: 9, fontFamily: 'monospace', color: Colors.white54)),
                    Text('TX=${(m.callTxFreq / 1e6).toStringAsFixed(3)}MHz',
                      style: const TextStyle(fontSize: 9, fontFamily: 'monospace', color: Colors.white38)),
                  ] else if (m.length > 0)
                    Text('LEN=${m.length}', style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.white54)),
                ]),
                if (!isCall && m.hexBytes.isNotEmpty)
                  Text(m.hexBytes,
                    style: TextStyle(
                      color: m.crcOk ? Colors.green : Colors.orange,
                      fontSize: 11, fontFamily: 'monospace', height: 1.3,
                    ),
                    maxLines: null,
                  ),
              ]),
            );
          },
        ),
      )),
    ])),

    // Right: constellation
    if (widget.ffi != null) ...[
      Expanded(flex: 2, child: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: ConstellationView(ffi: widget.ffi!, active: widget.service.isRunning),
      )),
    ],
  ]);
  }
}
