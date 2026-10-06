import 'package:flutter/material.dart';

/// 会议底部控制栏。
class ControlBar extends StatelessWidget {
  const ControlBar({
    super.key,
    required this.micOn,
    required this.cameraOn,
    required this.isSharing,
    required this.hardMuted,
    required this.handRaised,
    required this.memberCount,
    required this.unreadCount,
    required this.onToggleMic,
    required this.onToggleCamera,
    required this.onSwitchCamera,
    required this.onToggleShare,
    required this.onToggleHand,
    required this.onOpenChat,
    required this.onOpenMembers,
    required this.onOpenMore,
    required this.onLeave,
    this.sharePending = false,
    this.shareEnabled = true,
  });

  final bool micOn;
  final bool cameraOn;
  final bool isSharing;
  final bool hardMuted;
  final bool handRaised;
  final int memberCount;
  final int unreadCount;
  final bool shareEnabled;

  /// 已请求共享，正在等用户在系统弹窗上确认（点「开始录制」/「开始直播」）。
  /// 这个中间态必须显示出来，否则用户会觉得"点了没反应"而反复点击。
  final bool sharePending;

  final VoidCallback onToggleMic;
  final VoidCallback onToggleCamera;
  final VoidCallback onSwitchCamera;
  final VoidCallback onToggleShare;
  final VoidCallback onToggleHand;
  final VoidCallback onOpenChat;
  final VoidCallback onOpenMembers;
  final VoidCallback onOpenMore;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF16171A),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _Btn(
              icon: micOn ? Icons.mic : Icons.mic_off,
              label: hardMuted ? '被静音' : (micOn ? '静音' : '开麦'),
              active: !micOn,
              danger: hardMuted,
              onTap: onToggleMic,
            ),
            _Btn(
              icon: cameraOn ? Icons.videocam : Icons.videocam_off,
              label: cameraOn ? '关视频' : '开视频',
              active: !cameraOn,
              onTap: onToggleCamera,
            ),
            if (cameraOn)
              _Btn(
                icon: Icons.cameraswitch_rounded,
                label: '翻转',
                onTap: onSwitchCamera,
              ),
            _Btn(
              icon: Icons.screen_share_rounded,
              // 三态：共享中 / 等待用户在系统弹窗确认 / 未共享
              label: isSharing
                  ? '停止共享'
                  : (sharePending ? '等待确认…' : '共享'),
              active: sharePending,
              highlight: isSharing,
              onTap: shareEnabled ? onToggleShare : null,
            ),
            _Btn(
              icon: handRaised ? Icons.front_hand : Icons.pan_tool_outlined,
              label: handRaised ? '放下' : '举手',
              highlight: handRaised,
              onTap: onToggleHand,
            ),
            _Btn(
              icon: Icons.chat_bubble_outline_rounded,
              label: '聊天',
              badge: unreadCount,
              onTap: onOpenChat,
            ),
            _Btn(
              icon: Icons.people_outline_rounded,
              label: '成员',
              badge: memberCount,
              onTap: onOpenMembers,
            ),
            _Btn(
              icon: Icons.more_horiz_rounded,
              label: '更多',
              onTap: onOpenMore,
            ),
            _Btn(
              icon: Icons.call_end_rounded,
              label: '离开',
              danger: true,
              filledDanger: true,
              onTap: onLeave,
            ),
          ],
        ),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.danger = false,
    this.highlight = false,
    this.filledDanger = false,
    this.badge = 0,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final bool danger;
  final bool highlight;
  final bool filledDanger;
  final int badge;

  @override
  Widget build(BuildContext context) {
    Color bg = const Color(0xFF2A2C31);
    Color fg = Colors.white;
    if (filledDanger) {
      bg = const Color(0xFFE5484D);
    } else if (highlight) {
      bg = const Color(0xFF1A73E8);
    } else if (active) {
      bg = const Color(0x33FFFFFF);
    } else if (danger) {
      fg = const Color(0xFFFF6B6B);
    }

    final enabled = onTap != null;

    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                    child: Icon(icon, color: fg, size: 20),
                  ),
                  if (badge > 0)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        constraints: const BoxConstraints(minWidth: 16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE5484D),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          badge > 99 ? '99+' : '$badge',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(color: Color(0xFFC9CDD4), fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
