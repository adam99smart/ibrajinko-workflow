// ====================================================================
//  Battery Monitor — Flutter App (Dual Connectivity)
//
//  Architecture:
//    1. BLE used for Wi-Fi provisioning + local fallback data/control
//    2. MQTT used for remote cloud data/control (primary when available)
//    3. DeviceService manages both channels and exposes unified state
//    4. UI is a single dashboard with connection status, gauges, toggle
//
//  File: main.dart  (single-file for simplicity)
// ====================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'dart:math' as math;

// ─────────────────────────────────────────────
//  CONSTANTS
// ─────────────────────────────────────────────
const String kDeviceName = "BatteryMonitor";

// BLE UUIDs — must match ESP32 firmware
const String kSensorServiceUUID   = "0000180f-0000-1000-8000-00805f9b34fb";
const String kVoltageCharUUID     = "00002a19-0000-1000-8000-00805f9b34fb";
const String kCurrentCharUUID     = "00002a1a-0000-1000-8000-00805f9b34fb";
const String kRelayCmdCharUUID    = "00002a1b-0000-1000-8000-00805f9b34fb";
const String kRelayStateCharUUID  = "00002a1c-0000-1000-8000-00805f9b34fb";

const String kWifiServiceUUID     = "0000181a-0000-1000-8000-00805f9b34fb";
const String kWifiSsidCharUUID    = "00002a20-0000-1000-8000-00805f9b34fb";
const String kWifiPassCharUUID    = "00002a21-0000-1000-8000-00805f9b34fb";
const String kWifiCmdCharUUID     = "00002a22-0000-1000-8000-00805f9b34fb";
const String kWifiStatusCharUUID  = "00002a23-0000-1000-8000-00805f9b34fb";

// MQTT — must match ESP32's DEVICE_ID and broker
const String kMqttBroker   = "broker.hivemq.com";
const int    kMqttPort     = 1883;
const String kDeviceId     = "bm_esp32_001";

// MQTT topics
String get topicVoltage    => "$kDeviceId/voltage";
String get topicCurrent    => "$kDeviceId/current";
String get topicRelayState => "$kDeviceId/relay/state";
String get topicRelayCmd   => "$kDeviceId/relay/cmd";
String get topicStatus     => "$kDeviceId/status";

// ─────────────────────────────────────────────
//  DATA SOURCE ENUM
// ─────────────────────────────────────────────
enum DataSource { none, ble, mqtt }

// ─────────────────────────────────────────────
//  DEVICE SERVICE (state management core)
// ─────────────────────────────────────────────
class DeviceService extends ChangeNotifier {
  // ── Public state ──
  double voltage       = 0.0;
  double current       = 0.0;
  bool   relayOn       = false;
  bool   bleConnected  = false;
  bool   mqttConnected = false;
  bool   isScanning    = false;
  bool   isConnecting  = false;
  String statusMessage = "Disconnected";
  String wifiProvStatus = "";
  DataSource activeSource = DataSource.none;

  // ── Private handles ──
  BluetoothDevice? _bleDevice;
  BluetoothCharacteristic? _voltageChar;
  BluetoothCharacteristic? _currentChar;
  BluetoothCharacteristic? _relayCmdChar;
  BluetoothCharacteristic? _relayStateChar;
  BluetoothCharacteristic? _wifiSsidChar;
  BluetoothCharacteristic? _wifiPassChar;
  BluetoothCharacteristic? _wifiCmdChar;
  BluetoothCharacteristic? _wifiStatusChar;

  MqttServerClient? _mqttClient;

  // ── Subscriptions ──
  final List<StreamSubscription> _subs = [];

  // ── Timers ──
  Timer? _mqttReconnectTimer;

  // ── Computed getters ──
  bool get isFullyConnected => bleConnected || mqttConnected;

