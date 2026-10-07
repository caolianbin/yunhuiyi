#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
在 ios/Runner.xcodeproj 里创建 Broadcast Upload Extension Target。

━━━━━━━━━━━━━━ 为什么这件事非做不可 ━━━━━━━━━━━━━━

iOS 的系统级屏幕共享（能录到**别的 App** 的画面）不是主 App 自己采集的：
系统会另外拉起一个独立的 **Broadcast Upload Extension 进程**去采集整块屏幕，
再用 App Group 这个跨进程共享容器把画面交给主 App 推流。

这个扩展必须以「独立 Target」的形式存在于 Runner.xcodeproj 里。
只放一份 SampleHandler.swift 源码是**没用**的 —— 它不会被编译，也不会
出现在系统「屏幕录制」的来源列表里。

缺了它的现象极具误导性：点「共享屏幕」之后**什么都不发生，日志里一个错都没有**。

━━━━━━━━━━━━━━ 为什么用脚本而不是让人在 Xcode 里点 ━━━━━━━━━━━━━━

因为本项目是纯 CI 构建（Codemagic），没有 Mac。
Xcode 的「File > New > Target」本质上也就是往 project.pbxproj 里写对象，
所以完全可以程序化完成。

━━━━━━━━━━━━━━ 怎么保证不把工程改坏 ━━━━━━━━━━━━━━

project.pbxproj 是 Xcode 的工程文件，格式敏感，改错会让 Xcode 直接打不开。
这里刻意**不用「正则全文替换」**那种脆做法，而是：

  1. 新增对象：只在各 section 的 `/* End xxx section */` 之前插入完整对象块；
  2. 修改已有对象：先用 object_block() 精确切出**那一个**对象的文本，
     再在块内替换 —— 避免误伤 RunnerTests 等结构相同的邻居；
  3. 写完立刻 verify()：重新解析并逐项断言（target / 编译阶段 / 构建设置 /
     嵌入关系），任何一项不对就**不落盘**（宁可不改，也不能留下半个坏工程）。

