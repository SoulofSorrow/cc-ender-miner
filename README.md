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
  Ereignisprotokoll und Touch-Buttons für Pause, Weiter und Heimkehr.

Neu geschrieben, angelehnt an das Skript "Mining Turtle 3.5" von PrinceTommen.

## Voraussetzungen

| Was | Wofür |
| --- | --- |
| CC: Tweaked | Turtle und Computer |
| [EnderStorage](https://www.curseforge.com/minecraft/mc-mods/ender-storage-1-8) | Ender Chests, auf die Turtles zugreifen können (Vanilla-Ender-Chests funktionieren **nicht**) |
| Mining Turtle mit Ender Modem | Turtle mit Spitzhacke auf der einen und Ender Modem auf der anderen Seite |
| Computer mit Ender Modem | Empfängt die Telemetrie |
| 4x4 Advanced Monitor | Farbe und Touch für das Dashboard |

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
`minermon`. Mit `--startup` wird zusätzlich eine `startup.lua` angelegt:

```sh
wget https://raw.githubusercontent.com/SoulofSorrow/cc-ender-miner/main/src/install.lua install
install monitor --startup
```

Alternativ die Dateien aus `src/` von Hand kopieren (`miner.lua` auf den
Turtle, `minermon.lua` auf den Computer).

## Benutzung

### Dashboard starten

Computer mit Ender Modem und 4x4 Monitor aufbauen, dann:

```sh
minermon        # Textgröße 0.5 (Standard, ideal für 4x4)
minermon 1      # größere Schrift
```

`Q` beendet das Programm. Mit `id` siehst du die Computer-ID. Die kannst du im
Turtle als "Monitor PC id" eintragen, dann nimmt der Turtle nur Befehle von
diesem Computer an.

### Turtle starten

Turtle an den Startpunkt stellen, mit Blick in Richtung des ersten Tunnels.
Slots wie oben belegen, dann:

```sh
miner           # zeigt die gespeicherte Konfiguration, Enter startet
miner setup     # Assistent erneut ausführen
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

**Chunk-Loading:** Turtles stoppen, sobald ihr Chunk entladen wird. Bleib in der
Nähe oder nutze einen Chunk Loader. Nach einem Neustart weiß der Turtle nicht
mehr, wo er ist. Setze ihn dann wieder auf den Startpunkt.

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
