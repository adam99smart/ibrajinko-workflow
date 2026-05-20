/*
 * ====================================================================
 *  ESP32 Battery Monitor & Inverter Controller
 *  Dual Connectivity: BLE (provisioning + fallback) + Wi-Fi/MQTT
 * ====================================================================
 *
 *  Architecture:
 *    1. BLE server ALWAYS runs (provisioning + local data + fallback)
 *    2. Wi-Fi credentials received via BLE → stored in NVS (survives reboot)
 *    3. Once Wi-Fi connected → MQTT publishes sensor data, subscribes to cmds
 *    4. Relay commands accepted from BOTH BLE writes AND MQTT messages
 *    5. If Wi-Fi drops → auto-reconnects; BLE remains operational
 *
 *  Board:  ESP32 Dev Module  (Arduino core >= 2.0)
 *  Libs:   BLE (built-in), WiFi (built-in), PubSubClient (MQTT),
 *          Preferences (built-in, for NVS)
 *
 *  Install PubSubClient via Arduino Library Manager:
 *    Sketch → Include Library → Manage Libraries → search "PubSubClient"
 * ====================================================================
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <Preferences.h>
#include <Arduino.h>

// ─────────────────────────────────────────────────────────
//  PIN DEFINITIONS
// ─────────────────────────────────────────────────────────
#define PIN_VOLTAGE     34    // ADC1_CH6 — voltage divider output
#define PIN_CURRENT     35    // ADC1_CH7 — ACS712 OUT
#define PIN_RELAY       26    // Digital out — relay signal
#define PIN_STATUS_LED   2    // Onboard LED (most ESP32 boards)

// ─────────────────────────────────────────────────────────
//  HARDWARE CALIBRATION CONSTANTS
// ─────────────────────────────────────────────────────────
const float DIVIDER_RATIO       = 0.18033;  // R2/(R1+R2) = 22k/122k
const float ADC_REF_VOLTAGE     = 3.3;      // Measure your board's 3V3 pin
const int   ADC_MAX             = 4095;     // 12-bit ADC
const float ACS712_SENSITIVITY  = 0.066;    // 66 mV/A for 30A version
const float ACS712_ZERO_CURRENT = 2.50;     // Voltage at 0 A (calibrate!)
const int   ADC_SAMPLES         = 64;       // Multi-sample averaging
const bool  RELAY_ACTIVE_LOW    = true;     // Most opto-isolated modules

// ─────────────────────────────────────────────────────────
//  MQTT CONFIGURATION
// ─────────────────────────────────────────────────────────
//  Using HiveMQ public broker (free, no auth needed for testing).
//  For production, use a private broker with TLS + credentials.
const char* MQTT_BROKER   = "broker.hivemq.com";
const int   MQTT_PORT     = 1883;

//  Unique device ID — change this if you have multiple units!
//  This prefixes all MQTT topics to avoid collisions on public broker.
const char* DEVICE_ID     = "bm_esp32_001";

//  MQTT Topics (auto-constructed from DEVICE_ID in setup)
char TOPIC_VOLTAGE[64];     //  bm_esp32_001/voltage
char TOPIC_CURRENT[64];     //  bm_esp32_001/current
char TOPIC_RELAY_STATE[64]; //  bm_esp32_001/relay/state
char TOPIC_RELAY_CMD[64];   //  bm_esp32_001/relay/cmd
char TOPIC_STATUS[64];      //  bm_esp32_001/status

// ─────────────────────────────────────────────────────────
//  BLE UUIDs
// ─────────────────────────────────────────────────────────
//  Primary sensor/control service (same as before)
#define SERVICE_UUID              "0000180F-0000-1000-8000-00805F9B34FB"
#define CHAR_VOLTAGE_UUID         "00002A19-0000-1000-8000-00805F9B34FB"
#define CHAR_CURRENT_UUID         "00002A1A-0000-1000-8000-00805F9B34FB"
#define CHAR_RELAY_CMD_UUID       "00002A1B-0000-1000-8000-00805F9B34FB"
#define CHAR_RELAY_STATE_UUID     "00002A1C-0000-1000-8000-00805F9B34FB"

//  Wi-Fi provisioning service
#define WIFI_SERVICE_UUID         "0000181A-0000-1000-8000-00805F9B34FB"
#define CHAR_WIFI_SSID_UUID       "00002A20-0000-1000-8000-00805F9B34FB"
#define CHAR_WIFI_PASS_UUID       "00002A21-0000-1000-8000-00805F9B34FB"
#define CHAR_WIFI_CMD_UUID        "00002A22-0000-1000-8000-00805F9B34FB"
#define CHAR_WIFI_STATUS_UUID     "00002A23-0000-1000-8000-00805F9B34FB"

// ─────────────────────────────────────────────────────────
//  GLOBAL OBJECTS
// ─────────────────────────────────────────────────────────
WiFiClient    wifiClient;
PubSubClient  mqtt(wifiClient);
Preferences   prefs;

// BLE characteristics
BLEServer*            pServer            = nullptr;
BLECharacteristic*    pCharVoltage       = nullptr;
BLECharacteristic*    pCharCurrent       = nullptr;
BLECharacteristic*    pCharRelayCmd      = nullptr;
BLECharacteristic*    pCharRelayState    = nullptr;
BLECharacteristic*    pCharWifiSsid      = nullptr;
BLECharacteristic*    pCharWifiPass      = nullptr;
BLECharacteristic*    pCharWifiCmd       = nullptr;
BLECharacteristic*    pCharWifiStatus    = nullptr;

// ─────────────────────────────────────────────────────────
//  STATE VARIABLES
// ─────────────────────────────────────────────────────────
// BLE
bool     bleClientConnected     = false;
bool     bleOldConnected        = false;

// Wi-Fi provisioning
String   pendingSsid            = "";
String   pendingPass            = "";
String   storedSsid             = "";
String   storedPass             = "";
bool     wifiProvisioned        = false;
bool     wifiConnected          = false;
bool     mqttConnected          = false;

// Relay
bool     relayState             = false;   // false=OFF, true=ON

// Timing
unsigned long lastSensorRead    = 0;
unsigned long lastMqttReconnect = 0;
unsigned long lastWifiCheck     = 0;
unsigned long lastLedToggle     = 0;
bool          ledOn             = false;

const unsigned long SENSOR_INTERVAL_MS      = 1000;
const unsigned long MQTT_RECONNECT_MS       = 5000;
const unsigned long WIFI_CHECK_INTERVAL_MS  = 10000;

// Sensor values
float    voltage                = 0.0;
float    current                = 0.0;

// ─────────────────────────────────────────────────────────
//  STATUS LED PATTERNS
// ─────────────────────────────────────────────────────────
enum LedPattern { LED_SLOW_BLINK, LED_FAST_BLINK, LED_SOLID, LED_OFF };
LedPattern currentLedPattern = LED_SLOW_BLINK;

void updateStatusLed() {
  unsigned long now = millis();
  switch (currentLedPattern) {
    case LED_SOLID:
      digitalWrite(PIN_STATUS_LED, HIGH);
      break;
    case LED_OFF:
      digitalWrite(PIN_STATUS_LED, LOW);
      break;
    case LED_SLOW_BLINK:
      if (now - lastLedToggle > 1000) {
        ledOn = !ledOn;
        digitalWrite(PIN_STATUS_LED, ledOn ? HIGH : LOW);
        lastLedToggle = now;
      }
      break;
    case LED_FAST_BLINK:
      if (now - lastLedToggle > 150) {
        ledOn = !ledOn;
        digitalWrite(PIN_STATUS_LED, ledOn ? HIGH : LOW);
        lastLedToggle = now;
      }
      break;
  }
}

// ─────────────────────────────────────────────────────────
//  RELAY CONTROL
// ─────────────────────────────────────────────────────────
void applyRelayState() {
  if (RELAY_ACTIVE_LOW) {
    digitalWrite(PIN_RELAY, relayState ? LOW : HIGH);
  } else {
    digitalWrite(PIN_RELAY, relayState ? HIGH : LOW);
  }
}

void setRelay(bool on, const char* source) {
  relayState = on;
  applyRelayState();
  Serial.printf("[RELAY] %s via %s\n", on ? "ON" : "OFF", source);

  // Update BLE characteristic
  uint8_t stateVal = relayState ? 0x01 : 0x00;
  pCharRelayState->setValue(&stateVal, 1);
  if (bleClientConnected) {
    pCharRelayState->notify();
  }

  // Publish relay state to MQTT (regardless of which source triggered it)
  if (mqttConnected) {
    mqtt.publish(TOPIC_RELAY_STATE, relayState ? "1" : "0", true); // retained
  }
}

// ─────────────────────────────────────────────────────────
//  SENSOR READING
// ─────────────────────────────────────────────────────────
float readADC_Averaged(int pin) {
  long sum = 0;
  for (int i = 0; i < ADC_SAMPLES; i++) {
    sum += analogRead(pin);
    delayMicroseconds(100);
  }
  return (float)sum / (float)ADC_SAMPLES;
}

float readBatteryVoltage() {
  float adcRaw   = readADC_Averaged(PIN_VOLTAGE);
  float adcVolts = (adcRaw / (float)ADC_MAX) * ADC_REF_VOLTAGE;
  return adcVolts / DIVIDER_RATIO;
}

float readLoadCurrent() {
  float adcRaw   = readADC_Averaged(PIN_CURRENT);
  float adcVolts = (adcRaw / (float)ADC_MAX) * ADC_REF_VOLTAGE;
  float amps     = (adcVolts - ACS712_ZERO_CURRENT) / ACS712_SENSITIVITY;
  if (amps < 0.0) amps = 0.0;
  return amps;
}

// ─────────────────────────────────────────────────────────
//  BLE CALLBACKS
// ─────────────────────────────────────────────────────────
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* s) override {
    bleClientConnected = true;
    Serial.println("[BLE] Client connected");
  }
  void onDisconnect(BLEServer* s) override {
    bleClientConnected = false;
    Serial.println("[BLE] Client disconnected");
  }
};

// Relay command via BLE
class RelayCmdCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pChar) override {
    String val = pChar->getValue();
    if (val.length() > 0) {
      setRelay(val[0] == 0x01, "BLE");
    }
  }
};

// Wi-Fi SSID received via BLE
class WifiSsidCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pChar) override {
    pendingSsid = pChar->getValue();
    Serial.printf("[WIFI-PROV] SSID received: %s\n", pendingSsid.c_str());
  }
};

// Wi-Fi Password received via BLE
class WifiPassCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pChar) override {
    pendingPass = pChar->getValue();
    Serial.println("[WIFI-PROV] Password received: ****");
  }
};

// Wi-Fi command: 0x01 = connect with pending creds, 0x02 = forget/reset
class WifiCmdCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pChar) override {
    String val = pChar->getValue();
    if (val.length() == 0) return;

    uint8_t cmd = val[0];
    if (cmd == 0x01) {
      // Save credentials and initiate connection
      if (pendingSsid.length() > 0) {
        Serial.println("[WIFI-PROV] Saving credentials & connecting...");
        storedSsid = pendingSsid;
        storedPass = pendingPass;

        // Persist to NVS
        prefs.begin("wifi", false);
        prefs.putString("ssid", storedSsid);
        prefs.putString("pass", storedPass);
        prefs.end();

        wifiProvisioned = true;
        setWifiStatusBLE("CONNECTING");
        connectWifi();
      } else {
        setWifiStatusBLE("ERROR:NO_SSID");
      }
    } else if (cmd == 0x02) {
      // Forget credentials
      Serial.println("[WIFI-PROV] Forgetting credentials...");
      WiFi.disconnect(true);
      prefs.begin("wifi", false);
      prefs.clear();
      prefs.end();
      storedSsid = "";
      storedPass = "";
      wifiProvisioned = false;
      wifiConnected = false;
      mqttConnected = false;
      setWifiStatusBLE("CLEARED");
      currentLedPattern = LED_SLOW_BLINK;
    }
  }
};

void setWifiStatusBLE(const char* status) {
  pCharWifiStatus->setValue(status);
  if (bleClientConnected) {
    pCharWifiStatus->notify();
  }
}

// ─────────────────────────────────────────────────────────
//  WI-FI CONNECTION
// ─────────────────────────────────────────────────────────
void connectWifi() {
  if (storedSsid.length() == 0) return;

  Serial.printf("[WIFI] Connecting to: %s\n", storedSsid.c_str());
  currentLedPattern = LED_FAST_BLINK;

  WiFi.mode(WIFI_STA);
  WiFi.begin(storedSsid.c_str(), storedPass.c_str());

  // Block for up to 15 seconds
  int tries = 0;
  while (WiFi.status() != WL_CONNECTED && tries < 30) {
    delay(500);
    Serial.print(".");
    tries++;
    updateStatusLed();
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    wifiConnected = true;
    Serial.printf("[WIFI] Connected! IP: %s\n", WiFi.localIP().toString().c_str());
    setWifiStatusBLE("CONNECTED");
    currentLedPattern = LED_SOLID;
    connectMqtt();
  } else {
    wifiConnected = false;
    Serial.println("[WIFI] Connection FAILED");
    setWifiStatusBLE("FAILED");
    currentLedPattern = LED_SLOW_BLINK;
  }
}

// ─────────────────────────────────────────────────────────
//  MQTT
// ─────────────────────────────────────────────────────────
void mqttCallback(char* topic, byte* payload, unsigned int length) {
  // Relay command from cloud
  if (strcmp(topic, TOPIC_RELAY_CMD) == 0 && length > 0) {
    char cmd = (char)payload[0];
    if (cmd == '1') {
      setRelay(true, "MQTT");
    } else if (cmd == '0') {
      setRelay(false, "MQTT");
    }
  }
}

void connectMqtt() {
  if (!wifiConnected) return;

  mqtt.setServer(MQTT_BROKER, MQTT_PORT);
  mqtt.setCallback(mqttCallback);
  mqtt.setKeepAlive(60);
  mqtt.setBufferSize(512);

  // Create a unique client ID
  String clientId = String(DEVICE_ID) + "_" + String(random(0xFFFF), HEX);

  Serial.printf("[MQTT] Connecting to %s as %s...\n",
                MQTT_BROKER, clientId.c_str());

  // Connect with a Last Will & Testament (LWT)
  if (mqtt.connect(clientId.c_str(), NULL, NULL,
                   TOPIC_STATUS, 1, true, "offline")) {
    mqttConnected = true;
    Serial.println("[MQTT] Connected!");

    // Publish online status (retained)
    mqtt.publish(TOPIC_STATUS, "online", true);

    // Publish current relay state (retained)
    mqtt.publish(TOPIC_RELAY_STATE, relayState ? "1" : "0", true);

    // Subscribe to relay commands
    mqtt.subscribe(TOPIC_RELAY_CMD, 1);
    Serial.printf("[MQTT] Subscribed to: %s\n", TOPIC_RELAY_CMD);

    setWifiStatusBLE("MQTT_OK");
    currentLedPattern = LED_SOLID;
  } else {
    mqttConnected = false;
    Serial.printf("[MQTT] Failed, rc=%d\n", mqtt.state());
    setWifiStatusBLE("MQTT_FAIL");
  }
}

// ─────────────────────────────────────────────────────────
//  BLE SETUP
// ─────────────────────────────────────────────────────────
void setupBLE() {
  BLEDevice::init("BatteryMonitor");

  // Increase MTU for longer Wi-Fi passwords
  BLEDevice::setMTU(256);

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  // ── Service 1: Sensor & Relay (primary) ──
  BLEService* pSensorService = pServer->createService(
    BLEUUID(SERVICE_UUID), 20  // 20 handles (need extra room)
  );

  // Battery Voltage (read + notify)
  pCharVoltage = pSensorService->createCharacteristic(
    CHAR_VOLTAGE_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharVoltage->addDescriptor(new BLE2902());

  // Load Current (read + notify)
  pCharCurrent = pSensorService->createCharacteristic(
    CHAR_CURRENT_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharCurrent->addDescriptor(new BLE2902());

  // Relay Command (read + write)
  pCharRelayCmd = pSensorService->createCharacteristic(
    CHAR_RELAY_CMD_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE
  );
  pCharRelayCmd->setCallbacks(new RelayCmdCallback());
  uint8_t initCmd = 0x00;
  pCharRelayCmd->setValue(&initCmd, 1);

  // Relay State (read + notify)
  pCharRelayState = pSensorService->createCharacteristic(
    CHAR_RELAY_STATE_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharRelayState->addDescriptor(new BLE2902());
  uint8_t initState = 0x00;
  pCharRelayState->setValue(&initState, 1);

  pSensorService->start();

  // ── Service 2: Wi-Fi Provisioning ──
  BLEService* pWifiService = pServer->createService(
    BLEUUID(WIFI_SERVICE_UUID), 20
  );

  // SSID (write)
  pCharWifiSsid = pWifiService->createCharacteristic(
    CHAR_WIFI_SSID_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  pCharWifiSsid->setCallbacks(new WifiSsidCallback());

  // Password (write)
  pCharWifiPass = pWifiService->createCharacteristic(
    CHAR_WIFI_PASS_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  pCharWifiPass->setCallbacks(new WifiPassCallback());

  // Command (write): 0x01=connect, 0x02=forget
  pCharWifiCmd = pWifiService->createCharacteristic(
    CHAR_WIFI_CMD_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  pCharWifiCmd->setCallbacks(new WifiCmdCallback());

  // Status (read + notify)
  pCharWifiStatus = pWifiService->createCharacteristic(
    CHAR_WIFI_STATUS_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharWifiStatus->addDescriptor(new BLE2902());
  pCharWifiStatus->setValue("IDLE");

  pWifiService->start();

  // ── Start advertising ──
  BLEAdvertising* pAdv = BLEDevice::getAdvertising();
  pAdv->addServiceUUID(SERVICE_UUID);
  pAdv->addServiceUUID(WIFI_SERVICE_UUID);
  pAdv->setScanResponse(true);
  pAdv->setMinPreferred(0x06);
  BLEDevice::startAdvertising();

  Serial.println("[BLE] Server started, advertising...");
}

// ─────────────────────────────────────────────────────────
//  LOAD STORED CREDENTIALS
// ─────────────────────────────────────────────────────────
void loadStoredCredentials() {
  prefs.begin("wifi", true);  // read-only
  storedSsid = prefs.getString("ssid", "");
  storedPass = prefs.getString("pass", "");
  prefs.end();

  if (storedSsid.length() > 0) {
    wifiProvisioned = true;
    Serial.printf("[NVS] Found stored SSID: %s\n", storedSsid.c_str());
  } else {
    Serial.println("[NVS] No stored Wi-Fi credentials.");
  }
}

// ─────────────────────────────────────────────────────────
//  SETUP
// ─────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("\n====== Battery Monitor — Dual Connectivity ======");

  // GPIO
  pinMode(PIN_RELAY, OUTPUT);
  pinMode(PIN_STATUS_LED, OUTPUT);
  relayState = false;
  applyRelayState();

  // ADC
  analogReadResolution(12);
  analogSetAttenuation(ADC_11db);

  // Build MQTT topic strings
  snprintf(TOPIC_VOLTAGE,     sizeof(TOPIC_VOLTAGE),     "%s/voltage",     DEVICE_ID);
  snprintf(TOPIC_CURRENT,     sizeof(TOPIC_CURRENT),     "%s/current",     DEVICE_ID);
  snprintf(TOPIC_RELAY_STATE, sizeof(TOPIC_RELAY_STATE), "%s/relay/state", DEVICE_ID);
  snprintf(TOPIC_RELAY_CMD,   sizeof(TOPIC_RELAY_CMD),   "%s/relay/cmd",   DEVICE_ID);
  snprintf(TOPIC_STATUS,      sizeof(TOPIC_STATUS),      "%s/status",      DEVICE_ID);

  // BLE (always on)
  setupBLE();

  // Check for stored Wi-Fi creds (from a previous provisioning)
  loadStoredCredentials();
  if (wifiProvisioned) {
    setWifiStatusBLE("CONNECTING");
    connectWifi();
  } else {
    currentLedPattern = LED_SLOW_BLINK;
  }
}

// ─────────────────────────────────────────────────────────
//  MAIN LOOP
// ─────────────────────────────────────────────────────────
void loop() {
  unsigned long now = millis();

  // ── LED animation ──
  updateStatusLed();

  // ── Handle BLE reconnection (re-advertise after disconnect) ──
  if (!bleClientConnected && bleOldConnected) {
    delay(300);
    pServer->startAdvertising();
    Serial.println("[BLE] Re-advertising...");
    bleOldConnected = false;
  }
  if (bleClientConnected && !bleOldConnected) {
    bleOldConnected = true;
  }

  // ── Wi-Fi watchdog: reconnect if dropped ──
  if (wifiProvisioned && (now - lastWifiCheck >= WIFI_CHECK_INTERVAL_MS)) {
    lastWifiCheck = now;
    if (WiFi.status() != WL_CONNECTED) {
      if (wifiConnected) {
        Serial.println("[WIFI] Connection lost! Reconnecting...");
        wifiConnected = false;
        mqttConnected = false;
        currentLedPattern = LED_FAST_BLINK;
        setWifiStatusBLE("RECONNECTING");
      }
      connectWifi();
    }
  }

  // ── MQTT keep-alive & reconnect ──
  if (wifiConnected) {
    if (!mqtt.connected()) {
      mqttConnected = false;
      if (now - lastMqttReconnect >= MQTT_RECONNECT_MS) {
        lastMqttReconnect = now;
        connectMqtt();
      }
    } else {
      mqtt.loop();  // Process incoming messages + keepalive
    }
  }

  // ── Periodic sensor reads (1 Hz) ──
  if (now - lastSensorRead >= SENSOR_INTERVAL_MS) {
    lastSensorRead = now;

    voltage = readBatteryVoltage();
    current = readLoadCurrent();

    // Format strings
    char voltStr[8], currStr[8];
    dtostrf(voltage, 4, 2, voltStr);
    dtostrf(current, 4, 2, currStr);

    // ── Update BLE characteristics ──
    pCharVoltage->setValue(voltStr);
    pCharCurrent->setValue(currStr);
    if (bleClientConnected) {
      pCharVoltage->notify();
      pCharCurrent->notify();
    }

    // ── Publish to MQTT ──
    if (mqttConnected) {
      mqtt.publish(TOPIC_VOLTAGE, voltStr);
      mqtt.publish(TOPIC_CURRENT, currStr);
    }

    // ── Serial debug ──
    Serial.printf("[DATA] V=%-6s A=%-6s Relay=%-3s | WiFi=%s MQTT=%s BLE=%s\n",
                  voltStr, currStr,
                  relayState ? "ON" : "OFF",
                  wifiConnected ? "✓" : "✗",
                  mqttConnected ? "✓" : "✗",
                  bleClientConnected ? "✓" : "✗");
  }
}
