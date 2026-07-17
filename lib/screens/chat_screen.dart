import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import '../models/chat_message.dart';

// ========== Backend networking ==========
const String _kDomain = 'ce.a2ne.com';
final InternetAddress _kIp = InternetAddress('43.131.228.126');
const int _kPort = 443;

int _httpStatus(List<int> raw) {
  for (int i = 0; i < raw.length - 3; i++) {
    if (raw[i] == 13 && raw[i + 1] == 10 && raw[i + 2] == 13 && raw[i + 3] == 10) {
      final h = utf8.decode(raw.sublist(0, i));
      final p = h.split('\r\n')[0].split(' ');
      return p.length > 1 ? int.tryParse(p[1]) ?? 500 : 500;
    }
  }
  return 500;
}

List<int> _httpBody(List<int> raw) {
  for (int i = 0; i < raw.length - 3; i++) {
    if (raw[i] == 13 && raw[i + 1] == 10 && raw[i + 2] == 13 && raw[i + 3] == 10) {
      return raw.sublist(i + 4);
    }
  }
  return [];
}

Future<SecureSocket> _connect() async {
  final raw =
      await Socket.connect(_kIp, _kPort, timeout: const Duration(seconds: 15));
  return SecureSocket.secure(raw, host: _kDomain, onBadCertificate: (_) => true);
}

Future<Map<String, dynamic>> _post(String path, String text, File? img) async {
  final bd = 'BZ${DateTime.now().millisecondsSinceEpoch}Z';
  final buf = <int>[];
  void w(String s) => buf.addAll(utf8.encode(s));
  w('--$bd\r\nContent-Disposition: form-data; name="text"\r\n\r\n$text\r\n');
  if (img != null && img.existsSync()) {
    final ext = img.path.endsWith('.png') ? 'png' : 'jpeg';
    final d = await img.readAsBytes();
    w('--$bd\r\nContent-Disposition: form-data; name="image"; filename="image.$ext"\r\nContent-Type: image/$ext\r\n\r\n');
    buf.addAll(d);
    w('\r\n');
  }
  w('--$bd--\r\n');
  final s = await _connect();
  try {
    s.add(utf8.encode(
        'POST $path HTTP/1.1\r\nHost: $_kDomain\r\nContent-Type: multipart/form-data; boundary=$bd\r\nContent-Length: ${buf.length}\r\nConnection: close\r\n\r\n'));
    s.add(buf);
    await s.flush();
    final raw = <int>[];
    await for (final c in s) {
      raw.addAll(c);
    }
    final status = _httpStatus(raw);
    if (status != 200) {
      final body = utf8.decode(_httpBody(raw));
      String detail = '';
      try {
        final j = jsonDecode(body);
        detail = j['error'] ?? j.toString();
      } catch (_) {
        detail = body.length > 200 ? body.substring(0, 200) : body;
      }
      return {'error': 'HTTP $status: $detail'};
    }
    return jsonDecode(utf8.decode(_httpBody(raw))) as Map<String, dynamic>;
  } finally {
    s.close();
  }
}

Future<Uint8List> _getBytes(String url) async {
  final s = await _connect();
  try {
    final u = url.startsWith('http') ? Uri.parse(url).path : url;
    s.add(utf8.encode(
        'GET $u HTTP/1.1\r\nHost: $_kDomain\r\nConnection: close\r\n\r\n'));
    await s.flush();
    final raw = <int>[];
    await for (final c in s) {
      raw.addAll(c);
    }
    return Uint8List.fromList(_httpBody(raw));
  } finally {
    s.close();
  }
}

// ========== Free local image tools ==========
enum ToolType {
  meitu('美图AI', Icons.auto_awesome, false),
  grayscale('黑白', Icons.color_lens, true),
  sepia('复古', Icons.wb_sunset, true),
  brighten('增亮', Icons.brightness_high, true),
  contrast('对比度', Icons.contrast, true),
  rotate('旋转', Icons.rotate_right, true),
  flip('翻转', Icons.flip, true),
  blur('模糊', Icons.blur_on, true);

  final String label;
  final IconData icon;
  final bool isLocal;
  const ToolType(this.label, this.icon, this.isLocal);
}