  // ─────────────────────────────────────────
  //  PERMISSIONS
  // ─────────────────────────────────────────
  Future<bool> ensurePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    return statuses.values.every((s) => s.isGranted || s.isLimited);
  }

  // ─────────────────────────────────────────
  //  BLE: SCAN & CONNECT
  // ─────────────────────────────────────────
  Future<void> scanAndConnect() async {
    if (isScanning || isConnecting || bleConnected) return;
    if (!await ensurePermissions()) {
      _setStatus("Permissions denied");
      return;
    }
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      _setStatus("Turn on Bluetooth");
      return;
    }

    isScanning = true;
    _setStatus("Scanning…");

    late StreamSubscription sub;
    sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.platformName == kDeviceName) {
          FlutterBluePlus.stopScan();
          sub.cancel();
          _connectBLE(r.device);
          return;
        }
      }
    });
    _subs.add(sub);

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 12),
      androidUsesFineLocation: true,
    );

    if (!bleConnected && !isConnecting) {
      isScanning = false;
      _setStatus("Device not found. Tap to retry.");
    }
  }

  Future<void> _connectBLE(BluetoothDevice device) async {
    isScanning = false;
    isConnecting = true;
    _setStatus("Connecting via BLE…");

    try {
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
      _bleDevice = device;

      // Monitor disconnects
      final connSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onBLEDisconnected();
        }
      });
      _subs.add(connSub);

      await _discoverBLE(device);

      bleConnected = true;
      isConnecting = false;
      _updateSource();
      _setStatus(_statusLabel());

      // After BLE is up, also try MQTT (if ESP32 is already on Wi-Fi)
      _startMqtt();
    } catch (e) {
      isConnecting = false;
      _setStatus("BLE failed: ${e.toString().split('\n').first}");
    }
  }

  Future<void> _discoverBLE(BluetoothDevice device) async {
    final services = await device.discoverServices();

    for (final svc in services) {
      final uid = svc.uuid.toString().toLowerCase();

      if (uid == kSensorServiceUUID) {
        for (final c in svc.characteristics) {
          final cu = c.uuid.toString().toLowerCase();
          if (cu == kVoltageCharUUID) {
            _voltageChar = c;
            await c.setNotifyValue(true);
            _subs.add(c.lastValueStream.listen(_onBLEVoltage));
          } else if (cu == kCurrentCharUUID) {
            _currentChar = c;
            await c.setNotifyValue(true);
            _subs.add(c.lastValueStream.listen(_onBLECurrent));
          } else if (cu == kRelayCmdCharUUID) {
            _relayCmdChar = c;
          } else if (cu == kRelayStateCharUUID) {
            _relayStateChar = c;
            await c.setNotifyValue(true);
            _subs.add(c.lastValueStream.listen(_onBLERelayState));
            // Read initial state
            final val = await c.read();
            if (val.isNotEmpty) relayOn = val[0] == 0x01;
          }
        }
      } else if (uid == kWifiServiceUUID) {
        for (final c in svc.characteristics) {
          final cu = c.uuid.toString().toLowerCase();
          if (cu == kWifiSsidCharUUID) _wifiSsidChar = c;
          else if (cu == kWifiPassCharUUID) _wifiPassChar = c;
          else if (cu == kWifiCmdCharUUID) _wifiCmdChar = c;
          else if (cu == kWifiStatusCharUUID) {
            _wifiStatusChar = c;
            await c.setNotifyValue(true);
            _subs.add(c.lastValueStream.listen(_onBLEWifiStatus));
          }
        }
      }
    }
  }

  // ── BLE data handlers ──
  void _onBLEVoltage(List<int> data) {
    if (data.isEmpty) return;
    final v = double.tryParse(String.fromCharCodes(data).trim());
    if (v != null) {
      // Only use BLE data if MQTT is not active (cloud is preferred)
      if (activeSource != DataSource.mqtt) {
        voltage = v;
        activeSource = DataSource.ble;
        notifyListeners();
      }
    }
  }

  void _onBLECurrent(List<int> data) {
    if (data.isEmpty) return;
    final a = double.tryParse(String.fromCharCodes(data).trim());
    if (a != null) {
      if (activeSource != DataSource.mqtt) {
        current = a;
        activeSource = DataSource.ble;
        notifyListeners();
      }
    }
  }

  void _onBLERelayState(List<int> data) {
    if (data.isEmpty) return;
    relayOn = data[0] == 0x01;
    notifyListeners();
  }

  void _onBLEWifiStatus(List<int> data) {
    if (data.isEmpty) return;
    wifiProvStatus = String.fromCharCodes(data).trim();
    notifyListeners();
    // If Wi-Fi just connected on ESP32, try MQTT
    if (wifiProvStatus.contains("MQTT_OK") || wifiProvStatus.contains("CONNECTED")) {
      Future.delayed(const Duration(seconds: 2), _startMqtt);
    }
  }

  void _onBLEDisconnected() {
    bleConnected = false;
    _voltageChar = null;
    _currentChar = null;
    _relayCmdChar = null;
    _relayStateChar = null;
    _wifiSsidChar = null;
    _wifiPassChar = null;
    _wifiCmdChar = null;
    _wifiStatusChar = null;
    _bleDevice = null;
    _updateSource();
    _setStatus(_statusLabel());
  }

  // ─────────────────────────────────────────
  //  WI-FI PROVISIONING (via BLE)
  // ─────────────────────────────────────────
  Future<bool> provisionWifi(String ssid, String password) async {
    if (_wifiSsidChar == null || _wifiPassChar == null || _wifiCmdChar == null) {
      return false;
    }
    try {
      wifiProvStatus = "Sending…";
      notifyListeners();

      // Write SSID
      await _wifiSsidChar!.write(utf8.encode(ssid), withoutResponse: false);
      await Future.delayed(const Duration(milliseconds: 200));

      // Write Password
      await _wifiPassChar!.write(utf8.encode(password), withoutResponse: false);
      await Future.delayed(const Duration(milliseconds: 200));

      // Write CONNECT command (0x01)
      await _wifiCmdChar!.write([0x01], withoutResponse: false);

      wifiProvStatus = "Connecting…";
      notifyListeners();
      return true;
    } catch (e) {
      wifiProvStatus = "Error: $e";
      notifyListeners();
      return false;
    }
  }

  Future<void> forgetWifi() async {
    if (_wifiCmdChar == null) return;
    try {
      await _wifiCmdChar!.write([0x02], withoutResponse: false);
      disconnectMqtt();
    } catch (_) {}
  }

  // ─────────────────────────────────────────
  //  MQTT: CONNECT
  // ─────────────────────────────────────────
  void _startMqtt() {
    if (mqttConnected) return;
    _connectMqtt();
    // Auto-reconnect timer
    _mqttReconnectTimer?.cancel();
    _mqttReconnectTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) { if (!mqttConnected) _connectMqtt(); },
    );
  }

  Future<void> _connectMqtt() async {
    if (mqttConnected) return;

    final clientId = "flutter_bm_${math.Random().nextInt(0xFFFF).toRadixString(16)}";

    _mqttClient = MqttServerClient(kMqttBroker, clientId)
      ..port = kMqttPort
      ..keepAlivePeriod = 30
      ..autoReconnect = true
      ..onDisconnected = _onMqttDisconnected
      ..onConnected = _onMqttConnected
      ..onAutoReconnect = () {
        debugPrint("[MQTT] Auto-reconnecting…");
      }
      ..logging(on: false);

    _mqttClient!.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean();

    try {
      debugPrint("[MQTT] Connecting to $kMqttBroker:$kMqttPort …");
      await _mqttClient!.connect();
    } catch (e) {
      debugPrint("[MQTT] Connection failed: $e");
      _mqttClient?.disconnect();
      _mqttClient = null;
    }
  }

  void _onMqttConnected() {
    mqttConnected = true;
    _updateSource();
    _setStatus(_statusLabel());
    debugPrint("[MQTT] Connected!");

    // Subscribe to sensor topics and relay state
    _mqttClient!.subscribe(topicVoltage, MqttQos.atMostOnce);
    _mqttClient!.subscribe(topicCurrent, MqttQos.atMostOnce);
    _mqttClient!.subscribe(topicRelayState, MqttQos.atMostOnce);
    _mqttClient!.subscribe(topicStatus, MqttQos.atMostOnce);

    // Listen for messages
    _mqttClient!.updates.listen((List<MqttReceivedMessage<MqttMessage>> msgs) {
      for (final msg in msgs) {
        final topic = msg.topic;
        final pubMsg = msg.payload as MqttPublishMessage;
        final payload = MqttUtilities.bytesToStringAsString(
            pubMsg.payload.message!);

        _handleMqttMessage(topic, payload);
      }
    });
  }

  void _onMqttDisconnected() {
    mqttConnected = false;
    _updateSource();
    _setStatus(_statusLabel());
    debugPrint("[MQTT] Disconnected");
  }

  void _handleMqttMessage(String topic, String payload) {
    if (topic == topicVoltage) {
      final v = double.tryParse(payload.trim());
      if (v != null) {
        voltage = v;
        activeSource = DataSource.mqtt;
        notifyListeners();
      }
    } else if (topic == topicCurrent) {
      final a = double.tryParse(payload.trim());
      if (a != null) {
        current = a;
        activeSource = DataSource.mqtt;
        notifyListeners();
      }
    } else if (topic == topicRelayState) {
      relayOn = payload.trim() == "1";
      notifyListeners();
    }
  }

  void disconnectMqtt() {
    _mqttReconnectTimer?.cancel();
    _mqttClient?.disconnect();
    _mqttClient = null;
    mqttConnected = false;
    _updateSource();
    _setStatus(_statusLabel());
  }

  // ─────────────────────────────────────────
  //  RELAY TOGGLE (dual-path)
  // ─────────────────────────────────────────
  Future<void> toggleRelay(bool on) async {
    // Prefer MQTT (cloud) if available
    if (mqttConnected && _mqttClient != null) {
      final builder = MqttPayloadBuilder();
      builder.addString(on ? "1" : "0");
      _mqttClient!.publishMessage(
        topicRelayCmd,
        MqttQos.atLeastOnce,
        builder.payload!,
      );
      debugPrint("[RELAY] Sent via MQTT: ${on ? 'ON' : 'OFF'}");
    }
    // Also send via BLE if connected (belt & suspenders, or if MQTT is down)
    else if (bleConnected && _relayCmdChar != null) {
      try {
        await _relayCmdChar!.write([on ? 0x01 : 0x00], withoutResponse: false);
        debugPrint("[RELAY] Sent via BLE: ${on ? 'ON' : 'OFF'}");
      } catch (e) {
        debugPrint("[RELAY] BLE write error: $e");
      }
    }
    // Optimistic update
    relayOn = on;
    notifyListeners();
  }

  // ─────────────────────────────────────────
  //  DISCONNECT ALL
  // ─────────────────────────────────────────
  Future<void> disconnectAll() async {
    _mqttReconnectTimer?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();

    _mqttClient?.disconnect();
    _mqttClient = null;
    mqttConnected = false;

    await _bleDevice?.disconnect();
    _bleDevice = null;
    bleConnected = false;

    voltage = 0;
    current = 0;
    relayOn = false;
    activeSource = DataSource.none;
    _setStatus("Disconnected");
  }

  // ── Helpers ──
  void _updateSource() {
    if (mqttConnected) {
      activeSource = DataSource.mqtt;
    } else if (bleConnected) {
      activeSource = DataSource.ble;
    } else {
      activeSource = DataSource.none;
    }
  }

  String _statusLabel() {
    if (mqttConnected && bleConnected) return "Cloud + BLE";
    if (mqttConnected) return "Cloud (MQTT)";
    if (bleConnected) return "BLE (local)";
    return "Disconnected";
  }

  void _setStatus(String msg) {
    statusMessage = msg;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnectAll();
    super.dispose();
  }
}

