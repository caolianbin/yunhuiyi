import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../models/models.dart';
import '../../../services/meeting_service.dart';
import '../../../state/room_controller.dart';
import '../../../widgets/common.dart';

// ============================================================
//  聊天面板
// ============================================================

class ChatPanel extends StatefulWidget {
  const ChatPanel({super.key, required this.controller, required this.selfUserId});

  final RoomController controller;
  final int selfUserId;

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    final n = widget.controller.messages.length;
    if (n != _lastCount) {
      _lastCount = n;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
    }
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  Future<void> _sendText() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await widget.controller.sendChat(text);
  }

  Future<void> _pick(String kind) async {
    setState(() => _sending = true);
    try {
      String? path;
      String? name;
      if (kind == 'image') {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 1600,
          imageQuality: 85,
        );
        path = picked?.path;
        name = picked?.name;
      } else {
        // ⚠️ file_picker 13 起 API 变更：
        //   旧：FilePicker.platform.pickFiles() → FilePickerResult?（取 .files.single）
        //   新：静态 FilePicker.pickFile()      → PlatformFile?（直接就是单个文件）
        //   写成旧 API 会报 “The getter 'platform' isn't defined for the type 'FilePicker'”。
        final picked = await FilePicker.pickFile();
        path = picked?.path;
        name = picked?.name;
      }
      if (path == null) return;

      final uploaded =
          await context.read<MeetingService>().uploadFile(File(path));
      await widget.controller.sendChat(
        name ?? uploaded.name,
        type: kind == 'image' ? 'image' : 'file',
        fileUrl: uploaded.url,
      );
    } catch (e) {
      if (mounted) showSnack(context, '发送失败：$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final msgs = widget.controller.messages;

    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('聊天', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        ),
        const Divider(height: 1),
        Expanded(
          child: msgs.isEmpty
              ? const EmptyView(text: '还没有消息\n说点什么吧', icon: Icons.chat_bubble_outline)
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) => _MessageBubble(
                    message: msgs[i],
                    isSelf: msgs[i].senderId == widget.selfUserId,
                    nickname: widget.controller.nicknameOf(msgs[i].senderId),
                  ),
                ),
        ),
        const Divider(height: 1),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                IconButton(
                  tooltip: '发送图片',
                  onPressed: _sending ? null : () => _pick('image'),
                  icon: const Icon(Icons.image_outlined),
                ),
                IconButton(
                  tooltip: '发送文件',
                  onPressed: _sending ? null : () => _pick('file'),
                  icon: const Icon(Icons.attach_file_rounded),
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: '输入消息…',
                      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                    onSubmitted: (_) => _sendText(),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  onPressed: _sending ? null : _sendText,
                  icon: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.send_rounded, size: 20),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isSelf,
    required this.nickname,
  });

  final ChatMessage message;
  final bool isSelf;
  final String nickname;

  @override
  Widget build(BuildContext context) {
    final time = message.sentAt == null ? '' : DateFormat('HH:mm').format(message.sentAt!);
    final isImage = message.type == 'image' && message.fileUrl != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isSelf ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isSelf) ...[
            Avatar(nickname: nickname, url: message.senderAvatar, size: 32),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isSelf ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Text(
                  '$nickname · $time',
                  style: const TextStyle(fontSize: 10.5, color: Color(0xFF8A9099)),
                ),
                const SizedBox(height: 3),
                Container(
                  padding: isImage
                      ? const EdgeInsets.all(3)
                      : const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: isSelf ? const Color(0xFF1A73E8) : Colors.white,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: isImage
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            message.fileUrl!,
                            width: 180,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Text(
                              '图片无法加载',
                              style: TextStyle(color: Color(0xFF8A9099), fontSize: 12),
                            ),
                          ),
                        )
                      : Text(
                          message.content,
                          style: TextStyle(
                            color: isSelf ? Colors.white : const Color(0xFF1B1D21),
                            fontSize: 14,
                            height: 1.45,
                          ),
                        ),
                ),
                if (message.type == 'file' && message.fileUrl != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: InkWell(
                      onTap: () async {
                        // 复制链接交给系统浏览器/其它应用打开，避免引入额外的下载权限
                        await Clipboard.setData(ClipboardData(text: message.fileUrl!));
                        if (context.mounted) showSnack(context, '文件链接已复制');
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.insert_drive_file_outlined,
                              size: 14, color: Color(0xFF1A73E8)),
                          const SizedBox(width: 4),
                          Text(
                            message.content.isEmpty ? '附件' : message.content,
                            style: const TextStyle(fontSize: 12, color: Color(0xFF1A73E8)),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (isSelf) ...[
            const SizedBox(width: 8),
            Avatar(nickname: nickname, url: message.senderAvatar, size: 32),
          ],
        ],
      ),
    );
  }
}