Future<Uint8List> _processLocalTool(File imageFile, ToolType tool) async {
  final bytes = await imageFile.readAsBytes();
  final src = img.decodeImage(bytes);
  if (src == null) throw Exception('无法解码图片');

  img.Image processed;
  switch (tool) {
    case ToolType.grayscale:
      processed = img.grayscale(src);
      break;
    case ToolType.sepia:
      processed = _applySepia(src);
      break;
    case ToolType.brighten:
      processed = img.adjustColor(src, brightness: 0.3);
      break;
    case ToolType.contrast:
      processed = img.adjustColor(src, contrast: 1.5);
      break;
    case ToolType.rotate:
      processed = img.copyRotate(src, 90);
      break;
    case ToolType.flip:
      processed = img.flipHorizontal(src);
      break;
    case ToolType.blur:
      processed = _applyBlur(src);
      break;
    default:
      processed = src;
  }

  final ext = imageFile.path.endsWith('.png') ? '.png' : '.jpg';
  final outBytes =
      ext == '.png' ? img.encodePng(processed) : img.encodeJpg(processed, quality: 95);
  return Uint8List.fromList(outBytes);
}

img.Image _applySepia(img.Image src) {
  final dst = img.Image.from(src);
  for (final p in dst) {
    final r = p.r.toInt();
    final g = p.g.toInt();
    final b = p.b.toInt();
    final tr = (0.393 * r + 0.769 * g + 0.189 * b).toInt();
    final tg = (0.349 * r + 0.686 * g + 0.168 * b).toInt();
    final tb = (0.272 * r + 0.534 * g + 0.131 * b).toInt();
    p
      ..r = tr.clamp(0, 255)
      ..g = tg.clamp(0, 255)
      ..b = tb.clamp(0, 255);
  }
  return dst;
}

img.Image _applyBlur(img.Image src) {
  final radius = 3;
  final w = src.width;
  final h = src.height;
  final dst = img.Image.from(src);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      int r = 0, g = 0, b = 0, count = 0;
      for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
          final nx = (x + dx).clamp(0, w - 1);
          final ny = (y + dy).clamp(0, h - 1);
          final p = src.getPixel(nx, ny);
          r += p.r.toInt();
          g += p.g.toInt();
          b += p.b.toInt();
          count++;
        }
      }
      dst.setPixelRgba(x, y, r ~/ count, g ~/ count, b ~/ count, 255);
    }
  }
  return dst;
}

// ========== Storage helpers ==========
class _Store {
  static String? _base;

  static Future<String> get _dir async {
    if (_base == null) {
      final d = await getApplicationDocumentsDirectory();
      final b = Directory('${d.path}/xiutu_data');
      if (!b.existsSync()) b.createSync(recursive: true);
      _base = b.path;
    }
    return _base!;
  }