// ─────────────────────────────────────────────
//  APP ENTRY POINT
// ─────────────────────────────────────────────
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(
    ChangeNotifierProvider(
      create: (_) => DeviceService(),
      child: const BatteryMonitorApp(),
    ),
  );
}

class BatteryMonitorApp extends StatelessWidget {
  const BatteryMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Battery Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0D47A1),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

// ─────────────────────────────────────────────
//  HOME PAGE — route to connect or dashboard
// ─────────────────────────────────────────────
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<DeviceService>(
      builder: (context, svc, _) {
        if (svc.isFullyConnected) {
          return const DashboardScreen();
        }
        return const ConnectScreen();
      },
    );
  }
}

// ─────────────────────────────────────────────
//  CONNECT SCREEN
// ─────────────────────────────────────────────
class ConnectScreen extends StatelessWidget {
  const ConnectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<DeviceService>();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Logo area ──
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.05),
                    border: Border.all(
                      color: Colors.blueAccent.withOpacity(0.3),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    svc.isScanning || svc.isConnecting
                        ? Icons.bluetooth_searching
                        : Icons.bluetooth,
                    size: 56,
                    color: svc.isScanning || svc.isConnecting
                        ? Colors.blueAccent
                        : Colors.grey,
                  ),
                ),
                const SizedBox(height: 32),

                Text(
                  "Battery Monitor",
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withOpacity(0.9),
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  svc.statusMessage,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withOpacity(0.5),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),

                if (svc.isScanning || svc.isConnecting)
                  const SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: () => svc.scanAndConnect(),
                      icon: const Icon(Icons.search),
                      label: const Text("Scan & Connect",
                          style: TextStyle(fontSize: 16)),
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
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

