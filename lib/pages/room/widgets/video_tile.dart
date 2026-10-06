import 'package:flutter/material.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_video_view.dart';

import '../../../models/models.dart';
import '../../../widgets/common.dart';

/// 一个视频方块。
///
/// ⚠️ [userId] 必须是 **TRTC 的 userId**（字符串），与 [Participant.userId]（数字）不是同一个东西。
/// 两者当前取值相同（都是后端数字 id），但类型不能混用。
class VideoTile extends StatelessWidget {
  const VideoTile({
    super.key,
    required this.userId,
    required this.nickname,
    required this.isLocal,
    required this.videoOn,
    required this.micOn,
    this.speaking = false,
    this.isSharing = false,
    this.isHost = false,
    this.avatar,
    this.onViewCreated,
    this.onTap,
    this.compact = false,
  });

  final String userId;
  final String nickname;
  final bool isLocal;
  final bool videoOn;
  final bool micOn;
  final bool speaking;
  final bool isSharing;
  final bool isHost;
  final String? avatar;
  final void Function(int viewId)? onViewCreated;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF26282D),
          borderRadius: BorderRadius.circular(12),
          border: speaking ? Border.all(color: const Color(0xFF30A46C), width: 2) : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (videoOn)
              _video()
            else
              _placeholder(),
            // 左上角：共享标记
            if (isSharing)
              Positioned(
                left: 6,
                top: 6,
                child: _badge(
                  icon: Icons.cast_connected_rounded,
                  text: '共享中',
                  color: const Color(0xFF1A73E8),
                ),
              ),
            // 底部：昵称 + 麦克风状态
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: compact ? 3 : 6),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xCC000000), Color(0x00000000)],
                  ),
                ),
                child: Row(
                  children: [
                    if (isHost && !compact) ...[
                      const Icon(Icons.star_rounded, size: 12, color: Color(0xFFFFC53D)),
                      const SizedBox(width: 3),
                    ],
                    Expanded(
                      child: Text(
                        isLocal ? '$nickname（我）' : nickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: compact ? 10 : 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      micOn ? Icons.mic : Icons.mic_off,
                      size: compact ? 11 : 13,
                      color: micOn ? Colors.white : const Color(0xFFFF6B6B),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _video() {
    // 新 SDK 的 TRTCCloudVideoView 只有 key 和 onViewCreated 两个参数
    // （hitTestBehavior 由它内部固定为 transparent，不需要也不允许外部再传）。
    return TRTCCloudVideoView(
      // key 必须稳定：一旦 key 变化，Flutter 会销毁并重建原生视图，
      // 重建后 viewId 失效，画面会突然变黑。
      key: ValueKey('$userId-${isLocal ? 'l' : 'r'}-${streamTypeForTile.name}'),
      onViewCreated: (viewId) {
        onViewCreated?.call(viewId);
      },
    );
  }

  /// 本地与远端都用主路（big）；共享画面由舞台单独渲染辅路。
  TRTCVideoStreamType get streamTypeForTile => TRTCVideoStreamType.big;

  Widget _placeholder() {
    return Container(
      color: const Color(0xFF2E3036),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Avatar(nickname: nickname, url: avatar, size: compact ? 30 : 46),
          if (!compact) ...[
            const SizedBox(height: 8),
            const Text(
              '摄像头已关闭',
              style: TextStyle(color: Color(0xFF9AA0A9), fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _badge({required IconData icon, required String text, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: Colors.white),
          const SizedBox(width: 3),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 10)),
        ],
      ),
    );
  }
}

/// 从会议成员里取出"需要显示成方块"的列表（不含等候室成员）。
List<Participant> visibleParticipants(List<Participant> all, int selfUserId) {
  return all.where((p) => !p.inWaitingRoom).toList();
}
