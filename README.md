# QuickInstall

QuickInstall ist eine kleine macOS-App in Swift/SwiftUI, die das Installieren und Deinstallieren von Programmen aus `.dmg`- und `.pkg`-Dateien vereinfacht. Statt das Image zu öffnen, die App in den Programme-Ordner zu ziehen und das Image wieder auszuwerfen, öffnest du die Datei einfach per Doppelklick und klickst auf **Installieren**.

Läuft auf allen Macs mit macOS 13 (Ventura) oder neuer, als Universal Binary nativ auf Apple Silicon (M1 bis M5) und Intel.

## Funktionen

### DMG-Dateien
- Öffnet sich automatisch beim Doppelklick auf eine `.dmg` (sobald als Standard-App festgelegt, siehe unten).
- Bindet das Image unsichtbar ein (auch Images mit Lizenzvereinbarung) und listet alle enthaltenen Programme (`.app`) und Installationspakete (`.pkg`).
- **Dropdown für den Zielordner** bei jeder Installation. Vorausgewählt ist der Standardordner aus der Konfiguration; über „Anderer Ordner …“ lässt sich jeder beliebige Ordner wählen (er wird dann in die Liste übernommen).
- Kopiert die App, legt eine vorhandene ältere Version in den Papierkorb und wirft das Image danach aus.
- Fragt nur dann nach dem Administratorpasswort, wenn der Zielordner geschützt ist.
- Enthält das Image nur ein Installationspaket, geht es direkt mit dem PKG-Ablauf weiter.
- Optional: App nach der Installation öffnen, `.dmg` danach in den Papierkorb legen.

### PKG-Dateien
Bevor etwas installiert wird, zeigt QuickInstall, was das Paket tut:
- **Signatur und Notarisierung** (grün = von Apple notarisiert und von Gatekeeper zugelassen, orange = signiert, aber nicht zugelassen, rot = unsigniert). Nicht zugelassene Pakete müssen ausdrücklich bestätigt werden.
- **Warnung bei Installationsskripten**, die mit Administratorrechten laufen.
- **Welche Programme installiert werden**, welche Bestandteile (Paket-IDs, Versionen, Zielort, Anzahl der Dateien) enthalten sind.
- Installation per Apple-`installer` mit dem üblichen macOS-Passwortdialog. Unterstützt das Paket es, kann man „Nur für mich“ installieren (ohne Passwort).
- Die dabei entstandenen Paketbelege werden gespeichert, damit sich das Paket später sauber entfernen lässt.
- „Mit Apple-Installer öffnen“ ist immer möglich, z. B. für Pakete mit eigener Komponentenauswahl. In den Einstellungen kann der Apple-Installer auch als Standard für alle Pakete gewählt werden.

### Deinstallieren
Über **Ablage › Programme deinstallieren …** (⌘U) oder das Startfenster:
- **Programme**: Liste aller Programme aus `/Applications`, `~/Applications` und deinen Zielordnern (Apple-Apps ausgeblendet). Zu jeder App sucht QuickInstall zugehörige Dateien in der Library (Einstellungen, Caches, Application Support, Container, Launch Agents …). Treffer über die Bundle-ID sind vorausgewählt, reine Namenstreffer musst du selbst anhaken. Alles landet im **Papierkorb**, also wiederherstellbar. Läuft die App noch, wird sie vorher beendet.
- **Pakete (pkg)**: Liste aller installierten Fremdpakete (`pkgutil`). Beim Entfernen werden Hintergrunddienste des Pakets beendet, seine Dateien gelöscht, leere Ordner aufgeräumt und der Paketbeleg entfernt. Dateien, die auch zu einem anderen Paket gehören, sowie Systemordner bleiben erhalten.
- Apps lassen sich auch per Drag & Drop ins Fenster ziehen.

## Konfiguration

Beim ersten Start öffnet sich das Einstellungsfenster. Alle Einstellungen liegen außerdem in einer lesbaren Datei:

```
~/Library/Application Support/QuickInstall/config.json
```

Sie kann in den Einstellungen per Knopfdruck im Texteditor geöffnet werden. Änderungen werden übernommen, sobald QuickInstall wieder aktiv wird (oder über „Neu laden“).