// ─────────────────────────────────────────────
//  DASHBOARD SCREEN
// ─────────────────────────────────────────────
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<DeviceService>();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E21),
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "Battery Monitor",
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 1),
        ),
        actions: [
          // Wi-Fi setup button
          IconButton(
            icon: const Icon(Icons.wifi_outlined),
            tooltip: "Wi-Fi Setup",
            onPressed: () => _showWifiDialog(context, svc),
          ),
          // Disconnect
          IconButton(
            icon: const Icon(Icons.power_settings_new),
            tooltip: "Disconnect",
            onPressed: () => svc.disconnectAll(),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Column(
            children: [
              // ── Connection status bar ──
              _ConnectionBar(svc: svc),
              const SizedBox(height: 20),

              // ── Battery card ──
              _BatteryCard(svc: svc),
              const SizedBox(height: 14),

              // ── Current / Power card ──
              _CurrentCard(svc: svc),
              const SizedBox(height: 14),

              // ── Inverter toggle card ──
              _InverterCard(svc: svc),
              const SizedBox(height: 24),

              // ── Footer ──
              Text(
                "Data via ${_sourceLabel(svc.activeSource)} • updates every 1 s",
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withOpacity(0.25),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  static String _sourceLabel(DataSource s) {
    switch (s) {
      case DataSource.mqtt:
        return "Cloud (MQTT)";
      case DataSource.ble:
        return "BLE (local)";
      case DataSource.none:
        return "—";
    }
  }

  static void _showWifiDialog(BuildContext context, DeviceService svc) {
    if (!svc.bleConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("BLE not connected. Connect via BLE first to provision Wi-Fi.")),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: svc,
        child: const _WifiProvisionDialog(),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  CONNECTION STATUS BAR
// ─────────────────────────────────────────────
class _ConnectionBar extends StatelessWidget {
  final DeviceService svc;
  const _ConnectionBar({required this.svc});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _chip(
          icon: Icons.bluetooth,
          label: "BLE",
          active: svc.bleConnected,
        ),
        const SizedBox(width: 12),
        _chip(
          icon: Icons.cloud_outlined,
          label: "Cloud",
          active: svc.mqttConnected,
        ),
      ],
    );
  }

  Widget _chip({required IconData icon, required String label, required bool active}) {
    final color = active ? Colors.greenAccent : Colors.grey.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 4),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? Colors.greenAccent : Colors.grey.shade700,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  BATTERY CARD
// ─────────────────────────────────────────────
class _BatteryCard extends StatelessWidget {
  final DeviceService svc;
  const _BatteryCard({required this.svc});

  int _percent() {
    const minV = 10.5, maxV = 12.7;
    if (svc.voltage <= minV) return 0;
    if (svc.voltage >= maxV) return 100;
    return ((svc.voltage - minV) / (maxV - minV) * 100).round();
  }

  Color _color() {
    final p = _percent();
    if (p > 60) return Colors.greenAccent;
    if (p > 30) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    final pct = _percent();
    final col = _color();

    return _GlassCard(
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.battery_std, color: col, size: 28),
              const SizedBox(width: 8),
              const Text("Battery",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
              const Spacer(),
              Text("$pct %", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: col)),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 14,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation(col),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                svc.voltage.toStringAsFixed(2),
                style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w300, color: Colors.white, height: 1),
              ),
              const SizedBox(width: 6),
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text("V", style: TextStyle(fontSize: 22, color: Colors.white54, fontWeight: FontWeight.w500)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  CURRENT / POWER CARD
// ─────────────────────────────────────────────
class _CurrentCard extends StatelessWidget {
  final DeviceService svc;
  const _CurrentCard({required this.svc});

  @override
  Widget build(BuildContext context) {
    final watts = (svc.voltage * svc.current);

    return _GlassCard(
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.electrical_services, color: Colors.amberAccent, size: 28),
              const SizedBox(width: 8),
              const Text("Load",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
              const Spacer(),
              Text("${watts.toStringAsFixed(0)} W",
                  style: const TextStyle(fontSize: 16, color: Colors.white54)),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                svc.current.toStringAsFixed(2),
                style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w300, color: Colors.amberAccent, height: 1),
              ),
              const SizedBox(width: 6),
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text("A", style: TextStyle(fontSize: 22, color: Colors.white54, fontWeight: FontWeight.w500)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  INVERTER TOGGLE CARD
// ─────────────────────────────────────────────
class _InverterCard extends StatelessWidget {
  final DeviceService svc;
  const _InverterCard({required this.svc});

  @override
  Widget build(BuildContext context) {
    final col = svc.relayOn ? Colors.greenAccent : Colors.grey;

    return _GlassCard(
      child: Row(
        children: [
          Icon(Icons.power_settings_new, color: col, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Inverter",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
                const SizedBox(height: 2),
                Text(svc.relayOn ? "Running" : "Standby",
                    style: TextStyle(fontSize: 14, color: col)),
              ],
            ),
          ),
          Transform.scale(
            scale: 1.3,
            child: Switch(
              value: svc.relayOn,
              onChanged: (val) => svc.toggleRelay(val),
              activeColor: Colors.greenAccent,
              activeTrackColor: Colors.green.withOpacity(0.4),
              inactiveThumbColor: Colors.grey.shade400,
              inactiveTrackColor: Colors.grey.shade800,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  WI-FI PROVISIONING DIALOG
// ─────────────────────────────────────────────
class _WifiProvisionDialog extends StatefulWidget {
  const _WifiProvisionDialog();

  @override
  State<_WifiProvisionDialog> createState() => _WifiProvisionDialogState();
}

class _WifiProvisionDialogState extends State<_WifiProvisionDialog> {
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscurePass = true;
  bool _sending = false;

  @override
  void dispose() {
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<DeviceService>();

    return AlertDialog(
      backgroundColor: const Color(0xFF1A1F36),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          const Icon(Icons.wifi, color: Colors.blueAccent),
          const SizedBox(width: 10),
          const Text("Wi-Fi Setup", style: TextStyle(color: Colors.white)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status from ESP32
            if (svc.wifiProvStatus.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      _statusIcon(svc.wifiProvStatus),
                      size: 18,
                      color: _statusColor(svc.wifiProvStatus),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        svc.wifiProvStatus,
                        style: TextStyle(
                          fontSize: 13,
                          color: _statusColor(svc.wifiProvStatus),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            TextField(
              controller: _ssidCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: "Wi-Fi Network (SSID)",
                labelStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                prefixIcon: const Icon(Icons.wifi, color: Colors.white38),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.15)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.blueAccent),
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _passCtrl,
              obscureText: _obscurePass,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: "Password",
                labelStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                prefixIcon: const Icon(Icons.lock_outline, color: Colors.white38),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePass ? Icons.visibility_off : Icons.visibility,
                    color: Colors.white38,
                  ),
                  onPressed: () => setState(() => _obscurePass = !_obscurePass),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.15)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.blueAccent),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await svc.forgetWifi();
          },
          child: const Text("Forget Wi-Fi", style: TextStyle(color: Colors.redAccent)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Cancel"),
        ),
        FilledButton(
          onPressed: _sending
              ? null
              : () async {
                  final ssid = _ssidCtrl.text.trim();
                  final pass = _passCtrl.text;
                  if (ssid.isEmpty) return;

                  setState(() => _sending = true);
                  await svc.provisionWifi(ssid, pass);
                  setState(() => _sending = false);
                  // Don't close dialog — let user see status updates
                },
          child: _sending
              ? const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text("Connect"),
        ),
      ],
    );
  }

  IconData _statusIcon(String s) {
    if (s.contains("OK") || s.contains("CONNECTED")) return Icons.check_circle;
    if (s.contains("FAIL") || s.contains("ERROR")) return Icons.error;
    return Icons.info;
  }

  Color _statusColor(String s) {
    if (s.contains("OK") || s.contains("CONNECTED")) return Colors.greenAccent;
    if (s.contains("FAIL") || s.contains("ERROR")) return Colors.redAccent;
    return Colors.orangeAccent;
  }
}

// ─────────────────────────────────────────────
//  REUSABLE GLASS CARD
// ─────────────────────────────────────────────
class _GlassCard extends StatelessWidget {
  final Widget child;
  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: child,
    );
  }
}
