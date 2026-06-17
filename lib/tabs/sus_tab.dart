import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/aero_provider.dart';
import '../services/aero_service.dart';

class SUsTab extends StatelessWidget {
  const SUsTab({super.key});

  static const List<String> _pchanTypes = [
    'T_ASSIGN', 'C_ASSIGN_D', 'C_ASSIGN_F', 'C_ASSIGN_S', 'C_ASSIGN_N',
    'ACK', 'ISU_DATA', 'ISU_LSDU3', 'ISU_LSDU4',
    'SAT_ID', 'SAT_BRD', 'SAT_IDX', 'SAT_BEAM',
    'LOGON_REQ', 'LOGON_CFM', 'LOGOFF', 'LOGON_REJ', 'LOGON_INT',
    'LOGON_ACK', 'LOGON_PROMPT',
    'CALL_ANNC', 'CALLPROG', 'EIRP_TBL',
    'P_R_CTRL', 'T_CTRL', 'RQA', 'REASSIGN',
    'FILL', 'UNK',
  ];

  @override
  Widget build(BuildContext context) {
    final aero = context.watch<AeroProvider>();
    final msgs = aero.messages.where((m) => _isPchan(m)).toList();
    final cs = Theme.of(context).colorScheme;

    return Column(children: [
      _buildHeader(context, msgs.length),
      const Divider(height: 1),
      Expanded(child: ListView.builder(
        itemCount: msgs.length,
        itemBuilder: (ctx, i) => _buildSuCard(msgs[i], cs),
      )),
    ]);
  }

  bool _isPchan(AeroMessage m) {
    if (m.suType == 'VASSIGN' || m.suType == 'PCHAN') return true;
    if (m.hexBytes.startsWith('P ')) return true;
    if (m.hexBytes.startsWith('CALLPROG')) return true;
    if (m.hexBytes.startsWith('SAT_')) return true;
    return false;
  }

  Widget _buildHeader(BuildContext context, int count) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: cs.surfaceContainerHighest,
      child: Row(children: [
        const Icon(Icons.settings_input_antenna, size: 18),
        const SizedBox(width: 8),
        Text('P-Channel SUs', style: TextStyle(
          fontWeight: FontWeight.w600, fontSize: 13, color: cs.onSurface)),
        const Spacer(),
        Text('$count', style: TextStyle(
          fontSize: 12, color: cs.onSurface.withValues(alpha: 0.6))),
      ]),
    );
  }

  Widget _buildSuCard(AeroMessage msg, ColorScheme cs) {
    Color bg;
    if (msg.suType == 'VASSIGN') {
      bg = Colors.purple.shade900.withValues(alpha: 0.3);
    } else {
      bg = cs.surface.withValues(alpha: 0.0);
    }

    final typeLabel = msg.callType.isNotEmpty ? msg.callType : msg.suType;
    final isAssign = typeLabel.startsWith('C_ASSIGN') || typeLabel == 'T_ASSIGN';
    final isSat = typeLabel == 'SAT_ID' || typeLabel == 'SAT_BRD';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        border: Border(bottom: BorderSide(
          color: cs.outlineVariant.withValues(alpha: 0.3), width: 0.5)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 80,
          child: Text(typeLabel, style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600,
            color: isAssign ? Colors.purpleAccent
                : isSat ? Colors.orangeAccent
                : Colors.blueAccent)),
        ),
        if (msg.aesId.isNotEmpty) ...[
          const SizedBox(width: 8),
          Text('AES=${msg.aesId}', style: TextStyle(
            fontSize: 11, color: cs.onSurface.withValues(alpha: 0.8),
            fontFamily: 'monospace')),
        ],
        if (msg.gesId > 0) ...[
          const SizedBox(width: 8),
          Text('GES=${msg.gesId}', style: TextStyle(
            fontSize: 11, color: cs.onSurface.withValues(alpha: 0.7),
            fontFamily: 'monospace')),
        ],
        if (isAssign && msg.callRxFreq > 0) ...[
          const SizedBox(width: 8),
          Text('RX=${(msg.callRxFreq / 1e6).toStringAsFixed(4)}',
            style: TextStyle(fontSize: 11, color: Colors.greenAccent, fontFamily: 'monospace')),
          const SizedBox(width: 4),
          Text('TX=${(msg.callTxFreq / 1e6).toStringAsFixed(4)}',
            style: TextStyle(fontSize: 11, color: Colors.orangeAccent, fontFamily: 'monospace')),
        ],
        const Spacer(),
        Text(msg.timestamp.toString().substring(11, 19),
          style: TextStyle(fontSize: 10, color: cs.onSurface.withValues(alpha: 0.4))),
      ]),
    );
  }
}
