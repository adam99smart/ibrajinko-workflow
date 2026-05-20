# Wiring Guide — ESP32 Battery Monitor & Inverter Controller
# (Dual-Connectivity: BLE + Wi-Fi/MQTT Edition)

## Components Required

| # | Component                        | Purpose                            |
|---|----------------------------------|------------------------------------|
| 1 | ESP32 Dev Board (30-pin)         | Controller + BLE + Wi-Fi           |
| 2 | ACS712-30A module                | Current sensing (±30 A range)      |
| 3 | 5 V single-channel relay module  | Inverter ON/OFF switching          |
| 4 | 100 kΩ resistor (R1)             | Voltage divider — high side        |
| 5 | 22 kΩ resistor (R2)              | Voltage divider — low side         |
| 6 | 100 nF (0.1 µF) ceramic cap     | ADC noise filter                   |
| 7 | LED + 220 Ω resistor (optional)  | Wi-Fi status indicator             |
| 8 | 12 V lead-acid / lithium battery | The battery being monitored        |
| 9 | Inverter                         | The load being switched            |

---

## Pin Map

```
ESP32 Pin  →  Destination              Notes
───────────────────────────────────────────────────────────────
GPIO 34    →  Voltage divider output    ADC input (input-only pin)
GPIO 35    →  ACS712 OUT pin            ADC input (input-only pin)
GPIO 26    →  Relay IN (signal)         Digital output
GPIO 2     →  Status LED (optional)     Onboard LED on most boards
3V3        →  (reference only)
VIN (5 V)  →  ACS712 VCC + Relay VCC   Shared 5 V rail
GND        →  Common ground            ALL grounds must be shared
```

---

## Wiring Detail

### A) Battery Voltage Divider → GPIO 34

Scale battery voltage to ESP32's 0–3.3 V ADC range.

```
Battery (+) ───[ 100 kΩ R1 ]───┬───[ 22 kΩ R2 ]─── GND
                                │
                                ├─── 100 nF cap ─── GND
                                │
                                └─── GPIO 34 (ESP32)
```

**Divider Math:**
- V_out = V_batt × R2 / (R1 + R2) = V_batt × 22k / 122k = V_batt × 0.1803

| Battery System | R1      | R2    | Ratio  | Max V_out at full |
|----------------|---------|-------|--------|-------------------|
| 12 V           | 100 kΩ  | 22 kΩ | 0.1803 | 2.60 V ✓         |
| 24 V           | 220 kΩ  | 22 kΩ | 0.0909 | 2.18 V ✓         |
| 48 V           | 470 kΩ  | 22 kΩ | 0.0447 | 2.15 V ✓         |

> ⚠️ Update `DIVIDER_RATIO` in firmware when changing resistors.

### B) ACS712-30A Current Sensor → GPIO 35

```
ACS712 Module
┌──────────────┐
│  VCC ────────│──── ESP32 VIN (5 V)
│  GND ────────│──── ESP32 GND
│  OUT ────────│──── ESP32 GPIO 35
│              │
│  IP+ ────────│──── Battery (−) terminal
│  IP− ────────│──── Inverter input (−) terminal
└──────────────┘
```

> Wired **in series** on the NEGATIVE wire.
> OUT = 2.5 V at 0 A, shifts ±66 mV/A for the 30 A version.

### C) Relay Module → GPIO 26

```
Relay Module
┌──────────────┐
│  VCC ────────│──── ESP32 VIN (5 V)
│  GND ────────│──── ESP32 GND
│  IN  ────────│──── ESP32 GPIO 26
│              │
│  COM ────────│──── Inverter power input (+)
│  NO  ────────│──── Battery (+) terminal
│  NC  ────────│──── (not connected)
└──────────────┘
```

### D) Status LED (Optional) → GPIO 2

```
GPIO 2 ───[ 220 Ω ]───▶|─── GND
                       (LED)
```

Most ESP32 dev boards have an onboard LED on GPIO 2.

**LED Patterns (defined in firmware):**
- **Slow blink (2s):** Waiting for Wi-Fi credentials via BLE
- **Fast blink (200ms):** Connecting to Wi-Fi
- **Solid ON:** Wi-Fi + MQTT connected
- **OFF:** Error state

---

## Full System Diagram (ASCII)

```
                    ┌─────────────┐
 Battery (+) ──────►│ 100kΩ (R1)  │
                    └──────┬──────┘
                           │
                           ├──────────────► GPIO 34 (ESP32)
                           │
                    ┌──────┴──────┐
                    │  22kΩ (R2)  │
                    └──────┬──────┘
                           │
                          GND

 Battery (−) ──► ACS712 IP+ ──► IP− ──► Inverter (−)
                  ACS712 OUT ──────────► GPIO 35 (ESP32)
                  ACS712 VCC ──────────► 5 V
                  ACS712 GND ──────────► GND

 Relay IN ◄──────────────────────────── GPIO 26 (ESP32)
 Relay VCC ────────────────────────────► 5 V
 Relay GND ────────────────────────────► GND
 Relay COM ────────────────────────────► Inverter (+) input
 Relay NO  ────────────────────────────► Battery (+)

 GPIO 2 ──[ 220Ω ]──▶|── GND          (Status LED)

                  ┌────────────────┐
    ESP32 Wi-Fi ──┤  Home Router   ├── Internet ── MQTT Broker
                  └────────────────┘              (HiveMQ Cloud)
```
