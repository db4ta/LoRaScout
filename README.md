# LoRaScout

iPhone-App für den LoRaWAN Field Tester (M5Stack Core2). Firmware, BLE-Protokoll und ioBroker-Skripte liegen in [db4ta/M5Stack_TTN_Fieldtester](https://github.com/db4ta/M5Stack_TTN_Fieldtester).

## Funktionen

- Live-Daten per Bluetooth: GPS, LoRaWAN, Gateways, Pakete, Ereignis-Verlauf
- Steuerung: SEND NOW, Screenwechsel am Gerät, komplette Konfiguration, Neustart
- Log-Download per BLE, zusammengeführt mit dem Coverage-Log vom ioBroker
- Karte, Auswertung und Verlauf nach Tag, Monat, Jahr oder gesamt
- Export als CSV und JPG mit wählbarem Kartenausschnitt
- Lokales Archiv, Löschen auf iPhone, Tester und Server

## Voraussetzungen

Xcode 26.5, iOS 26.5 oder neuer. Bluetooth gibt es nicht im Simulator.

Coverage-Abruf nur im lokalen Netz per IP-Adresse, `.local` oder Rechnername. Das Token liegt im iOS-Schlüsselbund.

## Aufbau

| Ordner | Inhalt |
|---|---|
| `LoRaScout/BLE` | CoreBluetooth-Verbindung |
| `LoRaScout/Protocol` | Parser, Zusammenführen, Ereignisse, Archiv als reine Funktionen |
| `LoRaScout/Network` | Netz-Abstraktion (bisher TTN), Coverage-Abruf, Token |
| `LoRaScout/Views` | SwiftUI-Oberfläche |

## Demo

Im Debug-Build zeigt das Startargument `-demo` Beispieldaten, `-demoTab n` öffnet einen Tab. Das Release-Build enthält das nicht.
