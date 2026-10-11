# cc-ender-miner

[English version](README.en.md)

Tunnel-Mining für [CC: Tweaked](https://tweaked.cc/) Mining-Turtles mit zwei
Ender Chests und einem Live-Dashboard auf einem Monitor.

- **Turtle (`miner`)** gräbt parallele Tunnel beliebiger Größe, setzt Fackeln,
  wirft Cobblestone & Co. weg und schickt alles andere über eine Ender Chest
  nach Hause.
- **Nachschub-Kiste**: Eine zweite Ender Chest liefert Fackeln (und
  optional Kohle). Der Turtle füllt selbstständig nach.
- **Dashboard (`minermon`)** auf einem Computer mit Ender Modem und 4x4
  Advanced Monitor: Fortschritt, Treibstoff, Inventar, gefundene Erze,
  Ereignisprotokoll und Touch-Buttons für Pause, Weiter und Heimkehr. Der
  Computer ist auch die **Zentrale** zwischen Miner und Begleiter.
- **Begleiter (`follower`)**: optionaler zweiter Turtle mit Chunk-Loader-Upgrade,
  der dem Miner folgt und dessen Chunk geladen hält. Standardmäßig aus, der
  Miner arbeitet auch allein.
- **Auto-Update (`update`)**: Alle Programme halten sich beim Start selbst
  aktuell.

Neu geschrieben, angelehnt an das Skript "Mining Turtle 3.5" von PrinceTommen.

## Voraussetzungen

| Was | Wofür |
| --- | --- |
| CC: Tweaked | Turtle und Computer |
| [EnderStorage](https://www.curseforge.com/minecraft/mc-mods/ender-storage-1-8) | Ender Chests, auf die Turtles zugreifen können (Vanilla-Ender-Chests funktionieren **nicht**) |
| Mining Turtle mit Ender Modem | Turtle mit Spitzhacke auf der einen und Ender Modem auf der anderen Seite |
| Computer mit Ender Modem | Empfängt die Telemetrie |
| Advanced Monitor, 4x4 empfohlen (2x2 geht auch) | Farbe und Touch für das Dashboard |
| Optional: zweiter Turtle mit Chunk-Loader-Upgrade und Ender Modem | Begleiter, der den Chunk des Miners geladen hält |

Ein Wireless Modem geht auch, hat aber nur begrenzte Reichweite. Das Ender
Modem funktioniert unbegrenzt weit und über Dimensionen hinweg.

## Ender Chests einrichten

EnderStorage-Kisten sind über ihre drei Farbcodes verbunden. Du brauchst zwei
Paare mit **unterschiedlichen** Farben:

| Kiste beim Turtle | Gegenstück in der Basis | Inhalt |
| --- | --- | --- |
| Slot 1: Nachschub | z. B. Weiß-Weiß-Gelb | Fackeln einfüllen, optional Kohle |
| Slot 2: Ressourcen | z. B. Weiß-Weiß-Blau | Hier landet alles Abgebaute. Am besten mit Trichter/Sortieranlage leeren |

Wenn die Ressourcen-Kiste voll ist, wartet der Turtle und zeigt auf dem
Dashboard **CHEST FULL** an.

## Slot-Belegung des Turtles

| Slot | Inhalt |
| --- | --- |
| 1 | Ender Chest **Nachschub** (Fackeln) |
| 2 | Ender Chest **Ressourcen** |
| 3 | Fackeln (wird automatisch nachgefüllt) |
| 4 | Treibstoff (Kohle, Holzkohle, Kohleblock, ...) |
| 5-16 | leer lassen, hier landet das Abgebaute |

## Installation

Im Spiel muss die HTTP-API in der CC: Tweaked-Konfiguration aktiv sein (Standard).

```sh
wget run https://raw.githubusercontent.com/SoulofSorrow/cc-ender-miner/main/src/install.lua
```

Auf einem Turtle wird automatisch `miner` installiert, auf einem Computer
`minermon`. Für den Begleiter gibst du die Rolle an. Mit `--startup` wird
zusätzlich eine `startup.lua` angelegt:

```sh
wget https://raw.githubusercontent.com/SoulofSorrow/cc-ender-miner/main/src/install.lua install
install monitor --startup     # Leitcomputer
install miner                 # Mining-Turtle
install follower              # Begleiter-Turtle (bekommt auch miner.lua für die Geometrie)
```

Jede Rolle bekommt zusätzlich `update.lua`, den Auto-Updater. Alternativ die
Dateien aus `src/` von Hand kopieren.

## Benutzung

### Dashboard starten

Computer mit Ender Modem und 4x4 Monitor aufbauen, dann:

```sh
minermon        # Textgröße 0.5 (Standard, ideal für 4x4)
minermon 1      # größere Schrift
```

Auf kleineren Monitoren (z. B. 2x2) schaltet das Dashboard automatisch auf
ein kompaktes Layout: nur die wichtigsten Werte, Erze, Ereignisse und
Kurz-Buttons. Lass dort die Standard-Schriftgröße 0.5, bei `minermon 1` ist es
sehr eng.

`Q` beendet das Programm. Mit `id` siehst du die Computer-ID. Die kannst du im
Turtle als "Monitor PC id" eintragen, dann nimmt der Turtle nur Befehle von
diesem Computer an.

### Turtle starten

Turtle an den Startpunkt stellen, mit Blick in Richtung des ersten Tunnels.
Slots wie oben belegen, dann:

```sh
miner           # zeigt die gespeicherte Konfiguration, Enter startet
miner setup     # Assistent erneut ausführen
miner resume    # unterbrochenen Auftrag fortsetzen (macht die Startup-Datei automatisch)
```

Beim ersten Start fragt ein Assistent alle Werte ab und speichert sie in
`miner.cfg`.

### Grabmuster

```
 Draufsicht (side = right, 3 Tunnel, width 3, spacing 3)

   z ^   ###...###...###
     |   ###...###...###
     |   ###...###...###
     |   ###...###...###
   1 |   ###############   <- Verbindungsgang auf Höhe des Bodens
   0 |   T
     +------------------> x
```

- Der erste Tunnel beginnt direkt vor dem Turtle, weitere Tunnel liegen rechts
  oder links daneben (`side`).
- Pro Durchgang werden drei Blockreihen abgebaut (oben, Mitte, unten). Höhere
  Tunnel werden in mehreren Lagen gegraben.
- Fackeln stehen in der ersten Spalte jedes Tunnels (der Seite, auf der der
  Turtle startet) auf dem Boden, alle `torchInterval` Blöcke.
- Am Ende fährt der Turtle zurück auf den Startblock und schaut wieder nach vorne.

### Dashboard-Buttons

| Button | Wirkung |
| --- | --- |
| PAUSE | Turtle hält beim nächsten Schritt an |
| RESUME | weitermachen |
| HOME | Abbrechen und zurück zum Start (zweimal tippen zum Bestätigen) |
| REFRESH | sofortiges Status-Update anfordern |

Bei mehreren Turtles erscheinen oben Tabs. Turtles ohne Meldung seit 15
Sekunden werden als **NO SIGNAL** angezeigt.

## Konfiguration (`miner.cfg`)

| Schlüssel | Standard | Bedeutung |
| --- | --- | --- |
| `tunnels` | 3 | Anzahl paralleler Tunnel |
| `width` / `height` / `length` | 3 / 3 / 48 | Tunnelmaße in Blöcken |
| `spacing` | 3 | Massive Blöcke zwischen zwei Tunneln |
| `side` | `"right"` | Seite für weitere Spalten und Tunnel |
| `useTorches` / `torchInterval` | `true` / 8 | Fackeln setzen und Abstand |
| `dropJunk` / `junkItems` | `true` / Liste | Schrott wegwerfen statt einlagern |
| `refuelFromLoot` / `fuelItems` | `true` / Kohle | Abgebaute Kohle verbrennen, wenn Treibstoff knapp wird |
| `torchItems` | `minecraft:torch` | Was als Fackel gilt |
| `fuelReserve` / `fuelBuffer` | 100 / 1000 | Reserve über den Heimweg hinaus, nachgetankte Menge |
| `minFreeSlots` | 2 | Ab so wenigen freien Slots wird entladen |
| `reportInterval` | 2 | Sekunden zwischen Status-Meldungen |
| `controllerId` | `nil` | ID des Dashboard-Computers. `nil` sendet per Broadcast und nimmt Befehle von allen an |
| `returnOnError` | `true` | Nach einem Fehler zurück zum Start fahren |
| `useFollower` | `false` | Mit einem Begleiter-Turtle (Chunk Loader) zusammenarbeiten |

## Fehlerverhalten

| Situation | Reaktion |
| --- | --- |
| Kein Treibstoff | Zieht Kohle aus der Nachschub-Kiste, sonst Status **NO FUEL**, wartet auf Nachschub |
| Keine Fackeln | Holt Nachschub; ist die Kiste leer, wird ohne Fackeln weitergegraben (Warnung) |
| Ressourcen-Kiste voll | Wartet, Status **CHEST FULL** |
| Unzerstörbarer Block (Bedrock) | Bricht ab und fährt über Umwege zurück |
| Kies/Sand | Wird nachgegraben, bis nichts mehr nachrutscht |
| Anderer Turtle im Weg | Wird nicht abgebaut, Turtle wartet |
| Fremde Items in Nachschub-Kiste | Landen in der Ressourcen-Kiste |
| Vanilla Ender Chest | Wird vor dem Start abgelehnt |
| Chunk entladen / ausgeloggt | Läuft nach dem Neuladen automatisch weiter (siehe unten) |
| Neustart mitten in einer Drehung ohne GPS | Status **LOST**, Turtle bleibt stehen |

## Ausloggen, Chunk-Unload und Server-Neustart

Minecraft hält einen Turtle an, sobald sein Chunk entladen wird: Du loggst aus,
entfernst dich zu weit, oder der Server startet neu. Das kann kein Skript
verhindern. `miner` sorgt aber dafür, dass der Auftrag danach **von selbst
genau dort weiterläuft**, wo er unterbrochen wurde:

- Position, Blickrichtung und Fortschritt werden laufend gespeichert
  (`miner.state`, `miner.pos`).
- Beim Start legt `miner` die Datei `startup/endermine.lua` an. Wird der Chunk
  wieder geladen, startet CC: Tweaked den Turtle neu, und der Auftrag läuft
  nach 5 Sekunden weiter. Ein Tastendruck in diesem Moment bricht das ab.
- Am Ende des Auftrags werden diese Dateien wieder gelöscht.
- Startest du `miner` von Hand und es gibt einen unterbrochenen Auftrag, fragt
  das Programm, ob es ihn fortsetzen soll.
- Eine Ender Chest, die gerade draußen stand, wird nach dem Neustart wieder
  eingesammelt.
- Das Dashboard zeigt **RESUMING** und zählt die Neustarts.

**Wichtig – GPS einrichten:** Eine Bewegung, die genau beim Entladen passiert
ist, erkennt der Turtle am Treibstoffverbrauch. Eine **Drehung** verbraucht aber
keinen Treibstoff. Wird der Turtle genau während einer Drehung angehalten (das
ist selten, kommt aber vor), weiß er nicht sicher, wohin er schaut. Ohne GPS
bleibt er dann mit **LOST** stehen, statt in die falsche Richtung zu graben.
Mit GPS misst er seine Richtung neu und macht weiter. Dasselbe gilt für Server
mit unbegrenztem Treibstoff.

GPS-Turm mit Ender Modems (funktioniert in der ganzen Dimension, ein Turm
reicht):

1. Vier Computer mit je einem Ender Modem aufstellen, nicht alle auf einer
   Ebene, z. B. die Ecken eines Würfels mit einigen Blöcken Abstand.
2. Auf jedem Computer mit F3 die exakte Position **des Modems** ablesen und
   `gps host <x> <y> <z>` in die `startup.lua` schreiben.
3. Test auf dem Turtle: `gps locate` muss eine Position ausgeben.

Der Turtle erkennt GPS beim Start des Auftrags selbst und meldet
"GPS available".

**Weiterlaufen, während du weg bist:** Dafür muss der Chunk geladen bleiben:
mit dem [Begleiter-Turtle](#begleiter-turtle-chunk-loader), per `/forceload`
oder Chunk-Claim auf dem Server (FTB Chunks o. Ä.) über dem Abbaugebiet. Der
Miner selbst hat mit Spitzhacke und Ender Modem keinen freien Upgrade-Platz
mehr. Leitcomputer und Ender Chests in der Basis müssen ebenfalls geladen
sein, damit Anzeige, Weiterleitung und Kisten arbeiten.

## Begleiter-Turtle (Chunk Loader)

**Optional.** Ein zweiter Turtle mit **Chunk-Loader-Upgrade** und **Ender
Modem** (keine Spitzhacke nötig) fährt dem Miner hinterher und hält so dessen
Chunk geladen. Ohne Begleiter arbeitet der Miner genauso. Er wird nur bei
einem Chunk-Unload angehalten und macht danach weiter.
Der Leitcomputer verbindet die beiden: Er leitet Position und Fortschritt des
Miners an den Begleiter weiter.

**Einrichten**

1. Im Miner den Begleiter einschalten: `miner setup` und bei
   "Chunk loader follower" mit `y` antworten (oder `useFollower = true` in
   `miner.cfg`). Ist der Schalter aus, teilt der Leitcomputer dem Miner keinen
   Begleiter zu, und ein schon gekoppelter Begleiter wird freigegeben.
2. Begleiter mit `install follower` installieren und ein paar Kohle in sein
   Inventar legen.
3. **Direkt hinter** den Startblock des Miners stellen, mit Blick in dieselbe
   Richtung.
4. `follower` starten. Beim ersten Start fragt er nach der ID des
   Leitcomputers und optional des Miners. `-1` heißt: Der Leitcomputer teilt
   den nächsten freien Miner zu.
5. Miner starten. Auf dem Dashboard erscheint der Begleiter als eigener Tab
   mit Abstand zum Miner und dem Zustand des Chunk Loaders.

**So bleibt er aus dem Weg**

- Er fährt nur durch Blöcke, die der Miner nachweislich schon gegraben hat. Er
  gräbt selbst nie.
- Er wartet nur auf **Parkplätzen**: Das ist die oberste Reihe eines 3 Blöcke
  hohen Abschnitts im aktuellen Tunnel, durch die der Miner nie fährt, oder
  irgendwo in schon fertigen Tunneln. Bei Tunnelhöhe unter 3 parkt er nur in
  fertigen Tunneln.
- Steht er doch einmal im Weg, meldet der Miner das, und der Leitcomputer
  bittet den Begleiter, Platz zu machen.
- In Simulationen mit verschiedenen Tunnelformen stand der Begleiter dem Miner
  kein einziges Mal im Weg.

**Chunks und GPS:** Mit GPS kennt der Begleiter die Chunk-Grenzen. Er
bevorzugt dann Parkplätze im Chunk des Miners, und der Miner meldet jeden
Chunk-Wechsel sofort. In den Simulationen stand er so in über 95 % der Zeit im
selben oder einem direkt angrenzenden Chunk. Verstummt der Miner (sein Chunk
wurde doch entladen), fährt der Begleiter bis auf 2 Blöcke an die letzte
bekannte Position heran. Der Chunk wird wieder geladen, und der Miner macht
mit dem automatischen Fortsetzen weiter.

**Bitte prüfen:** Welche Chunks dein Chunk-Loader-Upgrade lädt (nur den
eigenen oder auch Nachbarn) und ob es mit `setActive` eingeschaltet werden
muss, hängt vom Mod ab. Der Begleiter schaltet Upgrades mit `setActive`
automatisch ein und zeigt "active", "passive" oder "none" an. Ohne Chunk Loader
folgt er trotzdem, hält aber nichts geladen. Im Einzelspieler hilft kein Chunk
Loader, denn beim Ausloggen hält die ganze Welt an.

Am Ende des Auftrags fährt der Begleiter **direkt vor den Miner** (Block 0/0/1)
und hält dort.

## Auto-Update

Miner, Begleiter und Leitcomputer prüfen bei jedem Start, ob es eine neue
Version gibt (`manifest.json` im `main`-Branch des Repositorys). Ist eine da,
laden sie nur ihre eigenen Dateien, prüfen jede Datei auf gültiges Lua,
ersetzen alle zusammen und starten neu.

- **Laufende Aufträge:** Ein unterbrochener Auftrag wird nur aktualisiert, wenn
  die neue Version seinen Speicherstand lesen kann. Sonst kommt das Update
  nach dem Auftrag.
- **Versionsabgleich:** Der Leitcomputer zeigt bei jedem Gerät die Version und
  warnt, wenn sie von seiner eigenen abweicht.
- **Von Hand:**

  ```sh
  update            # Rolle wird erkannt
  update follower   # Rolle angeben
  update --force    # neu installieren, auch bei gleicher Version
  ```

- **Abschalten oder eigene Quelle:**

  ```sh
  set endermine.auto_update false
  set endermine.update_url https://raw.githubusercontent.com/<user>/<repo>/<branch>/
  ```

Ohne HTTP-API oder ohne Netz läuft das Programm einfach mit der installierten
Version weiter.

## Entwicklung

```sh
make check      # luacheck, StyLua-Prüfung, Offline-Tests
make format     # formatieren
make build      # Programme nach dist/ kopieren
make release    # Tag v<VERSION> erstellen, pushen und GitHub-Release anlegen
```

Die Tests simulieren Welt, Turtle, Ender Chests und Rednet (`tests/mock_cc.lua`)
und laufen ohne Minecraft. Details stehen in [CONTRIBUTING.md](CONTRIBUTING.md).

## Lizenz

[GPL-3.0-or-later](LICENSE). Die Idee und das ursprüngliche Grabmuster stammen
aus "Mining Turtle 3.5" von PrinceTommen (für CyanideEpic). Dieser Code ist
eine eigenständige Neuimplementierung.
