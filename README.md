# LoRaScout

iPhone-App für den LoRaWAN Field Tester (M5Stack Core2) und den Heltec Wireless Tracker. Firmware, BLE-Protokoll und ioBroker-Skripte liegen in [db4ta/M5Stack_TTN_Fieldtester](https://github.com/db4ta/M5Stack_TTN_Fieldtester).

## Funktionen

- Mehrere Tester parallel: bis zu 4 aktive Tester gleichzeitig verbunden, die App verbindet sie beim Start wieder. Gerätewahl mit Typ und RSSI, Trennen, Vergessen
- Live-Daten per Bluetooth: GPS, LoRaWAN, Gateways, Pakete, Ereignis-Verlauf
- Steuerung: SEND NOW, Screenwechsel am Gerät, komplette Konfiguration, Neustart
- Countdown bis zum nächsten Auto-Uplink, LoRaWAN-Status mit TX, RX und Bereit, GPS-Status mit Standby und Aufwachen
- Stromsparen einzeln einstellbar: Prozessortakt, Helligkeit, Display-Zeit, GNSS-Standby
- Optionale Signaltöne in App und Tester: 2525 Hz senden, 1750 Hz empfangen, Dreifachgong bei Fehlern
- Log-Download per BLE, zusammengeführt mit dem Coverage-Log vom LoRaScout Server (je Tester) oder vom ioBroker
- Karte, Auswertung und Verlauf nach Tag, Monat, Jahr oder gesamt
- Export als CSV und JPG mit wählbarem Kartenausschnitt
- Lokales Archiv, Löschen auf iPhone, Tester und Server

## Voraussetzungen

Xcode 26.5, iOS 26.5 oder neuer. Bluetooth gibt es nicht im Simulator.

Coverage-Abruf nur im lokalen Netz per IP-Adresse, `.local` oder Rechnername. Das Token liegt im iOS-Schlüsselbund.

## Server

Konfig → Coverage-Server: Host, Port (leer = automatisch) und Token (Upload- oder beim LoRaScout Server auch Admin-Token). Die App fragt `GET /healthz` ohne Token ab: JSON mit `ok` bedeutet LoRaScout Server, jede andere HTTP-Antwort das ioBroker-Skript. Ohne Port probiert sie 8090, bei abgelehnter Verbindung 8099, so laufen gespeicherte ioBroker-Einstellungen ohne Änderung weiter. Ein Port im Host-Text oder in der Server-Adresse des Testers gilt ebenfalls. Konfig zeigt Typ, Version und Port, „Verbindung prüfen“ testet auch das Token.

- **LoRaScout Server:** `GET /coverage?device=<DevEUI>` je bekanntem Tester (alle gemerkten Geräte mit DevEUI). Die App hängt die DevEUI als zehnte Spalte an, die Zusammenführung gibt jede Zeile nur dem Tester mit dieser DevEUI. Kennt die App keine DevEUI, holt sie `/coverage` ohne Gerät (Standardgerät des Servers). „Auf dem Server ausblenden“ schickt `DELETE /logs?device=<DevEUI>` für den in Netz und Konfig gewählten Tester: Der Server liefert dessen bisherige Daten nicht mehr an App und Tester, behält sie aber in seiner Datenbank.
- **ioBroker:** wie bisher `GET /coverage` und `DELETE /logs` ohne Query, das Skript vergleicht die ganze URL.

Fehler: 401/403 → Token falsch, abgelehnte Verbindung → Port prüfen, 404 ohne „no coverage log“ → falscher Port bzw. abgeschaltete Endpunkte, sonst „nicht erreichbar“.

## Hinweise

TX und RX sind eine Annäherung, das LoRa-Modul meldet sie nicht getrennt. TX umfasst den ganzen Sendevorgang, RX steht für die Wartezeit auf die Netzantwort nach SEND NOW. Signaltöne der App klingen nur im Vordergrund, dafür auch bei stumm geschaltetem iPhone. Sie kommen bis zu etwa 1 s nach dem Tester.

Der Gerätetyp kommt aus dem Namen: `FieldTester-` ist der Core2, `FieldTracker-` der Tracker, alles andere gilt als allgemeiner Tester mit allen Feldern. Welche Einstellungen ein Typ hat, steht in `Protocol/DeviceKind.swift`. Beim Tracker fehlen WLAN-Upload, Signaltöne am Gerät und die Display-Auswahl. Lehnt ein Gerät einen Wert ab, zeigt die Konfiguration die Meldung.

Jeder Tester hat ein eigenes lokales Log (`fieldlog-<ID>.csv`), das bisherige `fieldlog.csv` übernimmt der zuletzt gewählte Tester. Archivzeilen tragen den Gerätenamen in der Spalte `Device`.

Mehrere Tester: `BLE/TesterCentral.swift` besitzt den CBCentralManager und die gemerkten und aktiven Geräte, `BLE/TesterSession.swift` hält je Tester Verbindung, Status, Konfiguration, Ereignisse und Log. Home zeigt mit mehreren Testern eine Karte je Tester mit eigenem SEND NOW, Netz eine Übersicht und eine Auswahl. Konfig bearbeitet den oben gewählten Tester. Meldungen nennen das Gerät, Signaltöne der App sagen danach den Kurznamen an (z. B. „Tracker C3D4“). Karte, Auswertung und Archivliste filtern nach Tester, bei „Alle“ bekommt jeder Tester auf der Karte einen eigenen Farbring.

Coverage-Log: Ohne Geräte-Spalte wie bisher nach Zeit, ein Server-Eintrag zählt nur für einen Tester. Eine zehnte Spalte oder eine Kopfzeile mit `Device`/`DevEUI` ordnet Einträge nur dem Tester mit dieser DevEUI zu. Ein Tester ohne bekannte DevEUI bekommt dann nur Zeilen ohne Gerät, so mischen sich Tester nie. Die DevEUI liest die App aus der Konfiguration des Testers und merkt sie sich.

## Aufbau

| Ordner | Inhalt |
|---|---|
| `LoRaScout/BLE` | CoreBluetooth-Verbindung |
| `LoRaScout/Protocol` | Parser, Zusammenführen, Ereignisse, Archiv als reine Funktionen |
| `LoRaScout/Network` | Netz-Abstraktion (bisher TTN), Coverage-Abruf, Token |
| `LoRaScout/Views` | SwiftUI-Oberfläche |

## Demo

Im Debug-Build zeigt das Startargument `-demo` Beispieldaten mit zwei parallelen Testern, `-demoSingle` nur einen, `-demoTab n` öffnet einen Tab. Das Release-Build enthält das nicht.
