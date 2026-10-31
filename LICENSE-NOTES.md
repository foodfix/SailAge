# LICENSE-NOTES.md — licensing & provenance record

SailAge keeps its data **first-party**: everything under `data/` and `tools/`
is authored in-repo, and this file records where authoring *facts* came from.
This section currently covers the Phase-5 trade-lane dataset (task E of
`docs/IMPLEMENT-Phase5.md`).

## Scope: `data/trade_routes.json` (the 12 historical major lanes)

- **Waypoints are hand-authored historical facts.** Each `[lat, lon]` polyline
  records, as a coarse navigational fact, where the historical route ran.
  Geographical facts and routes are not copyrightable subject matter; the
  coordinate list was written by hand for this project, at the game grid's
  10-arc-minute resolution (6 tiles/degree), rounded to 0.01°.
- **Nothing is vendored.** No shapefile, dataset, chart, image, or data file
  from any external source is copied into, generated into, or bundled with
  this repository. The lane file contains only coordinates and short id
  lists authored here.
- **No share-alike or no-derivatives data was copied or included.** No
  CC-BY-ND, CC-BY-SA, ODbL share-alike, or similar-licensed route dataset was
  downloaded, converted, trimmed, or adapted. The sources below were used
  **reference-only** (read as literature/atlas context when authoring the
  facts), and their contents are not reproduced here.
- **No URLs are cited.** Links rot and fabricated ones are worse; sources are
  identified by title, author/institution, and year so anyone can find them
  offline.
- Verification note (engineering, not licensing): after hand-authoring, every
  waypoint/segment was checked against the game's own raster world map
  (`data/maps/world.png`, built by `tools/build_world.py` from the repo's
  vendored public-domain shorelines) so the lines stay on real water. That
  step derives from in-repo data only.

## Per-lane source records

Each lane lists the works used as background when hand-authoring its
waypoints, nations, goods, and chokepoint tags.

### `carreira_da_india` — Lisbon → Cape Verde → Cape of Good Hope → Mozambique channel → Goa

- Álvaro Velho (attr.), *Roteiro da Primeira Viagem de Vasco da Gama*
  (c. 1499) — the original outbound log.
- João de Barros, *Ásia: Dos feitos que os Portugueses fizeram no
  descobrimento e conquista dos mares e terras do Oriente* (1552–1563).
- Duarte Pacheco Pereira, *Esmeraldo de Situ Orbis* (c. 1505–1508) —
  Portuguese roteiro tradition, incl. the South Atlantic volta.
- C. R. Boxer, *The Portuguese Seaborne Empire, 1415–1825* (1969).
- Michael N. Pearson, *The Indian Ocean* (2003).
- OWTRAD — Old World Trade Routes project, on-line dromographic database of
  pre-modern routes (c. 1998–2005 web edition).

### `west_indies_flota` — Seville → Canaries → Caribbean → Florida strait/Gulf Stream → Azores → Seville

- Huguette Chaunu & Pierre Chaunu, *Séville et l'Atlantique (1504–1650)*
  (1955–1960) — the fleet-system documentation.
- Clarence H. Haring, *Trade and Navigation between Spain and the Indies in
  the Time of the Hapsburgs* (1918).
- Antonio de Gálvez, *Derrotero de las Islas Antillas, y de las Costas de
  Tierrafirme, y del Seno Mexicano* (1784).
- J. H. Parry, *The Discovery of the Sea* (1974).
- Spanish *derroteros* collections, Archivo General de Indias, Seville
  (manuscript sailing directions, 16th–18th c.).

### `manila_galleon` — Acapulco ↔ Manila across the dateline (out via the trade winds, home via the Kuroshio at ~40°N)

- William Lytle Schurz, *The Manila Galleon* (1939) — the standard account,
  incl. both tracks and the San Bernardino (Embocadero) passage.
- O. H. K. Spate, *The Spanish Lake* (1979).
- Antonio de Morga, *Sucesos de las Islas Filipinas* (1609) — includes the
  route and the California landfall description.
- OWTRAD — Old World Trade Routes project (c. 1998–2005 web edition).

### `venice_alexandria` — Venice → Otranto → around the Peloponnese → Rhodes area → Alexandria

- Frederic C. Lane, *Venice: A Maritime Republic* (1973).
- Eliyahu Ashtor, *Studies on the Levantine Trade in the Middle Ages* (1978).
- Fernand Braudel, *The Mediterranean and the Mediterranean World in the Age
  of Philip II* (1949).
- David Abulafia, *The Great Sea: A Human History of the Mediterranean*
  (2011).

### `venice_flanders` — Venice → Messina → Gibraltar → Lisbon area → Dover → Flanders/London

- Frederic C. Lane, *Venetian Ships and Shipbuilders of the Renaissance*
  (1934) — the state galleys' Flanders route.
- Frederic C. Lane, *Venice: A Maritime Republic* (1973).
- J. A. van Houtte, *An Economic History of the Low Countries, 800–1800*
  (1977).
