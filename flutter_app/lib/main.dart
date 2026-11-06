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
  ThemeMode _themeMode = ThemeMode.dark;

  void _toggleTheme(bool currentlyDark) {
    setState(() {
      _themeMode = currentlyDark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 Control Suite',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
        colorSchemeSeed: const Color(0xFF0EA5E9),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF090D16),
        colorSchemeSeed: const Color(0xFF38BDF8),
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
  static const MethodChannel _classicBtChannel =
      MethodChannel('esp32_control/classic_bt');

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _rxChar;
  bool _connectedClassic = false;
  String? _lastClassicAddress;
  StreamSubscription<List<int>>? _txSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  String? _lastDeviceId;
  String _lastDeviceName = "Sin conectar";

  bool _editMode = false;
  bool _showBadges = false;
  String _currentProfileKey = 'pantalla';
  final List<String> _consoleLogs = [
    '[SYS] Listo. Usa ⚡ Rápida o 📡 BT/BLE para conectar.'
  ];
  final TextEditingController _customCmdCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  Map<String, Map<String, dynamic>> _profiles = {
    'pantalla': {
      'name': '📺 Pantalla Nueva (Options = P1-P4)',
      'builtin': true,
      'labels': {
        '1': 'Jog +',
        '2': 'Jog ESTE',
        '3': 'Jog OESTE',
        '4': 'Jog -',
        '5': 'AUTO RGB',
        '6': 'AUX',
        '7': 'STOP',
        '8': 'SAVE',
        '9': 'PLAY',
        '10': 'P1 • ESTE',
        '11': 'P2',
        '12': 'P3',
        '13': 'P4 • OESTE',
      }
    },
    'legado': {
      'name': '🕹️ Código Viejo (Flechas = P1-P4)',
      'builtin': true,
      'labels': {
        '1': 'P1 • ESTE',
        '2': 'P2',
        '3': 'P3',
        '4': 'P4 • OESTE',
        '5': 'AUTO RGB',
        '6': 'MINUS',
        '7': 'STOP',
        '8': 'SAVE',
        '9': 'PLAY',
        '10': 'OPTION 1',
        '11': 'OPTION 2',
        '12': 'OPTION 3',
        '13': 'OPTION 4',
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
        '5': 'Vel +',
        '6': 'Vel -',
        '7': 'STOP',
        '8': 'Guardar',
        '9': 'Secuencia',
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
        '5': 'PLUS',
        '6': 'MINUS',
        '7': 'STOP',
        '8': 'SAVE',
        '9': 'PLAY',
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
    final savedProfiles = prefs.getString('esp32_ble_profiles_v2');
    if (savedProfiles != null) {
      final decoded = jsonDecode(savedProfiles) as Map<String, dynamic>;
      setState(() {
        _profiles =
            decoded.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v)));
      });
    }
    setState(() {
      _lastDeviceId = prefs.getString('last_ble_id');
      _lastClassicAddress = prefs.getString('last_classic_addr');
      _lastDeviceName = prefs.getString('last_ble_name') ?? "Sin conectar";
      final savedProf = prefs.getString('last_profile');
      if (savedProf != null && _profiles.containsKey(savedProf)) {
        _currentProfileKey = savedProf;
      }
    });
  }

  Future<void> _saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('esp32_ble_profiles_v2', jsonEncode(_profiles));
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

  Future<void> _connectClassicBt(String name, String address) async {
    try {
      _log('BT', 'Conectando por BT Clásico a $name...');
      final ok = await _classicBtChannel
          .invokeMethod<bool>('connect', {'address': address});
      if (ok == true) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_classic_addr', address);
        await prefs.setString('last_ble_name', name);
        setState(() {
          _connectedClassic = true;
          _connectedDevice = null;
          _lastClassicAddress = address;
          _lastDeviceName = name;
        });
        _log('BT', 'Conectado por BT Clásico a "$name"');
      } else {
        _log('ERR', 'No se pudo conectar con $name');
      }
    } catch (e) {
      _log('ERR', 'Error BT Clásico: $e');
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      final devTitle =
          device.platformName.isNotEmpty ? device.platformName : 'ESP32 BLE';
      _log('BLE', 'Conectando a $devTitle...');
      await device.connect(
          autoConnect: false, timeout: const Duration(seconds: 8));
      _connSub?.cancel();
      _connSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            _connectedDevice = null;
            _rxChar = null;
          });
          _log('BLE', 'Desconectado. Toca ⚡ para reconectar.');
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
      await prefs.setString('last_ble_name', devTitle);

      setState(() {
        _connectedDevice = device;
        _connectedClassic = false;
        _lastDeviceId = device.remoteId.str;
        _lastDeviceName = devTitle;
      });
      _log('BLE', 'Conectado exitosamente a $_lastDeviceName');
    } catch (e) {
      _log('ERR', 'No se pudo conectar: $e');
    }
  }

  Future<void> _quickReconnect() async {
    if (_connectedDevice != null || _connectedClassic) {
      _log('BT', 'Ya estás conectado a $_lastDeviceName');
      return;
    }
    if (_lastClassicAddress != null && Platform.isAndroid) {
      await _connectClassicBt(_lastDeviceName, _lastClassicAddress!);
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
    List<Map<String, String>> bondedClassic = [];
    if (Platform.isAndroid) {
      try {
        final raw =
            await _classicBtChannel.invokeMethod<List>('getBondedDevices');
        if (raw != null) {
          bondedClassic =
              raw.map((e) => Map<String, String>.from(e as Map)).toList();
        }
      } catch (_) {}
    }

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (bondedClassic.isNotEmpty) ...[
                  const Text(
                      '🔗 Bluetooth Clásico Vinculados (Código Viejo ESP32)',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 150,
                    child: ListView.builder(
                      itemCount: bondedClassic.length,
                      itemBuilder: (context, idx) {
                        final b = bondedClassic[idx];
                        return ListTile(
                          dense: true,
                          title: Text(b['name'] ?? 'ESP32',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle:
                              Text('MAC: ${b['address']} • BT Clásico SPP'),
                          trailing: FilledButton(
                            onPressed: () {
                              FlutterBluePlus.stopScan();
                              Navigator.pop(ctx);
                              _connectClassicBt(
                                  b['name'] ?? 'ESP32', b['address'] ?? '');
                            },
                            child: const Text('Conectar'),
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(),
                ],
                const Text('📡 Dispositivos BLE Cercanos (Código Nuevo ESP32)',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 4),
                SizedBox(
                  height: 180,
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
                        return const Center(
                            child: Text('Buscando ESP32 BLE cercanos...'));
                      }
                      return ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (context, idx) {
                          final r = results[idx];
                          final devName = r.device.platformName.isNotEmpty
                              ? r.device.platformName
                              : r.advertisementData.advName;
                          return ListTile(
                            dense: true,
                            title: Text(devName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            subtitle: Text(
                                'RSSI: ${r.rssi} dBm • ${r.device.remoteId.str}'),
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
      final labels =
          Map<String, dynamic>.from(_profiles[_currentProfileKey]!['labels']);
      final ctrl =
          TextEditingController(text: labels['$code']?.toString() ?? '');
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
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar')),
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
    if (_connectedClassic) {
      try {
        final ok = await _classicBtChannel
            .invokeMethod<bool>('write', {'data': payload});
        if (ok == true) {
          _log('TX', '[BT Clásico] -> "$code\\n"');
        } else {
          setState(() => _connectedClassic = false);
          _log('ERR', 'Conexión BT Clásico perdida');
        }
      } catch (e) {
        _log('ERR', 'Error al enviar: $e');
      }
      return;
    }
    if (_connectedDevice == null || _rxChar == null) {
      _log('ERR', 'No conectado (Comando "$code\\n" no enviado)');
      return;
    }
    try {
      await _rxChar!.write(utf8.encode(payload), withoutResponse: false);
      _log('TX', '[BLE] -> "$code\\n"');
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
          decoration:
              const InputDecoration(labelText: 'Nombre de la plantilla'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
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
    final connected = _connectedDevice != null || _connectedClassic;

    // Paleta de alto contraste tanto en Modo Oscuro como en Modo Claro
    final cardColor = isDark ? const Color(0xFF111827) : Colors.white;
    final surfaceColor =
        isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final btnSurfaceColor =
        isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
    final borderColor =
        isDark ? const Color(0xFF334155) : const Color(0xFF94A3B8);
    final textMainColor =
        isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A);
    final mutedColor =
        isDark ? const Color(0xFF94A3B8) : const Color(0xFF334155);

    final accentBlue =
        isDark ? const Color(0xFF38BDF8) : const Color(0xFF0369A1);
    final accentGreen =
        isDark ? const Color(0xFF34D399) : const Color(0xFF047857);
    final accentRed =
        isDark ? const Color(0xFFFB7185) : const Color(0xFFBE123C);
    final accentAmber =
        isDark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Altura adaptativa para que todos los botones y la consola encajen sin desbordar
            final h = constraints.maxHeight;
            final compact = h < 700;
            final optBtnHeight = compact ? 48.0 : 54.0;
            final padBtnHeight = compact ? 54.0 : 62.0;
            final auxBtnHeight = compact ? 50.0 : 58.0;

            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: borderColor),
                  ),
                  child: Column(
                    children: [
                      // ==================== 1. TOP BAR RESPONSIVE ====================
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: surfaceColor,
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(23)),
                          border: Border(
                              bottom: BorderSide(color: borderColor, width: 1)),
                        ),
                        child: Row(
                          children: [
                            // Indicador y nombre del dispositivo con buen espacio
                            Expanded(
                              child: InkWell(
                                onTap: _openBleScannerModal,
                                borderRadius: BorderRadius.circular(10),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: connected
                                            ? const Color(0xFF10B981)
                                            : const Color(0xFFF43F5E),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  _lastDeviceName,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 14,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: connected
                                                      ? const Color(0xFF10B981)
                                                          .withOpacity(isDark ? 0.18 : 0.22)
                                                      : const Color(0xFFF43F5E)
                                                          .withOpacity(isDark ? 0.18 : 0.22),
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                                child: Text(
                                                  connected
                                                      ? (_connectedClassic
                                                          ? 'BT'
                                                          : 'BLE')
                                                      : 'Off',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                    color: connected
                                                        ? accentGreen
                                                        : accentRed,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          Text(
                                            connected
                                                ? 'Conectado • Toca para cambiar'
                                                : 'Toca ⚡ o 📡 para conectar',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: mutedColor),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),

                            // Botón Conexión Rápida compacto
                            _buildTopPillButton(
                              onTap: _quickReconnect,
                              icon: Icons.bolt_rounded,
                              iconColor: accentGreen,
                              label: 'Rápida',
                              bgColor: const Color(0xFF10B981)
                                  .withOpacity(isDark ? 0.12 : 0.18),
                              borderColor: accentGreen.withOpacity(0.55),
                            ),
                            const SizedBox(width: 6),

                            // Botón Buscar BLE/BT compacto
                            _buildTopPillButton(
                              onTap: _openBleScannerModal,
                              icon: Icons.bluetooth_searching_rounded,
                              iconColor: accentBlue,
                              label: 'BLE',
                              bgColor: cardColor,
                              borderColor: borderColor,
                            ),

                            // Separador vertical
                            Container(
                              height: 22,
                              width: 1,
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              color: borderColor,
                            ),

                            // Botón Modo Nocturno / Claro a la derecha
                            InkWell(
                              onTap: () => widget.onToggleTheme(isDark),
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.all(7),
                                decoration: BoxDecoration(
                                  color: cardColor,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: borderColor),
                                ),
                                child: Icon(
                                  isDark
                                      ? Icons.dark_mode_rounded
                                      : Icons.light_mode_rounded,
                                  size: 18,
                                  color: accentAmber,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // ==================== 2. BARRA DE PLANTILLAS (SIN OVERFLOW) ====================
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          border: Border(
                              bottom: BorderSide(color: borderColor, width: 1)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Container(
                                height: 36,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
                                decoration: BoxDecoration(
                                  color: btnSurfaceColor,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: borderColor),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    value: _currentProfileKey,
                                    isExpanded: true, // Evita el desborde de texto
                                    isDense: true,
                                    icon: Icon(Icons.expand_more_rounded,
                                        size: 18, color: mutedColor),
                                    items: _profiles.entries
                                        .map((e) => DropdownMenuItem(
                                              value: e.key,
                                              child: Text(
                                                e.value['name'].toString(),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color: textMainColor,
                                                    fontWeight:
                                                        FontWeight.w600),
                                              ),
                                            ))
                                        .toList(),
                                    onChanged: (val) async {
                                      if (val != null) {
                                        setState(
                                            () => _currentProfileKey = val);
                                        final prefs = await SharedPreferences
                                            .getInstance();
                                        await prefs.setString(
                                            'last_profile', val);
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            _buildTopPillButton(
                              onTap: () =>
                                  setState(() => _editMode = !_editMode),
                              icon: _editMode
                                  ? Icons.check_circle_rounded
                                  : Icons.edit_rounded,
                              iconColor: _editMode ? accentGreen : mutedColor,
                              label: _editMode ? 'Listo' : 'Editar',
                              bgColor: btnSurfaceColor,
                              borderColor:
                                  _editMode ? accentGreen : borderColor,
                            ),
                            const SizedBox(width: 6),
                            _buildTopPillButton(
                              onTap: _createNewTemplate,
                              icon: Icons.add_rounded,
                              iconColor: accentBlue,
                              label: 'Plantilla',
                              bgColor: const Color(0xFF0EA5E9)
                                  .withOpacity(isDark ? 0.12 : 0.18),
                              borderColor: accentBlue.withOpacity(0.5),
                            ),
                          ],
                        ),
                      ),

                      if (_editMode)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          color: const Color(0xFFF59E0B).withOpacity(0.18),
                          child: Text(
                            '✏️ Modo Edición: Toca cualquier botón para cambiarle el nombre.',
                            style: TextStyle(
                                fontSize: 11,
                                color: accentAmber,
                                fontWeight: FontWeight.w700),
                          ),
                        ),

                      // ==================== 3. CONTROLES PRINCIPALES ====================
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              // Cabecera Opciones 1..4
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'OPCIONES / POSICIONES (10\\n - 13\\n)',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: mutedColor,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () => setState(
                                        () => _showBadges = !_showBadges),
                                    child: Text(
                                      _showBadges
                                          ? 'Ocultar códigos'
                                          : 'Mostrar códigos',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: accentBlue,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),

                              // Fila Opciones 1..4
                              Row(
                                children: [10, 11, 12, 13]
                                    .map((code) => Expanded(
                                          child: Padding(
                                            padding: EdgeInsets.only(
                                              left: code == 10 ? 0 : 3,
                                              right: code == 13 ? 0 : 3,
                                            ),
                                            child: _buildCtrlButton(
                                              code,
                                              sub: 'Option ${code - 9}',
                                              height: optBtnHeight,
                                              isDark: isDark,
                                              surfaceColor: btnSurfaceColor,
                                              borderColor: borderColor,
                                              textMainColor: textMainColor,
                                              mutedColor: mutedColor,
                                              accentBlue: accentBlue,
                                            ),
                                          ),
                                        ))
                                    .toList(),
                              ),
                              SizedBox(height: compact ? 8 : 12),

                              // D-Pad Fila Superior: Plus (5), Arriba (1), Minus (6)
                              Row(
                                children: [
                                  Expanded(
                                    child: _buildCtrlButton(
                                      5,
                                      iconData: Icons.add_circle_outline_rounded,
                                      sub: 'Plus (5)',
                                      height: auxBtnHeight,
                                      isDark: isDark,
                                      surfaceColor: btnSurfaceColor,
                                      borderColor: borderColor,
                                      textMainColor: textMainColor,
                                      mutedColor: mutedColor,
                                      accentBlue: accentBlue,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _buildCtrlButton(
                                      1,
                                      iconData:
                                          Icons.keyboard_arrow_up_rounded,
                                      primary: true,
                                      height: padBtnHeight,
                                      isDark: isDark,
                                      surfaceColor: btnSurfaceColor,
                                      borderColor: borderColor,
                                      textMainColor: textMainColor,
                                      mutedColor: mutedColor,
                                      accentBlue: accentBlue,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _buildCtrlButton(
                                      6,
                                      iconData:
                                          Icons.remove_circle_outline_rounded,
                                      sub: 'Minus (6)',
                                      height: auxBtnHeight,
                                      isDark: isDark,
                                      surfaceColor: btnSurfaceColor,
                                      borderColor: borderColor,
                                      textMainColor: textMainColor,
                                      mutedColor: mutedColor,
                                      accentBlue: accentBlue,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: compact ? 6 : 8),

                              // D-Pad Fila Central: Izq (2), STOP (7), Der (3)
                              Row(
                                children: [
                                  Expanded(
                                    child: _buildCtrlButton(
                                      2,
                                      iconData:
                                          Icons.keyboard_arrow_left_rounded,
                                      primary: true,
                                      height: padBtnHeight,
                                      isDark: isDark,
                                      surfaceColor: btnSurfaceColor,
                                      borderColor: borderColor,
                                      textMainColor: textMainColor,
                                      mutedColor: mutedColor,
                                      accentBlue: accentBlue,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _buildCtrlButton(
                                      7,
                                      iconData: Icons.pan_tool_rounded,
                                      sub: 'Emergencia',
                                      danger: true,
                                      height: padBtnHeight,
                                      isDark: isDark,
                                      surfaceColor: btnSurfaceColor,
                                      borderColor: borderColor,
                                      textMainColor: textMainColor,
                                      mutedColor: mutedColor,
                                      accentBlue: accentBlue,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _buildCtrlButton(
                                      3,
                                      iconData:
                                          Icons.keyboard_arrow_right_rounded,
                                      primary: true,
                                      height: padBtnHeight,
                                      isDark: isDark,
                                      surfaceColor: btnSurfaceColor,
                                      borderColor: borderColor,
                                      textMainColor: textMainColor,
                                      mutedColor: mutedColor,
                                      accentBlue: accentBlue,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: compact ? 6 : 8),

                              // D-Pad Fila Inferior: Save (8), Abajo (4), Play (9)
                              Row(
                                children: [
                                  Expanded(
                                    child: _buildCtrlButton(
                                      8,
                                      iconData: Icons.bookmark_border_rounded,
                                      sub: 'Save (8)',
                                      height: auxBtnHeight,
                                      isDark: isDark,
                                      surfaceColor: btnSurfaceColor,
                                      borderColor: borderColor,
                                      textMainColor: textMainColor,
                                      mutedColor: mutedColor,
                                      accentBlue: accentBlue,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _buildCtrlButton(
                                      4,
                                      iconData:
                                          Icons.keyboard_arrow_down_rounded,
                                      primary: true,
                                      height: padBtnHeight,
                                      isDark: isDark,
                                      surfaceColor: btnSurfaceColor,
                                      borderColor: borderColor,
                                      textMainColor: textMainColor,
                                      mutedColor: mutedColor,
                                      accentBlue: accentBlue,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _buildCtrlButton(
                                      9,
                                      iconData: Icons.play_arrow_rounded,
                                      sub: 'Play (9)',
                                      height: auxBtnHeight,
                                      isDark: isDark,
                                      surfaceColor: btnSurfaceColor,
                                      borderColor: borderColor,
                                      textMainColor: textMainColor,
                                      mutedColor: mutedColor,
                                      accentBlue: accentBlue,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: compact ? 8 : 12),

                              // ==================== 4. CONSOLA SERIAL ====================
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: surfaceColor,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: borderColor),
                                  ),
                                  child: Column(
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 6),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Row(
                                              children: [
                                                Icon(Icons.terminal_rounded,
                                                    size: 14, color: mutedColor),
                                                const SizedBox(width: 6),
                                                Text(
                                                  'Monitor Serial Bluetooth',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold,
                                                    color: textMainColor,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            GestureDetector(
                                              onTap: () => setState(
                                                  () => _consoleLogs.clear()),
                                              child: Text(
                                                'Limpiar',
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                    color: accentBlue),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Divider(height: 1, color: borderColor),
                                      Expanded(
                                        child: Container(
                                          width: double.infinity,
                                          color: isDark
                                              ? const Color(0xFF090D16)
                                              : const Color(0xFFF8FAFC),
                                          child: ListView.builder(
                                            controller: _scrollCtrl,
                                            padding: const EdgeInsets.all(8),
                                            itemCount: _consoleLogs.length,
                                            itemBuilder: (ctx, i) {
                                              final line = _consoleLogs[i];
                                              Color col = mutedColor;
                                              if (line.startsWith('[TX]')) {
                                                col = accentBlue;
                                              } else if (line.startsWith('[RX]') ||
                                                  line.startsWith('[BT]') ||
                                                  line.startsWith('[BLE]')) {
                                                col = accentGreen;
                                              } else if (line
                                                  .startsWith('[ERR]')) {
                                                col = accentRed;
                                              }
                                              return Padding(
                                                padding: const EdgeInsets.only(
                                                    bottom: 2),
                                                child: Text(
                                                  line,
                                                  style: TextStyle(
                                                    fontFamily: 'monospace',
                                                    fontSize: 11,
                                                    fontWeight: isDark
                                                        ? FontWeight.normal
                                                        : FontWeight.w600,
                                                    color: col,
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: cardColor,
                                          borderRadius:
                                              const BorderRadius.vertical(
                                                  bottom: Radius.circular(15)),
                                          border: Border(
                                              top: BorderSide(
                                                  color: borderColor, width: 1)),
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: SizedBox(
                                                height: 36,
                                                child: TextField(
                                                  controller: _customCmdCtrl,
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      color: textMainColor,
                                                      fontFamily: 'monospace'),
                                                  decoration: InputDecoration(
                                                    hintText:
                                                        'Comando libre (ej. 10)...',
                                                    hintStyle: TextStyle(
                                                        fontSize: 12,
                                                        color: mutedColor),
                                                    filled: true,
                                                    fillColor: btnSurfaceColor,
                                                    contentPadding:
                                                        const EdgeInsets
                                                            .symmetric(
                                                            horizontal: 10,
                                                            vertical: 0),
                                                    border: OutlineInputBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              10),
                                                      borderSide: BorderSide(
                                                          color: borderColor),
                                                    ),
                                                    enabledBorder:
                                                        OutlineInputBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              10),
                                                      borderSide: BorderSide(
                                                          color: borderColor),
                                                    ),
                                                  ),
                                                  onSubmitted: (v) {
                                                    final n =
                                                        int.tryParse(v.trim());
                                                    if (n != null) {
                                                      _customCmdCtrl.clear();
                                                      _handleButtonTap(n);
                                                    }
                                                  },
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            SizedBox(
                                              height: 36,
                                              child: FilledButton(
                                                style: FilledButton.styleFrom(
                                                  backgroundColor:
                                                      const Color(0xFF0284C7),
                                                  foregroundColor: Colors.white,
                                                  padding: const EdgeInsets
                                                      .symmetric(horizontal: 14),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            10),
                                                  ),
                                                ),
                                                onPressed: () {
                                                  final n = int.tryParse(
                                                      _customCmdCtrl.text
                                                          .trim());
                                                  if (n != null) {
                                                    _customCmdCtrl.clear();
                                                    _handleButtonTap(n);
                                                  }
                                                },
                                                child: const Text('Enviar',
                                                    style: TextStyle(
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.bold)),
                                              ),
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
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopPillButton({
    required VoidCallback onTap,
    required IconData icon,
    required Color iconColor,
    required String label,
    required Color bgColor,
    required Color borderColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: iconColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCtrlButton(
    int code, {
    IconData? iconData,
    String? sub,
    bool primary = false,
    bool danger = false,
    required double height,
    required bool isDark,
    required Color surfaceColor,
    required Color borderColor,
    required Color textMainColor,
    required Color mutedColor,
    required Color accentBlue,
  }) {
    final bgColor = danger
        ? const Color(0xFFE11D48)
        : primary
            ? (isDark
                ? const Color(0xFF0EA5E9).withOpacity(0.16)
                : const Color(0xFFE0F2FE))
            : surfaceColor;

    final bCol = danger
        ? const Color(0xFFF43F5E)
        : primary
            ? (isDark
                ? const Color(0xFF38BDF8).withOpacity(0.5)
                : const Color(0xFF0284C7))
            : borderColor;

    // En vez de superponer un recuadro gris sobre el título, mostramos el código limpio en el subtítulo o badge de alto contraste
    final subText = _showBadges
        ? (sub != null ? '$sub • $code\\n' : 'Código: $code\\n')
        : sub;

    return SizedBox(
      height: height,
      child: Material(
        color: bgColor,
        borderRadius: BorderRadius.circular(15),
        child: InkWell(
          borderRadius: BorderRadius.circular(15),
          onTap: () => _handleButtonTap(code),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: bCol, width: isDark ? 1.0 : 1.2),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (iconData != null)
                  Icon(
                    iconData,
                    size: primary ? 22 : 16,
                    color: danger
                        ? Colors.white
                        : primary
                            ? accentBlue
                            : textMainColor,
                  ),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _label(code),
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                        color: danger ? Colors.white : textMainColor,
                      ),
                    ),
                  ),
                ),
                if (subText != null && (!primary || _showBadges))
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        subText,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: _showBadges
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: danger
                              ? Colors.white
                              : _showBadges
                                  ? accentBlue
                                  : mutedColor,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
