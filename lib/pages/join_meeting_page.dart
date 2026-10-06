import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../models/models.dart';
import '../services/meeting_service.dart';
import '../widgets/common.dart';
import 'room/room_page.dart';

/// 加入会议：支持会议号 / 邀请码 / 整条邀请链接。
class JoinMeetingPage extends StatefulWidget {
  const JoinMeetingPage({super.key, this.initialNo});

  final String? initialNo;

  @override
  State<JoinMeetingPage> createState() => _JoinMeetingPageState();
}

class _JoinMeetingPageState extends State<JoinMeetingPage> {
  late final TextEditingController _no = TextEditingController(text: widget.initialNo ?? '');
  final _password = TextEditingController();

  Meeting? _preview;
  String? _error;
  bool _looking = false;

  @override
  void dispose() {
    _no.dispose();
    _password.dispose();
    super.dispose();
  }

  /// 从"邀请链接"里抠出会议号。
  /// 与后端 MeetingsController.Join 的解析规则保持一致，避免两端行为不同。
  String _extractNo(String raw) {
    var s = raw.trim();
    final idx = s.toLowerCase().indexOf('no=');
    if (idx >= 0) {
      var rest = s.substring(idx + 3);
      final end = rest.indexOf(RegExp(r'[&#? ]'));
      if (end > 0) rest = rest.substring(0, end);
      s = rest;
    }
    return s;
  }

  Future<void> _lookup() async {
    final no = _extractNo(_no.text);
    if (no.isEmpty) {
      setState(() => _error = '请输入会议号');
      return;
    }
    setState(() {
      _looking = true;
      _error = null;
      _preview = null;
    });
    try {
      final m = await context.read<MeetingService>().getByNo(no);
      if (mounted) setState(() => _preview = m);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '查询失败：$e');
    } finally {
      if (mounted) setState(() => _looking = false);
    }
  }

  Future<void> _enter(Meeting m) async {
    // 直接把密码交给会议页：RoomController 会先走 REST 校验，
    // 密码不对时页面会给出可重试的提示，而不是在这里提前失败。
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RoomPage(
          meetingId: m.id,
          password: _password.text.trim().isEmpty ? null : _password.text.trim(),
        ),
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('加入会议')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _no,
              maxLines: 1,
              decoration: const InputDecoration(
                labelText: '会议号 / 邀请码 / 邀请链接',
                hintText: '9 位会议号，或整条邀请链接',
                prefixIcon: Icon(Icons.tag),
              ),
              onSubmitted: (_) => _lookup(),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _password,
              decoration: const InputDecoration(
                labelText: '会议密码',
                helperText: '仅在会议设置了密码时需要',
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(_error!, style: const TextStyle(color: Color(0xFFB3261E), fontSize: 13)),
            ],
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: _looking ? null : _lookup,
              child: _looking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('查询会议'),
            ),
            if (_preview != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _preview!.subject,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                          ),
                          StatusChip(status: _preview!.status),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text('会议号：${_preview!.meetingNo}', style: const TextStyle(fontSize: 13)),
                      Text('主持人：${_preview!.hostName ?? '—'}',
                          style: const TextStyle(fontSize: 13)),
                      if (_preview!.waitingRoomEnabled)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            '该会议开启了等候室，进入后需要主持人批准',
                            style: TextStyle(fontSize: 12, color: Color(0xFFE08A00)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _preview!.isEnded ? null : () => _enter(_preview!),
                child: Text(_preview!.isEnded ? '会议已结束' : '进入会议'),
              ),
            ],
            const SizedBox(height: 24),
            const Text(
              '提示：把别人发来的邀请链接整条粘贴到上面的输入框也可以直接进会。',
              style: TextStyle(fontSize: 12, color: Color(0xFF8A9099), height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}