幂等：已存在 app-extension target 时直接跳过，可以反复执行。
"""

from __future__ import annotations

import argparse
import hashlib
import io
import os
import re
import sys

# ---------------------------------------------------------------- 常量

EXT_NAME = 'BroadcastExtension'
SWIFT_FILE = 'SampleHandler.swift'
PLIST_FILE = 'Info.plist'
ENT_FILE = 'BroadcastExtension.entitlements'

TAB = '\t'
PRODUCT_TYPE_APP_EXT = 'com.apple.product-type.app-extension'
PRODUCT_TYPE_APP = 'com.apple.product-type.application'

#: 扩展本体的包装类型（.appex）
FILE_TYPE_APPEX = 'wrapper.app-extension'

#: 把 .appex 拷进主 App 的位置：13 = PlugIns。
#: 写成 10（Frameworks）之类会构建失败，而且报错与真正的原因没什么关系。
DST_PLUGINS = 13


def log(msg):
    print(msg)


def die(msg):
    sys.stderr.write('!! %s\n' % msg)
    sys.exit(1)


def read(path):
    try:
        with io.open(path, encoding='utf-8') as f:
            return f.read()
    except (IOError, OSError):
        return None


def write(path, text):
    with io.open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def L(depth, text=''):
    """按 pbxproj 的层级缩进一行并补换行。

    层级约定：对象本体 2 个 tab、属性 3 个、数组元素 4 个、buildSettings 里的键 4 个。
    这样写比手搓一大段 `%s%s%s` 模板可靠得多 —— 参数一多就必然数错。
    """
    return '%s%s\n' % (TAB * depth, text)


# ---------------------------------------------------------------- pbxproj 基本操作


def make_uuid_gen(text):
    """生成 24 位十六进制 UUID，并保证不与工程里已有的冲突。

    故意做成**确定性**的（md5 派生）而不是随机数：
    同样的工程每次跑出来的 ID 都一样，diff 干净，也便于复现问题。
    """
    taken = set(re.findall(r'[0-9A-F]{24}', text))

    def gen(seed):
        i = 0
        while True:
            h = hashlib.md5(('%s#%d' % (seed, i)).encode('utf-8')).hexdigest()[:24].upper()
            if h not in taken:
                taken.add(h)
                return h
            i += 1

    return gen


def object_block(text, uuid):
    """切出某一个 object 的完整文本块（从行首到它的 `};` 为止）。

    这是本脚本的安全底线：所有对已有对象的修改都只在这个块内进行。

    ⚠️ 必须用 `^` 锚定行首。否则 `\\t\\t<uuid>` 会命中**别的对象里对它的引用行** ——
    比如 Products 分组的 UUID 也出现在 mainGroup 的 children 里
    （`\\t\\t\\t\\t97C146EF... /* Products */,`，其后缀正是 `\\t\\t<uuid>`），
    于是切出来的会是引用行而不是定义块，后续所有替换都会作用在错误的位置。
    """
    m = re.search('^%s%s' % (TAB + TAB, re.escape(uuid)), text, re.M)
    if not m:
        return None
    i = m.start()
    end = '\n' + TAB + TAB + '};'
    j = text.find(end, i)
    if j < 0:
        return None
    return text[i:j + len(end)]


def insert_object(text, section, block):
    """把 object 块插到 `/* End <section> section */` 之前。

    section 不存在时（例如工程里没有 RunnerTests，导致 PBXContainerItemProxy /
    PBXTargetDependency 两个 section 缺失），就在 PBXProject section 前新建一个 ——
    Xcode 解析的是 plist 字典，对 section 的先后顺序并不敏感。
    """
    marker = '/* End %s section */' % section
    i = text.find(marker)
    if i >= 0:
        return text[:i] + block + text[i:]

    anchor = '/* Begin PBXProject section */'
    j = text.find(anchor)
    if j < 0:
        die('pbxproj 结构异常：既没有 %s，也没有 PBXProject section' % marker)
    log('  · 新建 section：%s' % section)
    return (text[:j]
            + '/* Begin %s section */\n' % section
            + block
            + '/* End %s section */\n\n' % section
            + text[j:])


def get_setting(block, key):
    """从某个对象的文本块里读一条 build setting。"""
    m = re.search(r'^[ \t]*%s = (.+?);$' % re.escape(key), block, re.M)
    return m.group(1).strip() if m else None


def find_uuid_by_line(text, pattern):
    m = re.search(pattern, text, re.M)
    return m.group(1) if m else None


def find_app_target(text):
    """找主 App target：productType 是 application 的那个。"""
    for m in re.finditer(
            '^%s([0-9A-F]{24}) /\\* (.+?) \\*/ = \\{\n%sisa = PBXNativeTarget;'
            % (TAB + TAB, TAB * 3), text, re.M):
        uuid = m.group(1)
        block = object_block(text, uuid)
        if block and PRODUCT_TYPE_APP in block:
            return uuid, m.group(2), block
    return None, None, None


def target_bundle_id(text, target_block):
    """顺着 target → buildConfigurationList → XCBuildConfiguration 读出 bundle id。"""
    m = re.search(r'buildConfigurationList = ([0-9A-F]{24})', target_block)
    if not m:
        return None
    cl = object_block(text, m.group(1))
    if not cl or 'buildConfigurations = (' not in cl:
        return None
    body = cl.split('buildConfigurations = (', 1)[1].split(');', 1)[0]
    for cfg_id in re.findall(r'([0-9A-F]{24})', body):
        cfg = object_block(text, cfg_id)
        if not cfg:
            continue
        value = get_setting(cfg, 'PRODUCT_BUNDLE_IDENTIFIER')
        if value:
            return value
    return None


def insert_into_list(block, list_key, line, before_comment=None):
    """在对象的某个数组属性里追加一行；before_comment 命中时插到它前面。"""
    m = re.search(r'(\t{3}%s = \(\n)((?:[^\n]*\n)*?)(\t{3}\);)'
                  % re.escape(list_key), block)
    if not m:
        return None
    items = m.group(2)
    if before_comment and before_comment in items:
        idx = items.find(before_comment)
        line_start = items.rfind('\n', 0, idx) + 1
        items = items[:line_start] + line + items[line_start:]
    else:
        items = items + line
    return block[:m.start(2)] + items + block[m.end(2):]


# ---------------------------------------------------------------- 生成对象块


#: 扩展的构建设置。键是设置名，值是 (Debug, Release, Profile) 三元组；
#: 三份都一样的写单个字符串。全部按字母序输出，与 Xcode 的习惯一致。
BUILD_SETTINGS = [
    ('APPLICATION_EXTENSION_API_ONLY', 'YES'),
    ('CODE_SIGN_ENTITLEMENTS', '@EXT@/@ENT@'),
    ('CODE_SIGN_STYLE', 'Automatic'),
    ('CURRENT_PROJECT_VERSION', '1'),
    ('DEBUG_INFORMATION_FORMAT', ('dwarf', '"dwarf-with-dsym"', '"dwarf-with-dsym"')),
    ('ENABLE_NS_ASSERTIONS', ('', 'NO', 'NO')),   # Debug 下默认就是 YES，不用显式写
    ('ENABLE_TESTABILITY', ('YES', 'NO', 'NO')),
    ('GENERATE_INFOPLIST_FILE', 'NO'),   # 必须：我们自带 Info.plist，否则会打架
    ('GCC_OPTIMIZATION_LEVEL', ('0', 's', 's')),
    ('INFOPLIST_FILE', '@EXT@/@PLIST@'),
    ('IPHONEOS_DEPLOYMENT_TARGET', '@DEPLOY@'),
    # LD_RUNPATH_SEARCH_PATHS 是多行，单独处理
    ('MARKETING_VERSION', '1.0'),
    ('ONLY_ACTIVE_ARCH', ('YES', 'NO', 'NO')),
    ('PRODUCT_BUNDLE_IDENTIFIER', '@BUNDLE@'),
    ('PRODUCT_NAME', '"$(TARGET_NAME)"'),
    ('SKIP_INSTALL', 'YES'),             # 必须：扩展不能单独安装
    ('SWIFT_ACTIVE_COMPILATION_CONDITIONS', ('DEBUG', '', '')),
    ('SWIFT_COMPILATION_MODE', ('', 'wholemodule', 'wholemodule')),
    ('SWIFT_OPTIMIZATION_LEVEL', ('"-Onone"', '"-O"', '"-O"')),
    ('SWIFT_VERSION', '5.0'),
    ('TARGETED_DEVICE_FAMILY', '"1,2"'),
]

CONFIG_KINDS = ('Debug', 'Release', 'Profile')


def build_objects(uuid_gen, ext_name, ext_bundle_id, deployment_target, project_uuid):
    """生成所有需要新增的 pbxproj 对象文本，返回 (uuid 表, {section: 文本})。"""
    u = {
        'swift_ref': uuid_gen('file-ref-%s' % SWIFT_FILE),
        'plist_ref': uuid_gen('file-ref-%s' % PLIST_FILE),
        'ent_ref': uuid_gen('file-ref-%s' % ENT_FILE),
        'swift_build': uuid_gen('build-file-swift'),
        'group': uuid_gen('group'),
        'target': uuid_gen('target'),
        'product_ref': uuid_gen('product-ref'),
        'sources': uuid_gen('phase-sources'),
        'frameworks': uuid_gen('phase-frameworks'),
        'resources': uuid_gen('phase-resources'),
        'conf_list': uuid_gen('conf-list'),
        'conf_debug': uuid_gen('conf-debug'),
        'conf_release': uuid_gen('conf-release'),
        'conf_profile': uuid_gen('conf-profile'),
        'embed_phase': uuid_gen('embed-phase'),
        'embed_build': uuid_gen('embed-build-file'),
        'dependency': uuid_gen('dependency'),
        'proxy': uuid_gen('proxy'),
    }
    appex = '%s.appex' % ext_name

    # ---------------- PBXBuildFile ----------------
    s = []
    s.append(L(2, '%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };'
                % (u['swift_build'], SWIFT_FILE, u['swift_ref'], SWIFT_FILE)))
    s.append(L(2, '%s /* %s in Embed App Extensions */ = {isa = PBXBuildFile; '
                  'fileRef = %s /* %s */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };'
                % (u['embed_build'], appex, u['product_ref'], appex)))
    sections = {'PBXBuildFile': ''.join(s)}

    # ---------------- PBXFileReference ----------------
    # Info.plist 与 entitlements 只登记、不进任何编译阶段：
    # 它们分别由 INFOPLIST_FILE / CODE_SIGN_ENTITLEMENTS 两个设置引用。
    # 若把 Info.plist 加进 Resources 阶段，会报 Multiple commands produce。
    s = []
    s.append(L(2, '%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
                  'path = %s; sourceTree = "<group>"; };' % (u['swift_ref'], SWIFT_FILE, SWIFT_FILE)))
    s.append(L(2, '%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; '
                  'path = %s; sourceTree = "<group>"; };' % (u['plist_ref'], PLIST_FILE, PLIST_FILE)))
    s.append(L(2, '%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; '
                  'path = %s; sourceTree = "<group>"; };' % (u['ent_ref'], ENT_FILE, ENT_FILE)))
    s.append(L(2, '%s /* %s */ = {isa = PBXFileReference; explicitFileType = "%s"; '
                  'includeInIndex = 0; path = %s; sourceTree = BUILT_PRODUCTS_DIR; };'
                % (u['product_ref'], appex, FILE_TYPE_APPEX, appex)))
    sections['PBXFileReference'] = ''.join(s)

    # ---------------- PBXGroup（源码分组，让 Xcode 左侧能看到） ----------------
    s = [L(2, '%s /* %s */ = {' % (u['group'], ext_name)),
         L(3, 'isa = PBXGroup;'),
         L(3, 'children = ('),
         L(4, '%s /* %s */,' % (u['swift_ref'], SWIFT_FILE)),
         L(4, '%s /* %s */,' % (u['plist_ref'], PLIST_FILE)),
         L(4, '%s /* %s */,' % (u['ent_ref'], ENT_FILE)),
         L(3, ');'),
         L(3, 'path = %s;' % ext_name),
         L(3, 'sourceTree = "<group>";'),
         L(2, '};')]
    sections['PBXGroup'] = ''.join(s)

    # ---------------- PBXNativeTarget ----------------
    s = [L(2, '%s /* %s */ = {' % (u['target'], ext_name)),
         L(3, 'isa = PBXNativeTarget;'),
         L(3, 'buildConfigurationList = %s /* Build configuration list for PBXNativeTarget "%s" */;'
              % (u['conf_list'], ext_name)),
         L(3, 'buildPhases = ('),
         L(4, '%s /* Sources */,' % u['sources']),
         L(4, '%s /* Frameworks */,' % u['frameworks']),
         L(4, '%s /* Resources */,' % u['resources']),
         L(3, ');'),
         L(3, 'buildRules = ('),
         L(3, ');'),
         L(3, 'dependencies = ('),
         L(3, ');'),
         L(3, 'name = %s;' % ext_name),
         L(3, 'productName = %s;' % ext_name),
         L(3, 'productReference = %s /* %s */;' % (u['product_ref'], appex)),
         L(3, 'productType = "%s";' % PRODUCT_TYPE_APP_EXT),
         L(2, '};')]
    sections['PBXNativeTarget'] = ''.join(s)

    # ---------------- 三个编译阶段 ----------------
    phases = (('sources', 'PBXSourcesBuildPhase',
               '%s /* %s in Sources */,' % (u['swift_build'], SWIFT_FILE)),
              ('frameworks', 'PBXFrameworksBuildPhase', None),
              ('resources', 'PBXResourcesBuildPhase', None))
    for key, isa, extra in phases:
        s = [L(2, '%s /* %s */ = {' % (u[key], isa.replace('PBX', '').replace('BuildPhase', ''))),
             L(3, 'isa = %s;' % isa),
             L(3, 'buildActionMask = 2147483647;'),
             L(3, 'files = ('),
             L(4, extra) if extra else '',
             L(3, ');'),
             L(3, 'runOnlyForDeploymentPostprocessing = 0;'),
             L(2, '};')]
        sections[isa] = ''.join(s)

    # ---------------- Embed App Extensions ----------------
    s = [L(2, '%s /* Embed App Extensions */ = {' % u['embed_phase']),
         L(3, 'isa = PBXCopyFilesBuildPhase;'),
         L(3, 'buildActionMask = 2147483647;'),
         L(3, 'dstPath = "";'),
         L(3, 'dstSubfolderSpec = %d;' % DST_PLUGINS),
         L(3, 'files = ('),
         L(4, '%s /* %s in Embed App Extensions */,' % (u['embed_build'], appex)),
         L(3, ');'),
         L(3, 'name = "Embed App Extensions";'),
         L(3, 'runOnlyForDeploymentPostprocessing = 0;'),
         L(2, '};')]
    sections['PBXCopyFilesBuildPhase'] = ''.join(s)

    # ---------------- 主 App 对扩展的依赖 ----------------
    s = [L(2, '%s /* PBXTargetDependency */ = {' % u['dependency']),
         L(3, 'isa = PBXTargetDependency;'),
         L(3, 'target = %s /* %s */;' % (u['target'], ext_name)),
         L(3, 'targetProxy = %s /* PBXContainerItemProxy */;' % u['proxy']),
         L(2, '};')]
    sections['PBXTargetDependency'] = ''.join(s)

    s = [L(2, '%s /* PBXContainerItemProxy */ = {' % u['proxy']),
         L(3, 'isa = PBXContainerItemProxy;'),
         L(3, 'containerPortal = %s /* Project object */;' % project_uuid),
         L(3, 'proxyType = 1;'),
         L(3, 'remoteGlobalIDString = %s;' % u['target']),
         L(3, 'remoteInfo = %s;' % ext_name),
         L(2, '};')]
    sections['PBXContainerItemProxy'] = ''.join(s)

    # ---------------- 构建设置（Debug / Release / Profile） ----------------
    conf_uuids = (u['conf_debug'], u['conf_release'], u['conf_profile'])
    conf_text = []
    for idx, kind in enumerate(CONFIG_KINDS):
        s = [L(2, '%s /* %s */ = {' % (conf_uuids[idx], kind)),
             L(3, 'isa = XCBuildConfiguration;'),
             L(3, 'buildSettings = {')]
        for key, value in sorted(BUILD_SETTINGS, key=lambda kv: kv[0]):
            if key == 'LD_RUNPATH_SEARCH_PATHS':
                continue
            v = value[idx] if isinstance(value, tuple) else value
            if v == '':
                continue        # 该配置下不需要这条（例如 Release 没有 ENABLE_TESTABILITY=YES）
            v = (v.replace('@EXT@', ext_name)
                  .replace('@ENT@', ENT_FILE)
                  .replace('@PLIST@', PLIST_FILE)
                  .replace('@DEPLOY@', deployment_target)
                  .replace('@BUNDLE@', ext_bundle_id))
            s.append(L(4, '%s = %s;' % (key, v)))
            if key == 'IPHONEOS_DEPLOYMENT_TARGET':
                # 紧随其后放多行的 LD_RUNPATH_SEARCH_PATHS，保持字母序
                s.append(L(4, 'LD_RUNPATH_SEARCH_PATHS = ('))
                s.append(L(5, '"$(inherited)",'))
                s.append(L(5, '"@executable_path/Frameworks",'))
                s.append(L(5, '"@executable_path/../../Frameworks",'))
                s.append(L(4, ');'))
        s.append(L(3, '};'))
        s.append(L(3, 'name = %s;' % kind))
        s.append(L(2, '};'))
        conf_text.append(''.join(s))
    sections['XCBuildConfiguration'] = ''.join(conf_text)

    # ---------------- XCConfigurationList ----------------
    s = [L(2, '%s /* Build configuration list for PBXNativeTarget "%s" */ = {'
            % (u['conf_list'], ext_name)),
         L(3, 'isa = XCConfigurationList;'),
         L(3, 'buildConfigurations = ('),
         L(4, '%s /* Debug */,' % u['conf_debug']),
         L(4, '%s /* Release */,' % u['conf_release']),
         L(4, '%s /* Profile */,' % u['conf_profile']),
         L(3, ');'),
         L(3, 'defaultConfigurationIsVisible = 0;'),
         L(3, 'defaultConfigurationName = Release;'),
         L(2, '};')]
    sections['XCConfigurationList'] = ''.join(s)

    return u, sections


# ---------------------------------------------------------------- 主流程


def main():
    ap = argparse.ArgumentParser(
        description='在 Runner.xcodeproj 里创建 Broadcast Upload Extension Target')
    ap.add_argument('--project', default=os.path.join('ios', 'Runner.xcodeproj', 'project.pbxproj'),
                    help='pbxproj 路径（默认 ios/Runner.xcodeproj/project.pbxproj）')
    ap.add_argument('--name', default=EXT_NAME, help='扩展 target 名（默认 %s）' % EXT_NAME)
    ap.add_argument('--bundle-id', default=None,
                    help='扩展的 Bundle ID（默认 = 主 App 的 + .<name>）')
    ap.add_argument('--deployment-target', default='13.0', help='最低 iOS 版本（默认 13.0）')
    ap.add_argument('--dry-run', action='store_true', help='只校验，不写文件')
    args = ap.parse_args()

    ext_name = args.name
    path = args.project

    print('=' * 70)
    print(' 创建 iOS 录屏扩展 Target')
    print(' 工程文件: %s' % path)
    print('=' * 70)

    text = read(path)
    if text is None:
        die('找不到 %s\n'
            '   请先执行 flutter create --platforms=ios 生成 iOS 工程，'
            '或检查 --project 参数。' % path)

    # ---------- 幂等 ----------
    if 'productType = "%s"' % PRODUCT_TYPE_APP_EXT in text:
        log('✓ 已存在 app-extension target，跳过（幂等）')
        return 0

    project_uuid = find_uuid_by_line(text, r'^\trootObject = ([0-9A-F]{24})')
    if not project_uuid:
        die('pbxproj 里找不到 rootObject')
    main_group = find_uuid_by_line(text, r'^\t{3}mainGroup = ([0-9A-F]{24})')
    if not main_group:
        die('pbxproj 里找不到 mainGroup')
    products = find_uuid_by_line(
        text, r'^\t{2}([0-9A-F]{24}) /\* Products \*/ = \{\n\t{3}isa = PBXGroup;')

    app_uuid, app_name, app_block = find_app_target(text)
    if not app_uuid:
        die('找不到主 App target（productType = application）')

    # 优先用显式指定的 Bundle ID：主 App 的 PRODUCT_BUNDLE_IDENTIFIER 有可能是
    # 变量（如 $(PRODUCT_NAME:rfc1034identifier)），那种情况下推导不出来。
    bundle_id = target_bundle_id(text, app_block) or '(未设置)'
    if args.bundle_id:
        ext_bundle_id = args.bundle_id
    else:
        if bundle_id == '(未设置)':
            die('主 App 没有设置 PRODUCT_BUNDLE_IDENTIFIER，推导不出扩展的 Bundle ID。\n'
                '   请用 --bundle-id 显式指定，例如 com.yourcompany.meetingApp.%s' % ext_name)
        if '$(' in bundle_id:
            die('主 App 的 PRODUCT_BUNDLE_IDENTIFIER 是变量（%s），推导不出扩展的 Bundle ID。\n'
                '   请用 --bundle-id 显式指定，例如 com.yourcompany.meetingApp.%s'
                % (bundle_id, ext_name))
        ext_bundle_id = '%s.%s' % (bundle_id, ext_name)

    log('主 App target : %s（%s）' % (app_name, app_uuid))
    log('主 App Bundle : %s' % bundle_id)
    log('扩展 Bundle ID: %s' % ext_bundle_id)

    uuid_gen = make_uuid_gen(text)
    uuids, sections = build_objects(uuid_gen, ext_name, ext_bundle_id,
                                    args.deployment_target, project_uuid)

    out = text

    # ---------- 1. 各 section 追加新对象 ----------
    for section, block in sections.items():
        out = insert_object(out, section, block)

    # ---------- 2. 产物 .appex 登记到 Products 分组 ----------
    products_block = object_block(out, products) if products else None
    if products_block:
        new_products = insert_into_list(
            products_block, 'children',
            L(4, '%s /* %s.appex */,' % (uuids['product_ref'], ext_name)))
        if new_products:
            out = out.replace(products_block, new_products)
        else:
            log('!! Products 分组里没能插入 .appex 引用（Xcode 里看不到产物，不影响构建）')
    else:
        log('!! 没找到 Products 分组（Xcode 里看不到产物，不影响构建）')

    # ---------- 3. 源码分组登记到 mainGroup ----------
    main_block = object_block(out, main_group)
    if main_block:
        new_main = insert_into_list(
            main_block, 'children',
            L(4, '%s /* %s */,' % (uuids['group'], ext_name)))
        if new_main:
            out = out.replace(main_block, new_main)
        else:
            log('!! mainGroup 里没能插入源码分组（Xcode 里看不到源码，不影响构建）')

    # ---------- 4. 主 App：加 Embed App Extensions + 依赖 ----------
    app_block_now = object_block(out, app_uuid)
    if not app_block_now:
        die('主 App target 块定位失败，拒绝继续（避免写坏工程）')

    new_app = insert_into_list(
        app_block_now, 'buildPhases',
        L(4, '%s /* Embed App Extensions */,' % uuids['embed_phase']),
        before_comment='/* Embed Frameworks */')
    if not new_app:
        die('没能往主 App 的 buildPhases 里插入 Embed App Extensions')

    new_app2 = insert_into_list(
        new_app, 'dependencies',
        L(4, '%s /* PBXTargetDependency */,' % uuids['dependency']))
    if not new_app2:
        die('没能往主 App 的 dependencies 里插入扩展依赖')

    out = out.replace(app_block_now, new_app2)

    # ---------- 5. project.targets 登记 ----------
    m = re.search(r'(\t{3}targets = \(\n)((?:[^\n]*\n)*?)(\t{3}\);)', out)
    if not m:
        die('找不到 project 的 targets 列表')
    out = (out[:m.start(2)]
           + m.group(2)
           + L(4, '%s /* %s */,' % (uuids['target'], ext_name))
           + out[m.end(2):])

    # ---------- 6. 自校验（不通过就不落盘） ----------
    problems = verify(out, uuids, ext_name, ext_bundle_id, project_uuid)
    if problems:
        sys.stderr.write('\n'.join('!! ' + p for p in problems) + '\n')
        die('自校验未通过，**未写入文件**（原工程保持不动）。')

    if args.dry_run:
        log('✓ 自校验通过（--dry-run，未写文件）')
        return 0

    write(path, out)
    log('✓ 已写入 %s' % path)
    log('✓ 新增 target：%s（%s）' % (ext_name, ext_bundle_id))
    return 0


# ---------------------------------------------------------------- 自校验


def verify(text, uuids, ext_name, ext_bundle_id, project_uuid):
    """重新解析结果并逐项断言。返回问题列表（空 = 通过）。"""
    p = []

    # 括号平衡是「工程能不能被 Xcode 打开」的最基本保证
    for open_c, close_c, label in (('{', '}', '花括号'), ('(', ')', '圆括号')):
        if text.count(open_c) != text.count(close_c):
            p.append('%s不平衡：%d 个 %s vs %d 个 %s'
                     % (label, text.count(open_c), open_c, text.count(close_c), close_c))

    tb = object_block(text, uuids['target'])
    if not tb:
        p.append('找不到新建的 target 对象')
        return p
    if PRODUCT_TYPE_APP_EXT not in tb:
        p.append('target 的 productType 不正确')
    if 'name = %s;' % ext_name not in tb:
        p.append('target 的 name 不正确')

    if not object_block(text, uuids['product_ref']):
        p.append('找不到 .appex 的 file reference')

    for key in ('sources', 'frameworks', 'resources'):
        if not object_block(text, uuids[key]):
            p.append('缺少编译阶段对象：%s' % key)

    src_block = object_block(text, uuids['sources']) or ''
    if uuids['swift_build'] not in src_block:
        p.append('SampleHandler.swift 没有被加入 Sources 阶段 —— 扩展会编译成空壳')

    conf = object_block(text, uuids['conf_debug']) or ''
    for key, want in (('PRODUCT_BUNDLE_IDENTIFIER', ext_bundle_id),
                      ('INFOPLIST_FILE', '%s/%s' % (ext_name, PLIST_FILE)),
                      ('CODE_SIGN_ENTITLEMENTS', '%s/%s' % (ext_name, ENT_FILE)),
                      ('APPLICATION_EXTENSION_API_ONLY', 'YES'),
                      ('SKIP_INSTALL', 'YES')):
        got = get_setting(conf, key)
        if got is None:
            p.append('扩展的 build settings 缺少 %s' % key)
        elif want not in got:
            p.append('扩展的 %s = %s，期望 %s' % (key, got, want))

    _, _, app_block = find_app_target(text)
    app_block = app_block or ''
    if uuids['embed_phase'] not in app_block:
        p.append('主 App 的 buildPhases 里没有 Embed App Extensions —— .appex 不会被打进包里')
    if uuids['dependency'] not in app_block:
        p.append('主 App 没有声明对扩展的依赖')

    embed = object_block(text, uuids['embed_phase']) or ''
    if 'dstSubfolderSpec = %d' % DST_PLUGINS not in embed:
        p.append('Embed App Extensions 的 dstSubfolderSpec 不是 %d（PlugIns）' % DST_PLUGINS)
    if uuids['embed_build'] not in embed:
        p.append('Embed App Extensions 里没有 .appex 的 build file')

    m = re.search(r'\t{3}targets = \(\n((?:[^\n]*\n)*?)\t{3}\);', text)
    if not m or uuids['target'] not in m.group(1):
        p.append('project 的 targets 列表里没有新 target')

    proxy = object_block(text, uuids['proxy']) or ''
    if project_uuid not in proxy:
        p.append('PBXContainerItemProxy 的 containerPortal 指向不正确的工程')

    # 引用完整性：pbxproj 里出现的任何 24 位十六进制串都必须有对应定义。
    # 少一个定义，Xcode 就打开不了工程。这条专门兜住「拼列表项时漏了 UUID
    # 只剩注释」这类只在特定位置才暴露的写法错误 —— 曾经真的漏过一次。
    # 缩进用 \t+ 而不是 \t{2}：Xcode 自己生成的工程里个别对象层级的缩进并不统一，
    # 卡死 2 个 tab 会产生误报（实测被 TargetAttributes 的条目误伤过）。
    defined = set(re.findall(r'^\t+([0-9A-F]{24}) ', text, re.M))
    dangling = set(re.findall(r'[0-9A-F]{24}', text)) - defined
    if dangling:
        p.append('存在无定义的引用（悬空 UUID）：%s' % ', '.join(sorted(dangling)))

    # 产物与源码要登记进分组，否则 Xcode 左侧会显示成缺失引用
    if not re.search(r'^\t{4}%s /\* %s\.appex \*/,' % (uuids['product_ref'], re.escape(ext_name)),
                     text, re.M):
        p.append('Products 分组里没有登记 .appex')
    if not re.search(r'^\t{4}%s /\* %s \*/,' % (uuids['group'], re.escape(ext_name)),
                     text, re.M):
        p.append('mainGroup 里没有登记扩展的源码分组')

    return p


if __name__ == '__main__':
    sys.exit(main())
