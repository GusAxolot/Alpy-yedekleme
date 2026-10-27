import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const ch = MethodChannel('alpy/native');
const red = Color(0xFFE5192B);
const defRoot = '/sdcard/AlpyYedekleme';
const grads = [
  [Color(0xFF2A0007), Color(0xFF000000)],
  [Color(0xFF7A0010), Color(0xFF1A0004)],
  [Color(0xFFB1121F), Color(0xFF3A0008)],
  [Color(0xFF0D0204), Color(0xFF0D0204)],
];

String q(String s) => "'${s.replaceAll("'", r"'\''")}'";
String fmtKb(int kb) => kb > 1048576
    ? '${(kb / 1048576).toStringAsFixed(1)} GB'
    : kb > 1024
        ? '${(kb / 1024).toStringAsFixed(0)} MB'
        : '$kb KB';

class AppInfo {
  final String name, pkg, version;
  final bool system;
  final Uint8List? icon;
  AppInfo(this.name, this.pkg, this.version, this.system, this.icon);
}

class Backup {
  String id, name, pkg, version, date;
  int sizeKb;
  Uint8List? icon;
  Backup(this.id, this.name, this.pkg, this.version, this.date, this.sizeKb, this.icon);
  factory Backup.fromJson(Map j) => Backup(
      j['id'], j['name'], j['pkg'], j['version'] ?? '', j['date'] ?? '',
      (j['sizeKb'] ?? 0) as int, j['icon'] != null ? base64Decode(j['icon']) : null);
  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'pkg': pkg, 'version': version, 'date': date,
        'sizeKb': sizeKb, 'icon': icon != null ? base64Encode(icon!) : null,
      };
}

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Alpy Yedekleme',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'Minecraft',
          colorScheme: const ColorScheme.dark(primary: red, secondary: red),
          scaffoldBackgroundColor: const Color(0xFF120508),
          dialogBackgroundColor: const Color(0xFF1E0A0D),
        ),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  SharedPreferences? sp;
  String root = defRoot, wall = 'g0', shizuku = 'checking', query = '';
  bool showSystem = false;
  List<String> customWalls = [];
  List<AppInfo> apps = [];
  List<Backup> backups = [];
  String? busy;

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    sp = await SharedPreferences.getInstance();
    root = sp!.getString('root') ?? defRoot;
    wall = sp!.getString('wall') ?? 'g0';
    showSystem = sp!.getBool('sys') ?? false;
    customWalls = sp!.getStringList('walls') ?? [];
    setState(() {});
    await checkShizuku();
  }

  Future<Map> sh(String cmd) async => await ch.invokeMethod('shell', cmd) as Map;

  Future<void> checkShizuku() async {
    shizuku = await ch.invokeMethod<String>('status') ?? 'notRunning';
    if (mounted) setState(() {});
    await loadApps();
    await loadBackups();
  }

  Future<void> loadApps() async {
    final l = await ch.invokeMethod<List>('listApps', showSystem) ?? [];
    apps = l
        .map((e) => AppInfo(e['name'], e['pkg'], e['version'] ?? '', e['system'], e['icon']))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (mounted) setState(() {});
  }

  Future<void> loadBackups() async {
    if (shizuku != 'ok') return;
    final r = await sh(
        'for d in ${q(root)}/*/; do [ -f "\${d}meta.json" ] && { cat "\${d}meta.json"; echo; }; done');
    final list = <Backup>[];
    for (final l in (r['out'] as String).split('\n')) {
      if (l.startsWith('{')) {
        try {
          list.add(Backup.fromJson(jsonDecode(l)));
        } catch (_) {}
      }
    }
    list.sort((a, b) => b.date.compareTo(a.date));
    backups = list;
    if (mounted) setState(() {});
  }

  void toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<bool> confirm(String title, String msg) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(title: Text(title), content: Text(msg), actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('İptal')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Eminim')),
        ]),
      ) ??
      false;

  Future<String?> ask(String init, String title) {
    final t = TextEditingController(text: init);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(title: Text(title), content: TextField(controller: t, autofocus: true), actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('İptal')),
        TextButton(
            onPressed: () => Navigator.pop(context, t.text.trim().isEmpty ? null : t.text.trim()),
            child: const Text('Tamam')),
      ]),
    );
  }

  Future<void> writeMeta(String dir, Backup b) async {
    final b64 = base64Encode(utf8.encode(jsonEncode(b.toJson())));
    await sh('echo $b64 | base64 -d > ${q(dir)}/meta.json');
  }

  // ---------- YEDEKLE ----------
  Future<void> backupFlow(AppInfo a) async {
    if (shizuku != 'ok') return toast('Önce Shizuku\'yu aç ve izin ver');
    final ex = backups.where((b) => b.pkg == a.pkg).toList();
    if (ex.isEmpty) {
      final n = await ask(a.name, 'Yedek adı');
      if (n != null) await doBackup(a, n);
      return;
    }
    final c = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(title: Text('${a.name} zaten yedekli'), children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(context, 'new'), child: const Text('Yeni adla ayrı yedek al')),
        SimpleDialogOption(onPressed: () => Navigator.pop(context, 'rep'), child: const Text('Eskisinin yerine koy')),
        SimpleDialogOption(onPressed: () => Navigator.pop(context), child: const Text('İptal')),
      ]),
    );
    if (c == 'new') {
      final n = await ask('${a.name} 2', 'Yeni yedek adı');
      if (n != null) await doBackup(a, n);
    } else if (c == 'rep') {
      await doBackup(a, ex.first.name, replace: ex.first);
    }
  }

  Future<void> doBackup(AppInfo a, String name, {Backup? replace}) async {
    setState(() => busy = '${a.name} yedekleniyor...');
    try {
      final id = '${a.pkg}_${DateTime.now().millisecondsSinceEpoch}';
      final d = '$root/$id', p = a.pkg;
      final r = await sh('''
mkdir -p ${q(d)}/apk || exit 1
for f in \$(pm path $p | sed 's/^package://'); do cp "\$f" ${q(d)}/apk/ || exit 2; done
[ -d /sdcard/Android/data/$p ] && { cp -r /sdcard/Android/data/$p ${q(d)}/data || exit 3; }
[ -d /sdcard/Android/obb/$p ] && { cp -r /sdcard/Android/obb/$p ${q(d)}/obb || exit 4; }
exit 0
''');
      if (r['code'] != 0) {
        await sh('rm -rf ${q(d)}');
        toast('Yedekleme başarısız (${r['code']}): ${r['out']}');
        return;
      }
      final du = await sh('du -sk ${q(d)} | cut -f1');
      final b = Backup(id, name, p, a.version, DateTime.now().toIso8601String(),
          int.tryParse((du['out'] as String).trim()) ?? 0, a.icon);
      await writeMeta(d, b);
      if (replace != null) await sh('rm -rf ${q('$root/${replace.id}')}');
      toast('$name yedeklendi');
    } finally {
      setState(() => busy = null);
      await loadBackups();
    }
  }

  // ---------- GERI YUKLE ----------
  Future<void> restore(Backup b) async {
    if (shizuku != 'ok') return toast('Önce Shizuku\'yu aç ve izin ver');
    final installed = await ch.invokeMethod<bool>('isInstalled', b.pkg) ?? false;
    if (installed) {
      final ok = await confirm('Emin misin?',
          '${b.name} şu an yüklü. Devam edersen yüklü olan silinecek ve yerine yedekteki sürüm (${b.version}) yüklenecek.');
      if (!ok) return;
    }
    setState(() => busy = '${b.name} geri yükleniyor...');
    try {
      final d = '$root/${b.id}', p = b.pkg;
      final r = await sh('''
pm uninstall $p >/dev/null 2>&1
n=\$(ls ${q(d)}/apk/*.apk | wc -l)
if [ "\$n" = "1" ]; then
  out=\$(pm install -r -d -i com.android.vending ${q(d)}/apk/*.apk 2>&1)
else
  sid=\$(pm install-create -r -d -i com.android.vending 2>&1 | grep -o '[0-9][0-9]*' | head -n1)
  [ -n "\$sid" ] || { echo "oturum acilamadi"; exit 8; }
  i=0
  for f in ${q(d)}/apk/*.apk; do
    sz=\$(wc -c < "\$f")
    pm install-write -S \$sz \$sid "\$i.apk" "\$f" >/dev/null 2>&1 || { echo "yazilamadi: \$f"; exit 9; }
    i=\$((i+1))
  done
  out=\$(pm install-commit \$sid 2>&1)
fi
echo "\$out"
case "\$out" in *Success*) ;; *) exit 5;; esac
rm -rf /sdcard/Android/data/$p /sdcard/Android/obb/$p
[ -d ${q(d)}/data ] && { cp -r ${q(d)}/data /sdcard/Android/data/$p || exit 6; }
[ -d ${q(d)}/obb ] && { cp -r ${q(d)}/obb /sdcard/Android/obb/$p || exit 7; }
exit 0
''');
      toast(r['code'] == 0 ? '${b.name} geri yüklendi' : 'Geri yükleme başarısız (${r['code']}): ${r['out']}');
    } finally {
      setState(() => busy = null);
      await loadApps();
    }
  }

  Future<void> rename(Backup b) async {
    final n = await ask(b.name, 'Yeni ad');
    if (n == null) return;
    b.name = n;
    await writeMeta('$root/${b.id}', b);
    setState(() {});
  }

  Future<void> delete(Backup b) async {
    if (!await confirm('Yedek silinsin mi?', '${b.name} yedeği kalıcı olarak silinecek.')) return;
    await sh('rm -rf ${q('$root/${b.id}')}');
    await loadBackups();
  }

  // ---------- ARAYUZ ----------
  Widget wallWidget(String id) {
    if (id.startsWith('g')) {
      return DecoratedBox(
          decoration: BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: grads[int.parse(id.substring(1))])));
    }
    if (id == 'asset') return Image.asset('assets/wall.jpg', fit: BoxFit.cover);
    return Image.file(File(id.substring(2)),
        fit: BoxFit.cover, errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black));
  }

  Widget ico(Uint8List? i) => ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: i == null
          ? const SizedBox(width: 42, height: 42, child: Icon(Icons.android))
          : Image.memory(i, width: 42, height: 42));

  Widget banner() {
    if (shizuku == 'ok' || shizuku == 'checking') return const SizedBox.shrink();
    final perm = shizuku == 'noPermission';
    return Card(
      color: const Color(0xCC5A0A12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Text(perm
              ? 'Shizuku çalışıyor ama bu uygulamaya izin verilmemiş.'
              : 'Shizuku kapalı. Shizuku\'yu aç, "Kablosuz hata ayıklama" ile başlat, sonra tekrar dene.'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            if (perm)
              FilledButton(
                  onPressed: () async {
                    await ch.invokeMethod('requestPermission');
                    await checkShizuku();
                  },
                  child: const Text('İzin ver')),
            if (!perm)
              OutlinedButton(onPressed: () => ch.invokeMethod('openShizuku'), child: const Text('Shizuku\'yu aç')),
            OutlinedButton(onPressed: checkShizuku, child: const Text('Tekrar dene')),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = query.toLowerCase();
    final done = {for (final b in backups) b.pkg};
    final avail = apps.where((a) => a.name.toLowerCase().contains(s) || a.pkg.contains(s)).toList();
    final bl = backups.where((b) => b.name.toLowerCase().contains(s)).toList();
    return DefaultTabController(
      length: 2,
      child: Stack(children: [
        Positioned.fill(child: wallWidget(wall)),
        const Positioned.fill(child: ColoredBox(color: Color(0x8C000000))),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: const Color(0x99120508),
            title: const Text('Alpy Yedekleme', style: TextStyle(color: red)),
            actions: [IconButton(icon: const Icon(Icons.settings), onPressed: openSettings)],
            bottom: const TabBar(indicatorColor: red, labelColor: red, tabs: [
              Tab(text: 'Yedeklenenler'),
              Tab(text: 'Yedeklenebilir'),
            ]),
          ),
          body: Column(children: [
            banner(),
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                onChanged: (v) => setState(() => query = v),
                decoration: InputDecoration(
                    hintText: 'Ara...',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: const Color(0x99000000),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)),
              ),
            ),
            Expanded(
              child: TabBarView(children: [
                bl.isEmpty
                    ? const Center(child: Text('Henüz yedek yok'))
                    : ListView(children: [
                        for (final b in bl)
                          ListTile(
                            leading: ico(b.icon),
                            title: Text(b.name),
                            subtitle: Text(
                                '${b.version} • ${fmtKb(b.sizeKb)}\n${b.date.length >= 16 ? b.date.substring(0, 16).replaceFirst('T', ' ') : b.date}'),
                            isThreeLine: true,
                            onTap: () => restore(b),
                            trailing: PopupMenuButton<String>(
                              onSelected: (v) => v == 'r' ? restore(b) : v == 'n' ? rename(b) : delete(b),
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'r', child: Text('Geri yükle')),
                                PopupMenuItem(value: 'n', child: Text('Adını değiştir')),
                                PopupMenuItem(value: 'd', child: Text('Sil')),
                              ],
                            ),
                          ),
                      ]),
                ListView(children: [
                  for (final a in avail)
                    ListTile(
                      leading: ico(a.icon),
                      title: Text(a.name),
                      subtitle: Text('${a.pkg}\n${a.version}'),
                      isThreeLine: true,
                      trailing: done.contains(a.pkg) ? const Icon(Icons.check_circle, color: red) : null,
                      onTap: () => backupFlow(a),
                    ),
                ]),
              ]),
            ),
          ]),
        ),
        if (busy != null)
          Positioned.fill(
            child: ColoredBox(
              color: const Color(0xCC000000),
              child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(color: red),
                const SizedBox(height: 16),
                Text(busy!, style: const TextStyle(fontSize: 16, decoration: TextDecoration.none)),
              ])),
            ),
          ),
      ]),
    );
  }

  void openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E0A0D),
      builder: (_) => StatefulBuilder(builder: (ctx, setS) {
        final walls = ['g0', 'g1', 'g2', 'g3', 'asset', ...customWalls.map((p) => 'f:$p')];
        return Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Yedek konumu', style: TextStyle(color: red, fontSize: 16)),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(root),
                subtitle: const Text('Değiştirmek için dokun'),
                onTap: () async {
                  final p = await FilePicker.platform.getDirectoryPath();
                  if (p != null) {
                    root = p.replaceFirst('/storage/emulated/0', '/sdcard');
                    await sp!.setString('root', root);
                    setS(() {});
                    loadBackups();
                  }
                },
                trailing: IconButton(
                    icon: const Icon(Icons.restore),
                    onPressed: () async {
                      root = defRoot;
                      await sp!.setString('root', root);
                      setS(() {});
                      loadBackups();
                    }),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sistem uygulamalarını göster'),
                value: showSystem,
                activeColor: red,
                onChanged: (v) async {
                  showSystem = v;
                  await sp!.setBool('sys', v);
                  setS(() {});
                  loadApps();
                },
              ),
              const SizedBox(height: 8),
              const Text('Arka plan', style: TextStyle(color: red, fontSize: 16)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final w in walls)
                  GestureDetector(
                    onTap: () async {
                      wall = w;
                      await sp!.setString('wall', w);
                      setState(() {});
                      setS(() {});
                    },
                    onLongPress: () async {
                      if (!w.startsWith('f:')) return;
                      customWalls.remove(w.substring(2));
                      await sp!.setStringList('walls', customWalls);
                      if (wall == w) wall = 'g0';
                      setState(() {});
                      setS(() {});
                    },
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                          border: Border.all(color: wall == w ? red : Colors.white24, width: wall == w ? 3 : 1),
                          borderRadius: BorderRadius.circular(8)),
                      child: ClipRRect(borderRadius: BorderRadius.circular(6), child: wallWidget(w)),
                    ),
                  ),
                GestureDetector(
                  onTap: () async {
                    final r = await FilePicker.platform.pickFiles(type: FileType.image);
                    final path = r?.files.single.path;
                    if (path == null) return;
                    final dir = await getApplicationDocumentsDirectory();
                    final f = await File(path).copy('${dir.path}/wall_${DateTime.now().millisecondsSinceEpoch}.jpg');
                    customWalls.add(f.path);
                    await sp!.setStringList('walls', customWalls);
                    wall = 'f:${f.path}';
                    await sp!.setString('wall', wall);
                    setState(() {});
                    setS(() {});
                  },
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(border: Border.all(color: red), borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.add, color: red),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
        
