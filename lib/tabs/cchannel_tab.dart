import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/aero_provider.dart';
import '../services/aero_service.dart';

class CChannelTab extends StatelessWidget {
  const CChannelTab({super.key});

  @override
  Widget build(BuildContext context) {
    final aero = context.watch<AeroProvider>();
    final cs = Theme.of(context).colorScheme;

    final callMsgs = aero.messages
      .where((m) => m.suType == 'CALL')
      .toList();

    final vassignMsgs = aero.messages
      .where((m) => m.suType == 'VASSIGN')
      .toList();

    final voiceActive = aero.service.isVoiceFollowing;

    return Column(children: [
      _buildHeader(context, voiceActive, cs),
      const Divider(height: 1),

      // Voice-follow status card
      Container(
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: voiceActive
            ? Colors.purple.shade900.withValues(alpha: 0.3)
            : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: voiceActive
            ? Colors.purpleAccent.withValues(alpha: 0.5)
            : cs.outlineVariant.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          Icon(voiceActive ? Icons.phone_in_talk : Icons.phone_paused,
            color: voiceActive ? Colors.purpleAccent : cs.onSurface.withValues(alpha: 0.5),
            size: 24),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Voice Follow', style: TextStyle(
              fontWeight: FontWeight.w600, color: cs.onSurface)),
            Text(voiceActive ? 'Active — monitoring 8400 bps'
                : aero.voiceFollow ? 'Armed — waiting for C_ASSIGN' : 'Disabled',
              style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.6))),
          ]),
          const Spacer(),
          Switch(
            value: aero.voiceFollow,
            onChanged: (v) => aero.setVoiceFollow(v),
            activeColor: Colors.purpleAccent),
        ]),
      ),

      const SizedBox(height: 8),

      // VASSIGN history
      if (vassignMsgs.isNotEmpty) ...[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          child: Row(children: [
            Text('VASSIGN (${vassignMsgs.length})', style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: Colors.purpleAccent)),
          ]),
        ),
        Expanded(
          flex: 2,
          child: ListView.builder(
            itemCount: vassignMsgs.length,
            itemBuilder: (ctx, i) => _buildVassignCard(vassignMsgs[i], cs),
          ),
        ),
      ],

      // CALL history
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        child: Row(children: [
          Text('Voice Calls (${callMsgs.length})', style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: Colors.cyanAccent)),
        ]),
      ),
      Expanded(
        flex: 3,
        child: ListView.builder(
          itemCount: callMsgs.length,
          itemBuilder: (ctx, i) => _buildCallCard(callMsgs[i], cs),
        ),
      ),
    ]);
  }

  Widget _buildHeader(BuildContext context, bool voiceActive, ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: cs.surfaceContainerHighest,
      child: Row(children: [
        Icon(Icons.phone_in_talk, size: 18, color: Colors.purpleAccent),
        const SizedBox(width: 8),
        Text('C-Channel Voice', style: TextStyle(
          fontWeight: FontWeight.w600, fontSize: 13, color: cs.onSurface)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: voiceActive ? Colors.purple.shade800 : Colors.grey.shade800,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(voiceActive ? 'ACTIVE' : 'IDLE',
            style: TextStyle(fontSize: 10, color: voiceActive ? Colors.purpleAccent : Colors.grey.shade400)),
        ),
      ]),
    );
  }

  Widget _buildVassignCard(AeroMessage msg, ColorScheme cs) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.purple.shade900.withValues(alpha: 0.2),
        border: Border(bottom: BorderSide(
          color: cs.outlineVariant.withValues(alpha: 0.3), width: 0.5)),
      ),
      child: Row(children: [
        Text(msg.callType, style: TextStyle(
          fontSize: 11, fontWeight: FontWeight.w600, color: Colors.purpleAccent)),
        const SizedBox(width: 8),
        Text('AES=${msg.aesId}', style: TextStyle(fontSize: 11, fontFamily: 'monospace',
          color: cs.onSurface.withValues(alpha: 0.8))),
        if (msg.gesId > 0) ...[
          const SizedBox(width: 8),
          Text('GES=${msg.gesId}', style: TextStyle(fontSize: 11,
            color: cs.onSurface.withValues(alpha: 0.6))),
        ],
        if (msg.callRxFreq > 0) ...[
          const SizedBox(width: 8),
          Text('RX=${(msg.callRxFreq / 1e6).toStringAsFixed(4)}',
            style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.greenAccent)),
        ],
        const Spacer(),
        Text(msg.timestamp.toString().substring(11, 19),
          style: TextStyle(fontSize: 10, color: cs.onSurface.withValues(alpha: 0.4))),
      ]),
    );
  }

  Widget _buildCallCard(AeroMessage msg, ColorScheme cs) {
    final isDistress = msg.callType == 'distress';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isDistress ? Colors.red.shade900.withValues(alpha: 0.3) : null,
        border: Border(bottom: BorderSide(
          color: cs.outlineVariant.withValues(alpha: 0.3), width: 0.5)),
      ),
      child: Row(children: [
        Icon(isDistress ? Icons.warning : Icons.call,
          size: 14, color: isDistress ? Colors.redAccent : Colors.cyanAccent),
        const SizedBox(width: 8),
        Text('CH=${msg.callChannel}', style: TextStyle(fontSize: 11, fontFamily: 'monospace',
          color: cs.onSurface.withValues(alpha: 0.8))),
        const SizedBox(width: 8),
        Text(msg.aesId.isNotEmpty ? 'AES=${msg.aesId}' : '',
          style: TextStyle(fontSize: 11, fontFamily: 'monospace',
            color: cs.onSurface.withValues(alpha: 0.7))),
        const SizedBox(width: 8),
        Text(msg.callType, style: TextStyle(fontSize: 11,
          color: isDistress ? Colors.redAccent : Colors.cyanAccent)),
        if (msg.callRxFreq > 0) ...[
          const SizedBox(width: 8),
          Text('RX=${(msg.callRxFreq / 1e6).toStringAsFixed(4)}',
            style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.greenAccent)),
        ],
        const Spacer(),
        Text(msg.timestamp.toString().substring(11, 19),
          style: TextStyle(fontSize: 10, color: cs.onSurface.withValues(alpha: 0.4))),
      ]),
    );
  }
}
