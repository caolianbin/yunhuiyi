import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/app_theme.dart';

void showSnack(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
}) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      // 带操作按钮的提示留久一点，否则用户还没看清就消失了
      duration: Duration(seconds: actionLabel == null ? 4 : 8),
      action: actionLabel == null
          ? null
          : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
    ));
}

/// 头像：有图用图，没图用昵称首字取色块。
/// 移动端经常出现"头像 URL 指向 127.0.0.1"（后端用 Request.Host 拼的），
/// 加载失败时要优雅降级，不能让整个列表变成一排红叉。
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.nickname,
    this.url,
    this.size = 40,
    this.textColor = Colors.white,
  });

  final String nickname;
  final String? url;
  final double size;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    // 取首字符做占位（用 substring 而非 characters，避免依赖额外的包）
    final initial = nickname.isEmpty ? '?' : nickname.substring(0, 1);
    final bg = _colorFor(nickname);

    Widget fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(
        initial,
        style: TextStyle(
          color: textColor,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    final src = url;
    if (src == null || src.isEmpty) return fallback;

    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: src,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      ),
    );
  }

  static Color _colorFor(String seed) {
    const palette = [
      Color(0xFF1A73E8),
      Color(0xFF30A46C),
      Color(0xFF9A5CFF),
      Color(0xFFE5484D),
      Color(0xFFE08A00),
      Color(0xFF0E9BB8),
    ];
    if (seed.isEmpty) return palette.first;
    var h = 0;
    for (final unit in seed.codeUnits) {
      h = (h * 31 + unit) & 0x7fffffff;
    }
    return palette[h % palette.length];
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.text, this.icon = Icons.inbox_outlined, this.action});

  final String text;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: const Color(0xFFB9BEC7)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF8A9099), fontSize: 14),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 52, color: AppTheme.danger),
            const SizedBox(height: 14),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              OutlinedButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}

/// 会议状态徽标
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    late Color color;
    late String text;
    switch (status) {
      case 'ongoing':
        color = AppTheme.success;
        text = '进行中';
        break;
      case 'ended':
        color = const Color(0xFF8A9099);
        text = '已结束';
        break;
      default:
        color = AppTheme.brand;
        text = '待开始';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}
