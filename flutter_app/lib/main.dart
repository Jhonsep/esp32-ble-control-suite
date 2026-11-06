import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Esp32BleApp());
}

class Esp32BleApp extends StatefulWidget {
  const Esp32BleApp({super.key});

  @override
  State<Esp32BleApp> createState() => _Esp32BleAppState();
}

class _Esp32BleAppState extends State<Esp32BleApp> {
  ThemeMode _themeMode = ThemeMode.system;

  void _toggleTheme(bool currentlyDark) {
    setState(() {
      _themeMode = currentlyDark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 BLE Control',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        colorSchemeSeed: Colors.lightBlue,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.lightBlue,
        scaffoldBackgroundColor: const Color(0xFF090D16),
        useMaterial3: true,
      ),
      home: ControlHomeScreen(onToggleTheme: _toggleTheme),
    );
  }
}

class ControlHomeScreen extends StatefulWidget {
  final void Function(bool currentlyDark) onToggleTheme;
  const ControlHomeScreen({super.key, required this.onToggleTheme});

  @override
  State<ControlHomeScreen> createState() => _ControlHomeScreenState();
}

class _ControlHomeScreenState extends State<ControlHomeScreen> {
  static const String nusServiceUuid = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  static const String nusRxUuid = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
  static const String nusTxUuid = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _rxChar;
  StreamSubscription<List<int>>? _txSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  String? _lastDeviceId;
  String _lastDeviceName = "Sin conectar";

  bool _editMode = false;
  bool _showBadges = false;
  String _currentProfileKey = 'pantalla';
  final List<String> _consoleLogs = [
    '[SYS] Listo. Usa ⚡ para conexión rápida o 📡 para buscar ESP32 BLE.'
  ];
  final TextEditingController _customCmdCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  Map<String, Map<String, dynamic>> _profiles = {
    'pantalla': {
      'name': '📺 Pantalla Móvil (P1-P4)',
      'builtin': true,
      'labels': {
        '1': 'Jog +',
        '2': 'Jog ESTE',
        '3': 'Jog OESTE',
        '4': 'Jog -',
        '5': '➕ AUTO',
        '6': '➖ AUX',
        '7': '🛑 STOP',
        '8': '💾 SAVE',
        '9': '▶️ PLAY',
        '10': 'P1 • ESTE',
        '11': 'P2',
        '12': 'P3',
        '13': 'P4 • OESTE',
      }
    },
    'servo': {
      'name': '⚙️ Debug Servo / Motor',
      'builtin': true,
      'labels': {
        '1': 'Tilt +10°',
        '2': 'Pan -10°',
        '3': 'Pan +10°',
        '4': 'Tilt -10°',
        '5': '➕ Vel +',
        '6': '➖ Vel -',
        '7': '🛑 STOP',
        '8': '💾 Guardar',
        '9': '▶️ Secuencia',
        '10': '0° Home',
        '11': '45°',
        '12': '90°',
        '13': '180°',
      }
    },
    'generico': {
      'name': '🔢 Genérico (App Inventor)',
      'builtin': true,
      'labels': {
        '1': 'Arriba',
        '2': 'Izquierda',
        '3': 'Derecha',
        '4': 'Abajo',
        '5': '➕ PLUS',
        '6': '➖ MINUS',
        '7': '🛑 STOP',
        '8': '💾 SAVE',
        '9': '▶️ PLAY',
        '10': 'OPTION 1',
        '11': 'OPTION 2',
        '12': 'OPTION 3',
        '13': 'OPTION 4',
      }
    }
  };

  @override
  void initState() {
    super.initState();
    _loadSavedState();
    _requestBlePermissions();
  }