```json
{
  "destinations" : [
    { "name" : "Programme", "path" : "/Applications" },
    { "name" : "Programme (nur ich)", "path" : "~/Applications" },
    { "name" : "Dienstprogramme", "path" : "/Applications/Utilities" }
  ],
  "defaultDestination" : "/Applications",
  "rememberLastDestination" : false,
  "confirmBeforeReplacing" : true,
  "openAppAfterInstall" : false,
  "trashImageAfterInstall" : false,
  "packageMode" : "quickInstall"
}
```

| Schlüssel | Bedeutung |
|---|---|
| `destinations` | Ordner, die im Dropdown erscheinen (`~` ist erlaubt) |
| `defaultDestination` | Vorausgewählter Ordner |
| `rememberLastDestination` | Stattdessen den zuletzt benutzten Ordner vorauswählen |
| `confirmBeforeReplacing` | Nachfragen, bevor eine vorhandene Version ersetzt wird |
| `openAppAfterInstall` | Programm nach der Installation starten |
| `trashImageAfterInstall` | `.dmg`/`.pkg` nach erfolgreicher Installation in den Papierkorb legen |
| `packageMode` | `quickInstall` (Inhalt prüfen, dann installieren) oder `appleInstaller` |

Die Installationshistorie liegt in `history.json` im selben Ordner.

## Bauen

Voraussetzung: ein Mac mit **Xcode 15 oder neuer** (oder den Command Line Tools mit Swift 5.9+).

```bash
git clone https://github.com/gigafrosxh/quick-install.git
cd quick-install
./scripts/build-app.sh            # erzeugt build/QuickInstall.app (arm64 + x86_64)
./scripts/build-app.sh --install  # zusätzlich nach /Applications kopieren
```

Alternativ `make app`, `make install` oder `make run`.

- Nur für Apple Silicon bauen: `ARCHS=arm64 ./scripts/build-app.sh`
- Mit eigenem Zertifikat signieren: `SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh`

Ohne Entwicklerzertifikat wird die App ad-hoc signiert. Auf dem Mac, auf dem du sie gebaut hast, startet sie direkt. Eine App, die du von woanders geladen hast (z. B. das ZIP aus GitHub Actions), musst du beim ersten Start per Rechtsklick › Öffnen bestätigen (ab macOS 15: Systemeinstellungen › Datenschutz & Sicherheit › „Trotzdem öffnen“).

**In Xcode:** `Package.swift` mit Xcode öffnen, dann kannst du den Code bearbeiten und mit ⌘R starten. Für die Dateizuordnung (Doppelklick auf `.dmg`/`.pkg`) wird aber das App-Bundle aus dem Skript benötigt, da nur dieses die `Info.plist` mit den Dokumenttypen enthält.

Jeder Push und Pull Request wird zusätzlich per GitHub Actions auf macOS gebaut. Die fertige `QuickInstall.zip` liegt dort als Artefakt zum Download.

## Als Standard-App festlegen

1. QuickInstall nach `/Applications` installieren (`./scripts/build-app.sh --install`).
2. QuickInstall öffnen › Einstellungen › **Standard-App** › bei `.dmg` und `.pkg` auf „QuickInstall verwenden“ klicken. macOS fragt dabei evtl. zur Bestätigung nach.

Alternativ im Finder: eine `.dmg` auswählen › ⌘I › „Öffnen mit“ › QuickInstall › **Alle ändern …**, dasselbe für eine `.pkg`.

## Aufbau

```
Sources/QuickInstall/
  App/        AppDelegate (Start, Dateien öffnen, Menü), Fenster, Installationsabläufe
  Core/       hdiutil/pkgutil/installer-Aufrufe, Konfiguration, Historie, Deinstallation
  Views/      SwiftUI-Oberflächen
Resources/    Info.plist (Dokumenttypen für .dmg/.pkg) und App-Icon
scripts/      build-app.sh (Universal Binary + App-Bundle)
```

QuickInstall nutzt nur Bordmittel von macOS (`hdiutil`, `pkgutil`, `installer`, `spctl`, `lsbom`) und benötigt keine weiteren Abhängigkeiten. Administratorrechte werden nur bei Bedarf über den normalen macOS-Passwortdialog angefordert.