- Wendy R. Childs, *Anglo-Castilian Trade in the Later Middle Ages* (1978).

### `genoa_grain` — Genoa → Sicilian channel (grain) → Ionian → Aegean → Dardanelles/Bosporus → Black Sea grain

- Roberto S. Lopez, *The Commercial Revolution of the Middle Ages, 950–1350*
  (1971).
- Steven A. Epstein, *Genoa and the Genoese, 958–1528* (1996).
- Michel Balard, *La Romanie génoise (XIIe – début du XVe siècle)* (1978) —
  the Black Sea (Romania) grain-and-colonies system.
- Kate Fleet, *European and Islamic Trade in the Early Ottoman State: The
  Merchants of Genoa and Turkey* (1999).
- Fernand Braudel, *The Mediterranean and the Mediterranean World in the Age
  of Philip II* (1949).

### `hanseatic_north` — Bergen → Dover → London/Flanders → Danish sounds → Lübeck/Danzig

- Philippe Dollinger, *The German Hansa* (1964; English ed. 1970).
- Carsten Jahnke, *Das Silber des Meeres: Fisch und Fischhandel in der
  Ostseeregion (1350–1550)* (2000).
- The Øresund Sound Dues registers (Øresundstoldregnskaber), Danish National
  Archives — from the 1420s onward; the documentary record of Baltic
  through-traffic.
- OWTRAD — Old World Trade Routes project (c. 1998–2005 web edition).

### `aden_gujarat_malacca` — Aden → Gujarat (Cambay) → Ceylon → Strait of Malacca → Malacca

- K. N. Chaudhuri, *Trade and Civilisation in the Indian Ocean: An Economic
  History from the Rise of Islam to 1750* (1985).
- Ahmad ibn Mājid, *Kitāb al-Fawā'id fī uṣūl al-baḥr wa-l-qawā'id* (c. 1490)
  — the Arab pilot's Indian Ocean sailing directions.
- Tomé Pires, *Suma Oriental* (c. 1512–1515) — first-hand on Malacca and the
  Gujarat run.
- Ashin Das Gupta, *Malabar in Asian Trade, 1740–1800* (1967).
- The *Periplus of the Erythraean Sea* (1st c. AD) — the oldest Indian Ocean
  route record.

### `red_sea_india` — Jeddah/Suakin → Bab-el-Mandeb → Aden → India west coast

- K. N. Chaudhuri, *Trade and Civilisation in the Indian Ocean* (1985).
- Ibn Jubayr, *Riḥla* (1185) — a Red Sea crossing account.
- R. B. Serjeant, *The Portuguese off the South Arabian Coast: Ḥaḍramawt
  Chronicles* (1963).
- Sanjay Subrahmanyam, *The Career and Legend of Vasco da Gama* (1997).

### `basra_muscat_india` — Basra → Hormuz → Muscat → Gujarat/Calicut

- R. B. Serjeant, *The Portuguese off the South Arabian Coast* (1963).
- F. C. Danvers, *The Portuguese in India: Being a History of the Rise and
  Decline of Their Eastern Empire* (1894).
- Holden Furber, *Rival Empires of Trade in the Orient, 1600–1800* (1976).
- OWTRAD — Old World Trade Routes project (c. 1998–2005 web edition).

### `iceland_cod` — West of England → north about Scotland (the Minch) → Iceland cod banks

- "Konungs skuggsjá" (*The King's Mirror*, c. 1250) — the oldest sailing
  directions for the Iceland run.
- G. J. Marcus, *The Conquest of the North Atlantic* (1980).
- Mark Kurlansky, *Cod: A Biography of the Fish that Changed the World*
  (1997).
- E. G. R. Taylor, *The Haven-Finding Art: A History of Navigation from
  Odysseus to Captain Cook* (1956).

### `grand_banks_cod` — English Channel → north Atlantic → Newfoundland Grand Banks

- Harold A. Innis, *The Cod Fisheries: The History of an International
  Economy* (1940).
- Mark Kurlansky, *Cod: A Biography of the Fish that Changed the World*
  (1997).
- *The English Pilot, The Fourth Book* (London, from 1689) — the Newfoundland
  and West India pilot volume.
- David B. Quinn, *England and the Discovery of America, 1481–1620* (1974).

## General reference works (all lanes)

- OWTRAD — Old World Trade Routes project, on-line dromographic database of
  pre-modern trade routes (c. 1998–2005 web edition) — used as route-shape
  background only; no data copied.
- A. E. Nordenskiöld, *Periplus: An Essay on the Early History of Charts and
  Sailing-Directions* (1897).
- E. G. R. Taylor, *The Haven-Finding Art* (1956).
- Jan Huygen van Linschoten, *Itinerario* (1596) — the leaked Portuguese
  derrotero; covers the Carreira and the India Run.
- Willem Jansz. Blaeu, *Het Licht der Zeevaerdt* (1608) — printed pilot.
- J. H. Parry, *The Age of Reconnaissance* (1963).