// ============================================================
//  成员面板
// ============================================================

class MemberPanel extends StatelessWidget {
  const MemberPanel({super.key, required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final me = controller.selfUserId;
    final isHost = controller.isHost;
    final list = controller.joinedParticipants;
    final waiting = controller.waitingList.values.toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('成员（${list.length}）',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              if (isHost && waiting.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: Text('等候室',
                      style: TextStyle(fontSize: 12, color: Color(0xFFE08A00),
                          fontWeight: FontWeight.w600)),
                ),
                for (final p in waiting)
                  ListTile(
                    leading: Avatar(nickname: p.nickname, url: p.avatar, size: 38),
                    title: Text(p.nickname),
                    subtitle: const Text('等待批准进入'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () => controller.hostDeny(p.userId),
                          child: const Text('拒绝'),
                        ),
                        FilledButton(
                          onPressed: () => controller.hostAdmit(p.userId),
                          child: const Text('准入'),
                        ),
                      ],
                    ),
                  ),
                const Divider(height: 20),
              ],
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Text('会议中',
                    style: TextStyle(fontSize: 12, color: Color(0xFF8A9099),
                        fontWeight: FontWeight.w600)),
              ),
              for (final p in list)
                ListTile(
                  leading: Avatar(nickname: p.nickname, url: p.avatar, size: 38),
                  title: Row(
                    children: [
                      Flexible(child: Text(p.nickname, overflow: TextOverflow.ellipsis)),
                      if (p.userId == me)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Text('(我)',
                              style: TextStyle(fontSize: 11, color: Color(0xFF8A9099))),
                        ),
                      if (p.isHost)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Icon(Icons.star_rounded, size: 14, color: Color(0xFFFFC53D)),
                        ),
                      if (p.raisedHand)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(Icons.front_hand, size: 13, color: Color(0xFFE08A00)),
                        ),
                    ],
                  ),
                  subtitle: Text([
                    p.role == 'cohost'
                        ? '联席主持人'
                        : p.role == 'viewer'
                            ? '观众'
                            : '',
                    if (p.isSharing) '共享中',
                    if (p.hardMuted) '已被静音',
                  ].where((e) => e.isNotEmpty).join(' · ')),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        p.micOn ? Icons.mic : Icons.mic_off,
                        size: 17,
                        color: p.micOn ? const Color(0xFF30A46C) : const Color(0xFFB9BEC7),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        p.cameraOn ? Icons.videocam : Icons.videocam_off,
                        size: 17,
                        color: p.cameraOn ? const Color(0xFF30A46C) : const Color(0xFFB9BEC7),
                      ),
                      if (isHost && p.userId != me)
                        IconButton(
                          icon: const Icon(Icons.more_vert, size: 18),
                          onPressed: () => _hostActions(context, p),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _hostActions(BuildContext context, Participant p) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(p.nickname,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(p.micOn ? Icons.mic_off : Icons.mic),
              title: Text(p.micOn ? '静音该成员' : '解除静音'),
              onTap: () {
                Navigator.pop(sheetCtx);
                controller.hostMute(p.userId, p.micOn);
              },
            ),
            ListTile(
              leading: const Icon(Icons.star_border_rounded),
              title: Text(p.role == 'cohost' ? '取消联席主持人' : '设为联席主持人'),
              onTap: () {
                Navigator.pop(sheetCtx);
                controller.hostSetRole(p.userId, p.role == 'cohost' ? 'participant' : 'cohost');
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_remove_outlined),
              title: const Text('移出会议'),
              textColor: const Color(0xFFE5484D),
              iconColor: const Color(0xFFE5484D),
              onTap: () {
                Navigator.pop(sheetCtx);
                controller.hostRemove(p.userId);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
//  更多面板
// ============================================================

class MorePanel extends StatelessWidget {
  const MorePanel({super.key, required this.controller, required this.selfUserId});

  final RoomController controller;
  final int selfUserId;

  @override
  Widget build(BuildContext context) {
    final isHost = controller.isHost;

    return SafeArea(
      top: false,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 10),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: Text('会议设置',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          ),
          SwitchListTile(
            value: controller.speakerOn,
            onChanged: (_) => controller.toggleSpeaker(),
            secondary: Icon(controller.speakerOn ? Icons.volume_up : Icons.volume_down),
            title: const Text('扬声器'),
            subtitle: Text(controller.speakerOn ? '当前使用扬声器（外放）' : '当前使用听筒'),
          ),
          if (isHost) ...[
            const Divider(height: 1),
            SwitchListTile(
              value: controller.isLocked,
              onChanged: (v) => controller.hostToggleLock(v),
              secondary: Icon(controller.isLocked ? Icons.lock : Icons.lock_open),
              title: const Text('锁定会议'),
              subtitle: const Text('锁定后新成员无法加入'),
            ),
            ListTile(
              leading: const Icon(Icons.mic_off_outlined),
              title: const Text('全体静音'),
              onTap: () => controller.hostMuteAll(true),
            ),
            ListTile(
              leading: const Icon(Icons.mic_outlined),
              title: const Text('取消全体静音'),
              onTap: () => controller.hostMuteAll(false),
            ),
            ListTile(
              leading: const Icon(Icons.how_to_vote_outlined),
              title: const Text('发起投票'),
              onTap: () => _createPoll(context),
            ),
            ListTile(
              leading: const Icon(Icons.stop_circle_outlined),
              title: const Text('结束会议'),
              textColor: const Color(0xFFE5484D),
              iconColor: const Color(0xFFE5484D),
              onTap: () => _confirmEnd(context),
            ),
          ],
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Text('发送表情',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 10,
              children: [
                for (final e in const ['👍', '👏', '🎉', '❤️', '😂', '😮', '🙏', '✅'])
                  InkWell(
                    onTap: () => controller.sendReaction(e),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F3F6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(e, style: const TextStyle(fontSize: 20)),
                    ),
                  ),
              ],
            ),
          ),
          if (controller.polls.isNotEmpty) ...[
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text('投票',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            ),
            for (final poll in controller.polls)
              _PollCard(controller: controller, poll: poll, isHost: isHost),
          ],
        ],
      ),
    );
  }

  Future<void> _createPoll(BuildContext context) async {
    final titleCtl = TextEditingController();
    final optionsCtl = TextEditingController(text: '同意\n不同意');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发起投票'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtl,
              decoration: const InputDecoration(labelText: '投票主题'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: optionsCtl,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '选项（每行一个）',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('发起')),
        ],
      ),
    );
    if (ok == true) {
      final title = titleCtl.text.trim();
      final options = optionsCtl.text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (title.isNotEmpty && options.length >= 2) {
        await controller.hostCreatePoll(title, options);
      }
    }
    titleCtl.dispose();
    optionsCtl.dispose();
  }

  Future<void> _confirmEnd(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('结束会议'),
        content: const Text('所有参会人都会被移出会议，确定结束吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('结束会议'),
          ),
        ],
      ),
    );
    if (ok == true) await controller.hostEndMeeting();
  }
}

class _PollCard extends StatelessWidget {
  const _PollCard({required this.controller, required this.poll, required this.isHost});

  final RoomController controller;
  final Poll poll;
  final bool isHost;

  @override
  Widget build(BuildContext context) {
    final total = poll.totalVotes;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(poll.title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  if (!poll.isOpen)
                    const Text('已结束',
                        style: TextStyle(fontSize: 11, color: Color(0xFF8A9099))),
                ],
              ),
              const SizedBox(height: 10),
              for (var i = 0; i < poll.options.length; i++) ...[
                InkWell(
                  onTap: poll.isOpen && !poll.voted
                      ? () => controller.votePoll(poll.id, i)
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text(poll.options[i])),
                            Text(
                              '${poll.countFor(i)} 票',
                              style: const TextStyle(fontSize: 12, color: Color(0xFF8A9099)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: total == 0 ? 0 : poll.countFor(i) / total,
                          minHeight: 5,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (poll.voted)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('你已投票', style: TextStyle(fontSize: 11, color: Color(0xFF8A9099))),
                ),
              if (isHost && poll.isOpen)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => controller.hostClosePoll(poll.id),
                    child: const Text('结束投票'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
