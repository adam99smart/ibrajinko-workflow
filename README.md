# 🔋 ESP32 Battery Monitor & Inverter Controller
## Dual Connectivity: BLE + Wi-Fi/MQTT

A production-grade IoT system with an **ESP32 BLE+Wi-Fi server** and a
**Flutter mobile app**. Monitors battery voltage and load current in
real-time, controls an inverter relay, and supports both local (BLE) and
remote (cloud/MQTT) operation with automatic failover.

---

## 🏗 Architecture

```
┌───────────────────┐        BLE         ┌──────────────────┐
│   Flutter App     │◄──────────────────►│     ESP32        │
│                   │                     │                  │
│  ┌─────────────┐  │    Wi-Fi / MQTT     │  ┌────────────┐ │
│  │ DeviceService│  │◄──────────────────►│  │ PubSubClient│ │
│  │  (Provider)  │  │   (HiveMQ broker)  │  └────────────┘ │
│  └─────────────┘  │                     │                  │
│                   │                     │  ┌────────────┐ │
│  BLE: provisioning│                     │  │  Sensors   │ │
│       + fallback  │                     │  │  + Relay   │ │
│  MQTT: primary    │                     │  └────────────┘ │
│        data path  │                     │                  │
└───────────────────┘                     └──────────────────┘
```

**How it works:**

1. User opens app → scans for ESP32 via **BLE** → connects
2. From the dashboard, user opens **Wi-Fi Setup** dialog
3. Enters Wi-Fi SSID & password → sent to ESP32 via BLE
4. ESP32 stores credentials in NVS (survives reboot), connects to Wi-Fi
5. ESP32 connects to **MQTT broker** and publishes sensor data
6. Flutter app connects to **same MQTT broker** for remote updates
7. Relay commands sent via **MQTT** (preferred) or **BLE** (fallback)
8. If Wi-Fi drops, BLE keeps working seamlessly
9. On reboot, ESP32 auto-reconnects to stored Wi-Fi + MQTT

---

## 📁 Project Structure

```
├── README.md                              ← This file
├── docs/
│   └── WIRING_GUIDE.md                    ← Pin-by-pin wiring + diagrams
├── firmware/
│   └── battery_monitor_dual.ino           ← Complete ESP32 Arduino sketch
└── flutter_app/
    ├── pubspec.yaml                       ← Flutter dependencies
    ├── lib/
    │   └── main.dart                      ← Complete Flutter app
    ├── android/app/src/main/
    │   └── AndroidManifest_PERMISSIONS.xml ← Android permissions to add
    └── ios/Runner/
        └── Info_PERMISSIONS.plist          ← iOS permissions to add
```

---

## ⚡ Hardware Setup

### Quick Pin Map

| ESP32 Pin | → Connection             |
|-----------|--------------------------|
| GPIO 34   | Voltage divider output   |
| GPIO 35   | ACS712 OUT               |
| GPIO 26   | Relay IN                 |
| GPIO 2    | Status LED (optional)    |
| VIN (5V)  | ACS712 VCC + Relay VCC   |
| GND       | All grounds tied         |

### LED Status Patterns

| Pattern        | Meaning                          |
|----------------|----------------------------------|
| Slow blink (1s)| Waiting for Wi-Fi provisioning   |
| Fast blink     | Connecting to Wi-Fi              |
| Solid ON       | Wi-Fi + MQTT connected           |

👉 Full wiring diagrams: **[docs/WIRING_GUIDE.md](docs/WIRING_GUIDE.md)**

---

## 🔧 Firmware Setup

### Prerequisites
- Arduino IDE 2.x (or PlatformIO)
- ESP32 board package (espressif/arduino-esp32 ≥ 2.0)
- **PubSubClient** library (install via Library Manager)
  - Sketch → Include Library → Manage Libraries → search "PubSubClient" by Nick O'Leary

### Configuration

Edit these in `battery_monitor_dual.ino`:

| Constant         | Default             | Change if…                    |
|------------------|---------------------|-------------------------------|
| `DEVICE_ID`      | `"bm_esp32_001"`    | Multiple units on same broker |
| `MQTT_BROKER`    | `"broker.hivemq.com"` | Using private broker       |
| `DIVIDER_RATIO`  | `0.18033`           | Different resistors           |
| `ACS712_ZERO_CURRENT` | `2.50`         | Calibration needed            |
| `RELAY_ACTIVE_LOW`    | `true`          | Non-inverted relay module     |

### Upload

1. Open `firmware/battery_monitor_dual.ino`
2. Board: **ESP32 Dev Module**
3. Upload, then open Serial Monitor at **115200 baud**
4. You should see: `[BLE] Server started, advertising...`

### BLE Characteristics

**Sensor Service** (`0x180F`):
| Char               | UUID     | Properties   | Format              |
|--------------------|----------|-------------|---------------------|
| Battery Voltage    | `0x2A19` | READ, NOTIFY | ASCII `"12.45"`     |
| Load Current       | `0x2A1A` | READ, NOTIFY | ASCII `"3.21"`      |
| Relay Command      | `0x2A1B` | READ, WRITE  | byte: `0x01`/`0x00` |
| Relay State        | `0x2A1C` | READ, NOTIFY | byte: `0x01`/`0x00` |

