import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/session.dart';
import '../services/auth_service.dart';
import '../widgets/common.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _busy = false;

  Future<void> _editField({
    required String title,
    required String initial,
    required String label,
    bool allowEmpty = true,
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    if (!allowEmpty && value.isEmpty) {
      if (mounted) showSnack(context, '$label 不能为空');
      return;
    }
    await _save(
      nickname: title == '修改昵称' ? value : null,
      department: title == '修改部门' ? value : null,
      email: title == '修改邮箱' ? value : null,
    );
  }

  Future<void> _save({String? nickname, String? department, String? email}) async {
    if (nickname == null && department == null && email == null) return;
    setState(() => _busy = true);
    try {
      final user = await context
          .read<AuthService>()
          .updateProfile(nickname: nickname, department: department, email: email);
      await context.read<Session>().updateUser(user);
      if (mounted) showSnack(context, '已保存');
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    } catch (e) {
      if (mounted) showSnack(context, '保存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeAvatar() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    setState(() => _busy = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (picked == null) return;
      final url = await context.read<AuthService>().uploadAvatar(File(picked.path));
      final session = context.read<Session>();
      if (url != null && session.user != null) {
        await session.updateUser(session.user!.copyWith(avatar: url));
      }
      if (mounted) showSnack(context, '头像已更新');
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    } catch (e) {
      if (mounted) showSnack(context, '上传失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeServer() async {
    final session = context.read<Session>();
    final controller = TextEditingController(text: session.baseUrl);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('服务器地址'),
        content: TextField(controller: controller, keyboardType: TextInputType.url),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok == true) {
      await session.setBaseUrl(controller.text);
      if (mounted) showSnack(context, '已切换到 ${session.baseUrl}');
    }
    controller.dispose();
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后需要重新输入账号密码。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('退出')),
        ],
      ),
    );
    if (ok != true) return;
    await context.read<Session>().clearAuth();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<Session>().user;
    final baseUrl = context.watch<Session>().baseUrl;

    return Scaffold(
      appBar: AppBar(title: const Text('个人中心')),
      body: user == null
          ? const EmptyView(text: '未登录')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        Stack(
                          children: [
                            Avatar(nickname: user.nickname, url: user.avatar, size: 84),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: InkWell(
                                onTap: _busy ? null : _changeAvatar,
                                child: Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2),
                                  ),
                                  child: const Icon(Icons.camera_alt,
                                      size: 13, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          user.nickname,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text('@${user.username}',
                            style: const TextStyle(color: Color(0xFF8A9099), fontSize: 13)),
                        if (user.isAdmin)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Chip(
                              label: Text('管理员', style: TextStyle(fontSize: 11)),
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.badge_outlined),
                        title: const Text('昵称'),
                        subtitle: Text(user.nickname),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _editField(
                          title: '修改昵称',
                          initial: user.nickname,
                          label: '昵称',
                          allowEmpty: false,
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.apartment_outlined),
                        title: const Text('部门'),
                        subtitle: Text(user.department ?? '未设置'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _editField(
                          title: '修改部门',
                          initial: user.department ?? '',
                          label: '部门',
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.mail_outline),
                        title: const Text('邮箱'),
                        subtitle: Text(user.email ?? '未设置'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _editField(
                          title: '修改邮箱',
                          initial: user.email ?? '',
                          label: '邮箱',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.pin_outlined),
                    title: const Text('个人会议号（PMI）'),
                    subtitle: Text(user.pmi.isEmpty ? '—' : user.pmi),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: user.pmi));
                        showSnack(context, 'PMI 已复制');
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: const Text('服务器地址'),
                    subtitle: Text(baseUrl, style: const TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _changeServer,
                  ),
                ),
                const SizedBox(height: 14),
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '关于 iOS 屏幕共享\n\n'
                      'iOS 上共享手机屏幕需要系统级「屏幕录制」能力，'
                      '必须在 Xcode 中为工程添加 Broadcast Upload Extension（ReplayKit 扩展），'
                      '并让主 App 与扩展共用同一个 App Group。\n\n'
                      '当前 App Group：${AppConfig.iosAppGroup}',
                      style: TextStyle(fontSize: 12, height: 1.7, color: Color(0xFF6B7280)),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _logout,
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('退出登录'),
                  style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFE5484D)),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
