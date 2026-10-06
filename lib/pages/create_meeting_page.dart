import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../services/meeting_service.dart';

/// 创建会议。[mode] 为 instant（即时）或 scheduled（预约）。
class CreateMeetingPage extends StatefulWidget {
  const CreateMeetingPage({super.key, this.mode = 'instant'});

  final String mode;

  @override
  State<CreateMeetingPage> createState() => _CreateMeetingPageState();
}

class _CreateMeetingPageState extends State<CreateMeetingPage> {
  final _formKey = GlobalKey<FormState>();
  final _subject = TextEditingController();
  final _description = TextEditingController();
  final _password = TextEditingController();

  bool get _isInstant => widget.mode == 'instant';

  int _duration = 60;
  bool _waitingRoom = false;
  bool _watermark = false;
  bool _usePmi = false;
  String? _recurrence;
  DateTime _startTime = DateTime.now().add(const Duration(minutes: 30));

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _subject.dispose();
    _description.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _pickStartTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _startTime,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startTime),
    );
    if (time == null) return;
    setState(() {
      _startTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final meeting = await context.read<MeetingService>().create(
            subject: _subject.text.trim(),
            mode: widget.mode,
            description: _description.text.trim(),
            startTime: _isInstant ? null : _startTime,
            durationMinutes: _duration,
            password: _password.text.trim(),
            waitingRoomEnabled: _waitingRoom,
            watermarkEnabled: _watermark,
            recurrence: _recurrence,
            usePmi: _usePmi,
          );
      if (!mounted) return;
      Navigator.pop(context, meeting);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '创建失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isInstant ? '发起会议' : '预约会议')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _subject,
                decoration: const InputDecoration(
                  labelText: '会议主题 *',
                  hintText: '例如：产品评审会',
                ),
                maxLength: 60,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '请填写会议主题' : null,
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _description,
                decoration: const InputDecoration(labelText: '会议说明'),
                maxLines: 2,
              ),
              const SizedBox(height: 14),
              if (!_isInstant) ...[
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.schedule),
                    title: const Text('开始时间'),
                    subtitle: Text(DateFormat('yyyy-MM-dd HH:mm').format(_startTime)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _pickStartTime,
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.timelapse),
                    title: const Text('时长（分钟）'),
                    trailing: DropdownButton<int>(
                      value: _duration,
                      underline: const SizedBox.shrink(),
                      items: const [15, 30, 45, 60, 90, 120, 180, 240]
                          .map((e) => DropdownMenuItem(value: e, child: Text('$e')))
                          .toList(),
                      onChanged: (v) => setState(() => _duration = v ?? 60),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.repeat),
                    title: const Text('重复'),
                    trailing: DropdownButton<String>(
                      value: _recurrence ?? '',
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: '', child: Text('不重复')),
                        DropdownMenuItem(value: 'daily', child: Text('每天')),
                        DropdownMenuItem(value: 'weekly', child: Text('每周')),
                        DropdownMenuItem(value: 'monthly', child: Text('每月')),
                      ],
                      onChanged: (v) =>
                          setState(() => _recurrence = (v == null || v.isEmpty) ? null : v),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              TextFormField(
                controller: _password,
                decoration: const InputDecoration(
                  labelText: '入会密码',
                  helperText: '留空表示无需密码',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      value: _waitingRoom,
                      onChanged: (v) => setState(() => _waitingRoom = v),
                      title: const Text('开启等候室'),
                      subtitle: const Text('参会人需主持人批准后才能进入'),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: _usePmi,
                      onChanged: (v) => setState(() => _usePmi = v),
                      title: const Text('使用个人会议号（PMI）'),
                      subtitle: const Text('固定会议号，方便他人随时呼入'),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: _watermark,
                      onChanged: (v) => setState(() => _watermark = v),
                      title: const Text('显示水印'),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Text(_error!, style: const TextStyle(color: Color(0xFFB3261E), fontSize: 13)),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Text(_isInstant ? '创建并进入' : '创建预约'),
              ),
              const SizedBox(height: 12),
              Text(
                _isInstant
                    ? '即时会议创建后会自动进入，并把主持人加入为第一个参会人。'
                    : '预约会议需要点击「开始」后才进入进行中状态。',
                style: const TextStyle(fontSize: 12, color: Color(0xFF8A9099), height: 1.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