  static Future<List<ChatMessage>> loadMsgs() async {
    final f = File('${await _dir}/msgs.json');
    if (!f.existsSync()) return [];
    try {
      return (jsonDecode(await f.readAsString()) as List).map((e) => ChatMessage(
        text: e['t'] ?? '',
        isUser: e['u'] ?? false,
        time: DateTime.parse(e['ts']),
        imagePath: e['ip'],
        resultImageUrl: e['rp'],
        resultImagePath: e['rpl'],
      )).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveMsgs(List<ChatMessage> msgs) async {
    if (msgs.isEmpty) return;
    await File('${await _dir}/msgs.json').writeAsString(jsonEncode(msgs
        .map((m) => {
              't': m.text,
              'u': m.isUser,
              'ts': m.time.toIso8601String(),
              'ip': m.imagePath,
              'rp': m.resultImageUrl,
              'rpl': m.resultImagePath,
            })
        .toList()));
  }

  static Future<List<EditRecord>> loadRecords() async {
    final f = File('${await _dir}/records.json');
    if (!f.existsSync()) return [];
    try {
      return (jsonDecode(await f.readAsString()) as List).map((e) => EditRecord(
            id: e['id'] ?? '',
            timestamp: DateTime.parse(e['ts']),
            toolName: e['tool'] ?? '',
            description: e['desc'] ?? '',
            beforeImagePath: e['before'],
            afterImagePath: e['after'],
          )).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveRecords(List<EditRecord> records) async {
    await File('${await _dir}/records.json').writeAsString(jsonEncode(records
        .map((r) => {
              'id': r.id,
              'ts': r.timestamp.toIso8601String(),
              'tool': r.toolName,
              'desc': r.description,
              'before': r.beforeImagePath,
              'after': r.afterImagePath,
            })
        .toList()));
  }

  static Future<String> saveResultImage(Uint8List bytes, String prefix) async {
    await Directory('${await _dir}/images').create(recursive: true);
    final path =
        '${await _dir}/images/${prefix}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(path).writeAsBytes(bytes);
    return path;
  }
}

// ========== Edit Record ==========
class EditRecord {
  final String id;
  final DateTime timestamp;
  final String toolName;
  final String description;
  final String beforeImagePath;
  final String? afterImagePath;

  EditRecord({
    required this.id,
    required this.timestamp,
    required this.toolName,
    required this.description,
    required this.beforeImagePath,
    this.afterImagePath,
  });
}

// ========== History Page ==========
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<EditRecord> _records = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await _Store.loadRecords();
    setState(() {
      _records = records.reversed.toList();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('修图记录'),
        actions: [
          if (_records.isNotEmpty)
            IconButton(
                icon: const Icon(Icons.delete_sweep),
                onPressed: () {
                  showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                            title: const Text('清空记录'),
                            content: const Text('确定清空所有修图记录？'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('取消')),
                              TextButton(
                                  onPressed: () {
                                    _Store.saveRecords([]);
                                    setState(() => _records.clear());
                                    Navigator.pop(ctx);
                                  },
                                  child: const Text('清空',
                                      style: TextStyle(color: Colors.red))),
                            ],
                          ));
                }),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? const Center(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                      Icon(Icons.photo_library_outlined,
                          size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('暂无修图记录',
                          style:
                              TextStyle(color: Colors.grey, fontSize: 16)),
                    ]))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _records.length,
                  itemBuilder: (ctx, i) {
                    final r = _records[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _showDetail(r),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primaryContainer,
                                        borderRadius:
                                            BorderRadius.circular(8)),
                                    child: Text(r.toolName,
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onPrimaryContainer))),
                                const Spacer(),
                                Text(
                                    '${r.timestamp.month}/${r.timestamp.day} ${r.timestamp.hour.toString().padLeft(2, '0')}:${r.timestamp.minute.toString().padLeft(2, '0')}',
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.grey)),
                              ]),
                              const SizedBox(height: 8),
                              Text(r.description,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14)),
                              const SizedBox(height: 8),
                              Row(children: [
                                Expanded(
                                    child: AspectRatio(
                                        aspectRatio: 1,
                                        child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            child: Image.file(
                                                File(r.beforeImagePath),
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) =>
                                                    const Icon(
                                                        Icons.broken_image))))),
                                const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 8),
                                    child: Icon(Icons.arrow_forward,
                                        color: Colors.grey)),
                                Expanded(
                                    child: AspectRatio(
                                        aspectRatio: 1,
                                        child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            child: r.afterImagePath !=
                                                        null &&
                                                    File(r.afterImagePath!)
                                                        .existsSync()
                                                ? Image.file(
                                                    File(r.afterImagePath!),
                                                    fit: BoxFit.cover,
                                                    errorBuilder:
                                                        (_, __, ___) =>
                                                            const Icon(Icons
                                                                .broken_image))
                                                : Container(
                                                    color: Colors.grey[200],
                                                    child: const Icon(
                                                        Icons
                                                            .image_not_supported,
                                                        color:
                                                            Colors.grey))))),
                              ]),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
    );
  }

  void _showDetail(EditRecord r) {
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => _HistoryDetailPage(record: r)));
  }
}

class _HistoryDetailPage extends StatelessWidget {
  final EditRecord record;
  const _HistoryDetailPage({required this.record});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('修图详情')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10)),
                child: Text(record.toolName,
                    style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onPrimaryContainer))),
            const SizedBox(width: 12),
            Text(
                '${record.timestamp.year}/${record.timestamp.month}/${record.timestamp.day} ${record.timestamp.hour.toString().padLeft(2, '0')}:${record.timestamp.minute.toString().padLeft(2, '0')}',
                style: const TextStyle(color: Colors.grey, fontSize: 13)),
          ]),
          const SizedBox(height: 12),
          Text(record.description, style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 16),
          const Text('原图', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(File(record.beforeImagePath),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.broken_image, size: 100))),
          const SizedBox(height: 16),
          const Text('处理后', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (record.afterImagePath != null &&
              File(record.afterImagePath!).existsSync())
            ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(File(record.afterImagePath!),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.broken_image, size: 100)))
          else
            Container(
                height: 200,
                decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(12)),
                child: const Center(
                    child: Text('图片不存在',
                        style: TextStyle(color: Colors.grey)))),
        ]),
      ),
    );
  }
}