**Wi-Fi Service** (`0x181A`):
| Char               | UUID     | Properties   | Format              |
|--------------------|----------|-------------|---------------------|
| Wi-Fi SSID         | `0x2A20` | WRITE        | UTF-8 string        |
| Wi-Fi Password     | `0x2A21` | WRITE        | UTF-8 string        |
| Wi-Fi Command      | `0x2A22` | WRITE        | `0x01`=connect, `0x02`=forget |
| Wi-Fi Status       | `0x2A23` | READ, NOTIFY | ASCII status string |

### MQTT Topics

| Topic                      | Direction    | Content        |
|----------------------------|-------------|----------------|
| `bm_esp32_001/voltage`     | ESP32 → App | `"12.45"`      |
| `bm_esp32_001/current`     | ESP32 → App | `"3.21"`       |
| `bm_esp32_001/relay/state` | ESP32 → App | `"1"` or `"0"` |
| `bm_esp32_001/relay/cmd`   | App → ESP32 | `"1"` or `"0"` |
| `bm_esp32_001/status`      | ESP32 → App | `"online"`/`"offline"` (LWT) |

---

## 📱 Flutter App Setup

### Dependencies

```yaml
dependencies:
  flutter_blue_plus: ^1.35.2       # BLE communication
  mqtt5_client: ^4.5.0             # MQTT cloud connectivity
  permission_handler: ^11.3.1      # Runtime permissions
  provider: ^6.1.2                 # State management
```

### Platform Permissions

**Android** — Add contents of `AndroidManifest_PERMISSIONS.xml` to your
`AndroidManifest.xml`. Set `minSdkVersion 21` in `build.gradle`.

**iOS** — Add contents of `Info_PERMISSIONS.plist` to your `Info.plist`.
Set `platform :ios, '13.0'` in `Podfile`.

### Build & Run

```bash
cd flutter_app
flutter pub get
flutter run          # physical device required (no BLE in emulators)
```

### App Flow

1. **Connect Screen** → Tap "Scan & Connect" → finds ESP32 via BLE
2. **Dashboard** → Real-time voltage, current, power display
3. **Wi-Fi Setup** (⚙️ icon) → Enter SSID/password → sends to ESP32 via BLE
4. **Cloud connects** → MQTT becomes primary data source automatically
5. **Inverter toggle** → sends command via MQTT (or BLE fallback)
6. **Dual indicators** show BLE 🟢 and Cloud 🟢 status at top

### Connectivity Logic

```
┌─────────────────────────────────────────────────┐
│              Data Source Priority                │
│                                                 │
│  MQTT available?  ──► YES ──► Use MQTT (cloud)  │
│       │                                         │
│       NO                                        │
│       │                                         │
│  BLE connected?   ──► YES ──► Use BLE (local)   │
│       │                                         │
│       NO                                        │
│       │                                         │
│  Show "Disconnected"                            │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│              Command Routing                    │
│                                                 │
│  Toggle relay ──► MQTT connected?               │
│                    │                            │
│                   YES ──► Publish to MQTT topic  │
│                    │                            │
│                    NO ──► BLE connected?         │
│                            │                    │
│                           YES ──► Write BLE char │
│                            │                    │
│                            NO ──► Show error     │
└─────────────────────────────────────────────────┘
```

---

## 🔒 Security Notes

> ⚠️ The HiveMQ **public** broker is used for development/testing.
> **Do NOT use it for production** — anyone can subscribe to your topics.

For production, use one of:
- **HiveMQ Cloud** (free tier, TLS + auth): https://www.hivemq.com/cloud/
- **Mosquitto** self-hosted with TLS
- **AWS IoT Core** / **Azure IoT Hub**

Update `MQTT_BROKER`, `MQTT_PORT`, and add username/password in both
the ESP32 firmware and Flutter app.

---

## 📐 Calibration

1. **Voltage:** Multimeter on battery → compare to Serial Monitor →
   adjust `DIVIDER_RATIO` or `ADC_REF_VOLTAGE`
2. **Current:** No load → serial should show ~0.00 A →
   adjust `ACS712_ZERO_CURRENT` if offset exists
3. **Battery %:** Default is 12 V lead-acid (10.5–12.7 V).
   Change `minV`/`maxV` in `_BatteryCard._percent()` for your chemistry:
   - 12 V LiFePO4: 10.0 – 14.6 V
   - 24 V lead-acid: 21.0 – 25.4 V
   - 48 V lead-acid: 42.0 – 50.8 V

---

## 🧪 Testing Without Hardware

You can test the MQTT path without an ESP32:

```bash
# Install mosquitto-clients
# Terminal 1: simulate ESP32 publishing voltage
mosquitto_pub -h broker.hivemq.com -t "bm_esp32_001/voltage" -m "12.45" -r

# Terminal 2: simulate ESP32 publishing current
mosquitto_pub -h broker.hivemq.com -t "bm_esp32_001/current" -m "5.30" -r

# Terminal 3: simulate relay state
mosquitto_pub -h broker.hivemq.com -t "bm_esp32_001/relay/state" -m "0" -r

# Terminal 4: listen for relay commands from the app
mosquitto_sub -h broker.hivemq.com -t "bm_esp32_001/relay/cmd" -v
```

Then run the Flutter app → skip BLE → manually call `_startMqtt()` from
a debug button to test cloud-only mode.