  Future<void> _requestBlePermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
    }
  }

  Future<void> _loadSavedState() async {
    final prefs = await SharedPreferences.getInstance();
    final savedProfiles = prefs.getString('esp32_ble_profiles');
    if (savedProfiles != null) {
      final decoded = jsonDecode(savedProfiles) as Map<String, dynamic>;
      setState(() {
        _profiles = decoded.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v)));
      });
    }
    setState(() {
      _lastDeviceId = prefs.getString('last_ble_id');
      _lastDeviceName = prefs.getString('last_ble_name') ?? "Sin conectar";
      final savedProf = prefs.getString('last_profile');
      if (savedProf != null && _profiles.containsKey(savedProf)) {
        _currentProfileKey = savedProf;
      }
    });
  }

  Future<void> _saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('esp32_ble_profiles', jsonEncode(_profiles));
  }

  void _log(String tag, String msg) {
    setState(() {
      _consoleLogs.add('[$tag] $msg');
    });
    Future.delayed(const Duration(milliseconds: 50), () {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      _log('BLE', 'Conectando a ${device.platformName}...');
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 8));
      _connSub?.cancel();
      _connSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            _connectedDevice = null;
            _rxChar = null;
          });
          _log('BLE', 'Dispositivo desconectado. Toca ⚡ para reconectar.');
        }
      });

      final services = await device.discoverServices();
      for (final s in services) {
        if (s.uuid.toString().toLowerCase() == nusServiceUuid) {
          for (final c in s.characteristics) {
            final cuuid = c.uuid.toString().toLowerCase();
            if (cuuid == nusRxUuid) {
              _rxChar = c;
            } else if (cuuid == nusTxUuid) {
              await c.setNotifyValue(true);
              _txSub?.cancel();
              _txSub = c.onValueReceived.listen((bytes) {
                final text = utf8.decode(bytes, allowMalformed: true).trim();
                if (text.isNotEmpty) {
                  for (final line in text.split('\n')) {
                    if (line.trim().isNotEmpty) _log('RX', line.trim());
                  }
                }
              });
            }
          }
        }
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_ble_id', device.remoteId.str);
      await prefs.setString('last_ble_name', device.platformName);

      setState(() {
        _connectedDevice = device;
        _lastDeviceId = device.remoteId.str;
        _lastDeviceName = device.platformName.isNotEmpty ? device.platformName : 'ESP32 BLE';
      });
      _log('BLE', 'Conectado exitosamente a $_lastDeviceName');
    } catch (e) {
      _log('ERR', 'No se pudo conectar: $e');
    }
  }

  Future<void> _quickReconnect() async {
    if (_connectedDevice != null) {
      _log('BLE', 'Ya estás conectado a $_lastDeviceName');
      return;
    }
    if (_lastDeviceId != null) {
      final dev = BluetoothDevice.fromId(_lastDeviceId!);
      await _connectToDevice(dev);
    } else {
      _openBleScannerModal();
    }
  }

  Future<void> _openBleScannerModal() async {
    await _requestBlePermissions();
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('📡 Dispositivos BLE Cercanos',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 260,
                  child: StreamBuilder<List<ScanResult>>(
                    stream: FlutterBluePlus.scanResults,
                    builder: (context, snapshot) {
                      final results = (snapshot.data ?? []).where((r) {
                        final name = r.device.platformName.isNotEmpty
                            ? r.device.platformName
                            : r.advertisementData.advName;
                        return name.isNotEmpty;
                      }).toList();
                      if (results.isEmpty) {
                        return const Center(child: Text('Buscando ESP32 BLE cercanos...'));
                      }
                      return ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (context, idx) {
                          final r = results[idx];
                          final devName = r.device.platformName.isNotEmpty
                              ? r.device.platformName
                              : r.advertisementData.advName;
                          return ListTile(
                            title: Text(devName,
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text('RSSI: ${r.rssi} dBm • ${r.device.remoteId.str}'),
                            trailing: FilledButton.tonal(
                              onPressed: () {
                                FlutterBluePlus.stopScan();
                                Navigator.pop(ctx);
                                _connectToDevice(r.device);
                              },
                              child: const Text('Conectar'),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() => FlutterBluePlus.stopScan());
  }

  Future<void> _handleButtonTap(int code) async {
    if (_editMode) {
      final labels = Map<String, dynamic>.from(_profiles[_currentProfileKey]!['labels']);
      final ctrl = TextEditingController(text: labels['$code']?.toString() ?? '');
      final newLabel = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Editar Botón (Envía "$code\\n")'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Nombre del botón'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('Guardar')),
          ],
        ),
      );
      if (newLabel != null && newLabel.isNotEmpty) {
        setState(() {
          _profiles[_currentProfileKey]!['labels']['$code'] = newLabel;
        });
        await _saveProfiles();
      }
      return;
    }

    HapticFeedback.lightImpact();
    final payload = '$code\n';
    if (_connectedDevice == null || _rxChar == null) {
      _log('ERR', 'No conectado (Comando "$code\\n" no enviado)');
      return;
    }
    try {
      await _rxChar!.write(utf8.encode(payload), withoutResponse: false);
      _log('TX', 'Enviado -> "$code\\n"');
    } catch (e) {
      _log('ERR', 'Error al enviar: $e');
    }
  }

  Future<void> _createNewTemplate() async {
    final ctrl = TextEditingController(text: '🤖 Nuevo Proyecto');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nueva Plantilla'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nombre de la plantilla'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Crear')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      final key = 'custom_${DateTime.now().millisecondsSinceEpoch}';
      final currentLabels =
          Map<String, dynamic>.from(_profiles[_currentProfileKey]!['labels']);
      setState(() {
        _profiles[key] = {
          'name': name,
          'builtin': false,
          'labels': currentLabels,
        };
        _currentProfileKey = key;
        _editMode = true;
      });
      await _saveProfiles();
    }
  }

  String _label(int code) {
    final labels = _profiles[_currentProfileKey]?['labels'] as Map?;
    return labels?['$code']?.toString() ?? 'Cmd $code';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final connected = _connectedDevice != null;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  // TOP BAR: Status | Quick Connect + BLE Scan | Separator | Theme Toggle
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: connected ? Colors.greenAccent : Colors.redAccent,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: GestureDetector(
                            onTap: _openBleScannerModal,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  connected ? _lastDeviceName : '$_lastDeviceName (Off)',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, fontSize: 13),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  connected
                                      ? 'Conectado por BLE'
                                      : 'Toca ⚡ Rápida o 📡 BLE',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(context).colorScheme.outline),
                                ),
                              ],
                            ),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _quickReconnect,
                          icon: const Text('⚡'),
                          label: const Text('Rápida', style: TextStyle(fontSize: 12)),
                        ),
                        const SizedBox(width: 6),
                        OutlinedButton.icon(
                          onPressed: _openBleScannerModal,
                          icon: const Text('📡'),
                          label: const Text('BLE', style: TextStyle(fontSize: 12)),
                        ),
                        Container(
                          height: 24,
                          width: 1,
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          color: Theme.of(context).dividerColor,
                        ),
                        IconButton.outlined(
                          onPressed: () => widget.onToggleTheme(isDark),
                          icon: Text(isDark ? '🌙' : '☀️'),
                          tooltip: 'Cambiar Modo Claro / Oscuro',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // PROFILE BAR
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _currentProfileKey,
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(),
                          ),
                          items: _profiles.entries
                              .map((e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(e.value['name'].toString(),
                                        style: const TextStyle(fontSize: 13)),
                                  ))
                              .toList(),
                          onChanged: (val) {
                            if (val != null) setState(() => _currentProfileKey = val);
                          },
                        ),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton(
                        onPressed: () => setState(() => _editMode = !_editMode),
                        child: Text(_editMode ? '✅ Listo' : '✏️ Editar',
                            style: const TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 6),
                      FilledButton.tonal(
                        onPressed: _createNewTemplate,
                        child: const Text('+ Plantilla', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // OPTIONS 1..4 (10\n .. 13\n)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('OPCIONES / POSICIONES (10\\n - 13\\n)',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      GestureDetector(
                        onTap: () => setState(() => _showBadges = !_showBadges),
                        child: Text(
                          _showBadges ? 'Ocultar códigos' : 'Mostrar códigos',
                          style: const TextStyle(fontSize: 11, color: Colors.lightBlue),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [10, 11, 12, 13]
                        .map((code) => Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 3),
                                child: _buildCtrlButton(code,
                                    sub: 'Option ${code - 9}', height: 54),
                              ),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 10),

                  // D-PAD + ACTION BUTTONS + CENTER STOP
                  Row(
                    children: [
                      Expanded(child: _buildCtrlButton(5, sub: 'Plus', height: 60)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _buildCtrlButton(1,
                              icon: '▲', primary: true, height: 64)),
                      const SizedBox(width: 8),
                      Expanded(child: _buildCtrlButton(6, sub: 'Minus', height: 60)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                          child: _buildCtrlButton(2,
                              icon: '◀', primary: true, height: 64)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _buildCtrlButton(7,
                              sub: 'Emergencia', danger: true, height: 64)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _buildCtrlButton(3,
                              icon: '▶', primary: true, height: 64)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: _buildCtrlButton(8, sub: 'Save', height: 60)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _buildCtrlButton(4,
                              icon: '▼', primary: true, height: 64)),
                      const SizedBox(width: 8),
                      Expanded(child: _buildCtrlButton(9, sub: 'Play', height: 60)),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // LIVE SERIAL CONSOLE
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Theme.of(context).dividerColor),
                      ),
                      child: Column(
                        children: [
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('💻 Monitor Serial BLE',
                                    style: TextStyle(
                                        fontSize: 11, fontWeight: FontWeight.bold)),
                                GestureDetector(
                                  onTap: () => setState(() => _consoleLogs.clear()),
                                  child: const Text('Limpiar',
                                      style: TextStyle(fontSize: 11)),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: ListView.builder(
                              controller: _scrollCtrl,
                              padding: const EdgeInsets.all(8),
                              itemCount: _consoleLogs.length,
                              itemBuilder: (ctx, i) => Text(
                                _consoleLogs[i],
                                style: const TextStyle(
                                    fontFamily: 'monospace', fontSize: 11),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(6),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _customCmdCtrl,
                                    decoration: const InputDecoration(
                                      hintText: 'Enviar comando libre (ej. 10)...',
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 8),
                                      border: OutlineInputBorder(),
                                    ),
                                    onSubmitted: (v) {
                                      final n = int.tryParse(v.trim());
                                      if (n != null) {
                                        _customCmdCtrl.clear();
                                        _handleButtonTap(n);
                                      }
                                    },
                                  ),
                                ),
                                const SizedBox(width: 6),
                                FilledButton(
                                  onPressed: () {
                                    final n =
                                        int.tryParse(_customCmdCtrl.text.trim());
                                    if (n != null) {
                                      _customCmdCtrl.clear();
                                      _handleButtonTap(n);
                                    }
                                  },
                                  child: const Text('Enviar'),
                                ),
                              ],
                            ),
                          )
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCtrlButton(
    int code, {
    String? icon,
    String? sub,
    bool primary = false,
    bool danger = false,
    double height = 60,
  }) {
    final bgColor = danger
        ? Colors.red.shade600
        : primary
            ? Colors.lightBlue.withOpacity(0.18)
            : Theme.of(context).colorScheme.surfaceContainerHighest;

    return SizedBox(
      height: height,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _handleButtonTap(code),
        child: Container(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: danger
                  ? Colors.redAccent
                  : primary
                      ? Colors.lightBlue.withOpacity(0.5)
                      : Theme.of(context).dividerColor,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null)
                    Text(icon,
                        style: const TextStyle(fontSize: 16, height: 1.0)),
                  Text(
                    _label(code),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: danger ? Colors.white : null,
                    ),
                  ),
                  if (sub != null)
                    Text(
                      sub,
                      style: TextStyle(
                        fontSize: 10,
                        color: danger
                            ? Colors.white70
                            : Theme.of(context).colorScheme.outline,
                      ),
                    ),
                ],
              ),
              if (_showBadges)
                Positioned(
                  top: 3,
                  right: 5,
                  child: Text(
                    '$code\\n',
                    style: const TextStyle(
                        fontSize: 9,
                        fontFamily: 'monospace',
                        color: Colors.lightBlueAccent),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