// ========== Main Chat Screen ==========
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  List<ChatMessage> _msgs = [];
  final TextEditingController _txt = TextEditingController();
  final ScrollController _scrl = ScrollController();
  final ImagePicker _picker = ImagePicker();
  File? _pending;
  bool _busy = false;
  ToolType _selectedTool = ToolType.meitu;
  String? _resultPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadHistory();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _persist();
    }
  }

  Future<void> _loadHistory() async {
    final saved = await _Store.loadMsgs();
    if (saved.isNotEmpty) {
      setState(() => _msgs = saved);
    } else {
      _welcome();
    }
  }

  void _welcome() {
    setState(() {
      _msgs.add(ChatMessage(
          text: '👋 你好！请选一张图片，然后选择工具进行处理！\n\n'
              '顶部工具栏可以切换工具：\n'
              '• 🤖 美图AI - 云端智能处理（需联网）\n'
              '• 🎨 本地工具 - 免费、快速、无需网络\n'
              '\n处理完的图片可放大查看，也可下载到手机！',
          isUser: false,
          time: DateTime.now()));
    });
  }

  void _scroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrl.hasClients) {
        _scrl.animateTo(_scrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _pick() async {
    if (_busy) return;
    try {
      final i = await _picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 1920,
          maxHeight: 1920,
          imageQuality: 90);
      if (i != null) {
        setState(() => _pending = File(i.path));
        _msgs.add(ChatMessage(
            text: '已选择图片，选择工具后点击发送',
            isUser: false,
            time: DateTime.now(),
            imagePath: i.path));
        setState(() {});
        _scroll();
        _persist();
      }
    } catch (_) {
      _err('选择图片失败');
    }
  }

  Future<void> _send() async {
    final t = _txt.text.trim();
    if (t.isEmpty && _pending == null) {
      _err('请先选择图片');
      return;
    }
    if (_pending == null) {
      _err('请先选择图片');
      return;
    }

    final desc = t.isNotEmpty ? t : '使用${_selectedTool.label}处理';
    final userMsg = ChatMessage(
        text: desc,
        isUser: true,
        time: DateTime.now(),
        imagePath: _pending?.path);
    setState(() {
      _busy = true;
      _msgs.add(userMsg);
    });
    _txt.clear();
    _scroll();

    if (_selectedTool.isLocal) {
      await _processLocal(t);
    } else {
      await _processMeitu(t);
    }

    setState(() {
      _pending = null;
      _busy = false;
    });
  }

  // ===== Meitu API processing =====
  Future<void> _processMeitu(String text) async {
    try {
      _addLoading('⏳ 正在调用美图API处理，请稍候...');
      final data = await _post('/api/edit', text, _pending);
      if (data.containsKey('error')) {
        _replace('❌ 处理失败：${data['error']}');
        return;
      }
      final exp = data['explanation'] ?? '处理完成';
      final rp = data['result_image_url'];
      final tu = data['tool_used'];
      final cc = data['credit_consumed'];
      final cr = data['credit_remaining'];
      String r = '✅ $exp\n\n🔧 $tu\n';
      if (cc != null) r += '💳 消耗积分：$cc\n';
      if (cr != null) r += '📊 剩余积分：$cr';
      if (rp != null && rp is String) {
        final bytes = await _getBytes(rp);
        if (bytes.isNotEmpty) {
          final localPath = await _Store.saveResultImage(bytes, 'meitu');
          _resultPath = localPath;
          _saveEditRecord(desc: text.isNotEmpty ? text : '美图AI修图',
              tool: '美图AI ($tu)',
              beforePath: _pending!.path,
              afterPath: localPath);
          _replaceWithImage('$r\n\n点击图片放大查看，点击 📥 下载到手机', localPath);
        } else {
          _replace('$r\n\n⚠️ 结果图片下载失败');
        }
      } else {
        _replace('$r\n\n⚠️ 未返回处理结果图片');
      }
    } catch (e) {
      _replace('❌ 网络错误：$e');
    }
    _scroll();
  }

  // ===== Local tool processing =====
  Future<void> _processLocal(String text) async {
    try {
      _addLoading('⏳ 正在使用${_selectedTool.label}处理...');
      final bytes = await _processLocalTool(_pending!, _selectedTool);
      final localPath = await _Store.saveResultImage(bytes, _selectedTool.name);
      _resultPath = localPath;
      _saveEditRecord(
          desc: '${_selectedTool.label}处理',
          tool: _selectedTool.label,
          beforePath: _pending!.path,
          afterPath: localPath);
      _replaceWithImage('✅ ${_selectedTool.label}处理完成\n\n点击图片放大查看，点击 📥 下载到手机',
          localPath);
    } catch (e) {
      _replace('❌ 处理失败：$e');
    }
    _scroll();
  }

  void _addLoading(String text) {
    setState(() {
      _msgs.add(ChatMessage(
          text: text,
          isUser: false,
          time: DateTime.now(),
          isLoading: true));
    });
    _scroll();
  }

  void _saveEditRecord({
    required String desc,
    required String tool,
    required String beforePath,
    required String afterPath,
  }) async {
    try {
      final records = await _Store.loadRecords();
      records.add(EditRecord(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        timestamp: DateTime.now(),
        toolName: tool,
        description: desc,
        beforeImagePath: beforePath,
        afterImagePath: afterPath,
      ));
      await _Store.saveRecords(records);
    } catch (_) {}
  }

  void _replace(String t) {
    setState(() {
      if (_msgs.isNotEmpty && _msgs.last.isLoading) _msgs.removeLast();
      _msgs.add(ChatMessage(text: t, isUser: false, time: DateTime.now()));
    });
    _persist();
  }

  void _replaceWithImage(String t, String imagePath) {
    setState(() {
      if (_msgs.isNotEmpty && _msgs.last.isLoading) _msgs.removeLast();
      _msgs.add(ChatMessage(
          text: t,
          isUser: false,
          time: DateTime.now(),
          resultImagePath: imagePath));
    });
    _persist();
  }

  void _err(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _persist();
    _txt.dispose();
    _scrl.dispose();
    super.dispose();
  }

  Future<void> _persist() async {
    try {
      await _Store.saveMsgs(_msgs);
    } catch (_) {}
  }

  void _downloadImage(String path) {
    if (!File(path).existsSync()) {
      _err('图片文件不存在');
      return;
    }
    // Copy to Pictures/DCIM directory so user can find it
    _saveToGallery(path);
  }

  Future<void> _saveToGallery(String srcPath) async {
    try {
      final d = Directory('/storage/emulated/0/Pictures/AI修图');
      if (!d.existsSync()) d.createSync(recursive: true);
      final name = 'xiutu_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final dst = '${d.path}/$name';
      await File(srcPath).copy(dst);
      _err('已保存到 相册/AI修图 文件夹');
    } catch (e) {
      _err('保存失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI修图'),
        centerTitle: true,
        actions: [
          IconButton(
              icon: const Icon(Icons.history),
              tooltip: '修图记录',
              onPressed: () {
                Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HistoryPage()));
              }),
          if (_pending != null)
            IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _pending = null)),
        ],
      ),
      body: Column(children: [
        _toolBar(t),
        Expanded(
            child: _msgs.isEmpty
                ? const Center(child: Text('来开始修图吧！'))
                : ListView.builder(
                    controller: _scrl,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    itemCount: _msgs.length,
                    itemBuilder: (ctx, i) => _bubble(_msgs[i], t, ctx))),
        if (_pending != null) _preview(),
        _input(t),
      ]),
    );
  }

  Widget _toolBar(ThemeData t) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 2,
              offset: const Offset(0, 1))
        ],
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: ToolType.values.map((tool) {
            final selected = tool == _selectedTool;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: ChoiceChip(
                showCheckmark: false,
                selected: selected,
                label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(tool.icon, size: 16),
                      const SizedBox(width: 4),
                      Text(tool.label, style: const TextStyle(fontSize: 12)),
                    ]),
                onSelected: (_) {
                  if (!_busy) setState(() => _selectedTool = tool);
                },
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _bubble(ChatMessage m, ThemeData t, BuildContext ctx) {
    final u = m.isUser;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
          crossAxisAlignment:
              u ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // User's selected image
            if (u && m.imagePath != null)
              Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(File(m.imagePath!),
                          width: 200,
                          height: 200,
                          fit: BoxFit.cover))),

            // Result image with download button
            if (!u &&
                m.resultImagePath != null &&
                File(m.resultImagePath!).existsSync())
              Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Column(children: [
                    InkWell(
                        onTap: () => _fullImage(m.resultImagePath!),
                        child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(File(m.resultImagePath!),
                                width: 250,
                                height: 250,
                                fit: BoxFit.contain))),
                    const SizedBox(height: 4),
                    Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            iconSize: 20,
                            icon: const Icon(Icons.fullscreen),
                            tooltip: '放大查看',
                            onPressed: () =>
                                _fullImage(m.resultImagePath!),
                          ),
                          IconButton(
                            iconSize: 20,
                            icon: const Icon(Icons.download),
                            tooltip: '下载到手机',
                            onPressed: () =>
                                _downloadImage(m.resultImagePath!),
                          ),
                        ]),
                  ])),

            // Loading indicator
            if (m.isLoading)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2))),

            // Text bubble
            if (m.text.isNotEmpty)
              Container(
                constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(ctx).size.width * 0.75),
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: u
                      ? t.colorScheme.primary
                      : t.colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(18).copyWith(
                    bottomLeft: u
                        ? const Radius.circular(18)
                        : const Radius.circular(4),
                    bottomRight: u
                        ? const Radius.circular(4)
                        : const Radius.circular(18),
                  ),
                ),
                child: Text(m.text,
                    style: TextStyle(
                        color: u
                            ? t.colorScheme.onPrimary
                            : t.colorScheme.onSurface,
                        fontSize: 15)),
              ),

            // Timestamp
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 8, right: 8),
              child: Text(
                  '${m.time.hour.toString().padLeft(2, '0')}:${m.time.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(
                      color: t.colorScheme.onSurfaceVariant, fontSize: 11)),
            ),
          ]),
    );
  }

  Widget _preview() {
    return Container(
      height: 80,
      color: Colors.grey[100],
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(_pending!,
                width: 60, height: 60, fit: BoxFit.cover)),
        const SizedBox(width: 12),
        Expanded(
            child: Text('已选择图片，选择顶部工具后发送',
                style: TextStyle(color: Colors.grey[600], fontSize: 13))),
      ]),
    );
  }

  Widget _input(ThemeData t) {
    return Container(
      padding: EdgeInsets.only(
          left: 8, right: 8, top: 8,
          bottom: MediaQuery.of(context).padding.bottom + 8),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 4,
              offset: const Offset(0, -1))
        ],
      ),
      child: Row(children: [
        IconButton(
            icon: const Icon(Icons.image_outlined),
            color: t.colorScheme.primary,
            onPressed: _busy ? null : _pick),
        Expanded(
            child: TextField(
          controller: _txt,
          enabled: !_busy,
          decoration: InputDecoration(
            hintText: _pending != null ? '输入需求或留空直接处理...' : '先选图片',
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none),
            filled: true,
            fillColor: t.colorScheme.surfaceVariant,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
          textInputAction: TextInputAction.send,
          onSubmitted: (_) => _send(),
          maxLines: 3,
          minLines: 1,
        )),
        const SizedBox(width: 4),
        IconButton.filled(
            icon: const Icon(Icons.send_rounded),
            color: t.colorScheme.onPrimary,
            onPressed: _busy ? null : _send),
      ]),
    );
  }

  void _fullImage(String path) {
    if (!File(path).existsSync()) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                title: const Text('修图结果'),
                actions: [
                  IconButton(
                      icon: const Icon(Icons.download),
                      tooltip: '下载到手机',
                      onPressed: () => _downloadImage(path)),
                ]),
            body: Center(
                child: InteractiveViewer(
                    child: Image.file(File(path), fit: BoxFit.contain))))));
  }
}
