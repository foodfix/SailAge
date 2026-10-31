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


---

# Phase 6 — task P: neutral ports + the five regional lanes

Scope: the 45 `nation_id: ""` neutral-tier ports appended to
`data/ports.json`, the re-placed `botany_bay` row, the five new lanes in
`data/trade_routes.json` (`canton_country_trade`, `coromandel_bengal`,
`swahili_coast`, `pacific_america`, `west_africa`), and the
`hanseatic_north_winter` variant. Task D of the same phase keeps its own
sections for the ocean datasets; this section covers only the task-P
content.

## Authoring policy (task P)

- **Facts, nothing vendored.** As in Phase 5: port rows carry names, WGS84
  coordinates, goods lists and one-sentence flavor, hand-authored here; no
  dataset, shapefile, or table was downloaded, converted, or bundled.
- **URLs are cited this phase.** Task P cites stable public reference URLs
  (encyclopedic articles) alongside printed works; the Phase-5 sections
  above keep their no-URL convention. Where no stable page exists for a
  small site, the port line cites the enclosing historical entity's article
  plus the contextual work.
- **Era anchor ≈ 1550–1620s.** Every port was a working seaport inside the
  window; where the game grid's 10-arc-minute cells cannot resolve a river
  town, the row sits at the rendered coast and the flavor text names the
  true site (the deliberate-loose convention of `10-DATA-SCHEMA.md` §7.1).

## The `botany_bay` re-place (master-pinned decision)

The locked id keeps its row; display name, position, nation and goods move
to Shark Bay, Western Australia — Dirck Hartog's 25 October 1616 landfall
in the *Eendracht* at Shark Bay (Cape Inscription), the first recorded
European landing on Australian soil, recorded in the VOC voyage records;
overviews at https://en.wikipedia.org/wiki/Shark_Bay and
https://en.wikipedia.org/wiki/Dirk_Hartog_Island. The 1770 Cook naming
postdates the phase anchor and is not used.

## Port bands and per-port basis (45 rows, file order)

Works used repeatedly below: *The Cambridge History of China*, vol. 8, *The
Ming Dynasty, 1368–1644* (1998); K. N. Chaudhuri, *Trade and Civilisation in
the Indian Ocean* (1985); Tomé Pires, *Suma Oriental* (c. 1512–1515); Duarte
Barbosa, *O Livro de Duarte Barbosa* (c. 1516); Jan Huygen van Linschoten,
*Itinerario* (1596); C. R. Boxer, *The Portuguese Seaborne Empire* (1969);
F. C. Danvers, *The Portuguese in India* (1894).

### China coast (13)

- **quanzhou 泉州 / Zayton** — the Song–Yuan emporium of Marco Polo's and
  Ibn Battuta's accounts, still shipping silk and ceramics under the Ming;
  https://en.wikipedia.org/wiki/Quanzhou
- **ningbo 宁波 / Mingzhou** — Yong river mouth port of the Ming tribute
  and smuggling trades; https://en.wikipedia.org/wiki/Ningbo
- **yuegang 月港 / Zhangzhou** — the single licensed export wharf of the
  1567 Longqing opening; https://en.wikipedia.org/wiki/Yuegang
- **shuangyu 双屿** — the Portuguese–Chinese smuggling anchorage razed by
  Zhu Wan in 1548; https://en.wikipedia.org/wiki/Shuangyu
- **nanao 南澳** — merchant-and-pirate island anchorage on the
  Fujian–Guangdong boundary; https://en.wikipedia.org/wiki/Nan%27ao_County
- **xiamen 厦门 / Amoy** — Yuegang's outer harbor in the Jiulong estuary;
  https://en.wikipedia.org/wiki/Xiamen
- **fuzhou 福州** — provincial capital at the head of the Min river's tidal
  water; https://en.wikipedia.org/wiki/Fuzhou
- **wenzhou 温州** — Ou river mouth port shipping kiln wares, fish and
  salt; https://en.wikipedia.org/wiki/Wenzhou
- **zhelin 柘林 (Chaozhou)** — the Raoping anchorage of eastern Guangdong
  shipping; context https://en.wikipedia.org/wiki/Raoping_County
- **qiongzhou 琼州 (Hainan)** — harbor on the Qiongzhou strait serving the
  island's sapanwood and hide trades; https://en.wikipedia.org/wiki/Haikou
- **beihai 北海 (Hepu)** — Gulf of Tonkin salt and pearl-coast station of
  old Hepu; https://en.wikipedia.org/wiki/Beihai
- **dinghai 定海 (Zhoushan)** — fishing and contraband market of the
  Zhoushan archipelago; https://en.wikipedia.org/wiki/Zhoushan
- **liujiagang 刘家港 (Taicang)** — Zheng He's treasure-fleet departure
  port at the Yangtze approaches, later an outlet for Songjiang cotton
  cloth; https://en.wikipedia.org/wiki/Zheng_He

### Japan (7)

Nanban context: C. R. Boxer, *The Christian Century in Japan, 1549–1650*
(1951); *The Cambridge History of Japan*, vol. 4 (1991).

- **hirado 平户** — Matsura Takanobu's port town, VOC factory 1609–1641;
  https://en.wikipedia.org/wiki/Hirado,_Nagasaki
- **sakai 堺** — the moat-ringed self-governing merchant city on Osaka bay;
  https://en.wikipedia.org/wiki/Sakai,_Osaka
- **yamagawa 山川 (Satsuma)** — Satsuma's southern harbor of the first
  nanban arrivals; https://en.wikipedia.org/wiki/Ibusuki,_Kagoshima
- **hakata 博多** — Kyushu's medieval international port;
  https://en.wikipedia.org/wiki/Hakata-ku,_Fukuoka
- **funai 丰后府内 (Bungo)** — Ōtomo Sōrin's nanban capital port at Ōita;
  https://en.wikipedia.org/wiki/Ōita
- **urado 浦户 (Tosa)** — Chōsokabe Motochika's sea gate in Tosa bay;
  https://en.wikipedia.org/wiki/Kochi,_Kochi
- **anotsu 安浓津 (Ise)** — one of the medieval "three ports of Japan"
  with Sakai and Hakata; https://en.wikipedia.org/wiki/Tsu,_Mie

### Korea (2)

Context: Kenneth R. Robinson, *Chosŏn Korea in the Ryūkyū-Japan-China
trade nexus*; the *samppo* (three-ports) system of Joseon-era Japanese
residence.

- **busan 釜山 (Pusan)** — seat of the Joseon-era Japanese trading house;
  https://en.wikipedia.org/wiki/Busan
- **yeompo 盐浦** — one of the three *samppo* open ports of the
  mid-Joseon Japanese residence system;
  https://en.wikipedia.org/wiki/Waegwan

### Sovereign SE Asia (7)

- **hoi_an 会安 / Faifo** — the Nguyễn port opened to Chinese and Japanese
  shipping (the Faifo of Dutch and Japanese factory records);
  https://en.wikipedia.org/wiki/Hội_An
- **banten 万丹** — pepper sultanate port frequented by English and Dutch
  fleets from the 1590s; https://en.wikipedia.org/wiki/Banten_(town)
- **jambi 占碑** — pepper port at the Batanghari river mouth;
  https://en.wikipedia.org/wiki/Jambi
- **palembang 巨港** — old Srivijaya seat shipping Musi-river pepper;
  https://en.wikipedia.org/wiki/Palembang
- **gresik 革儿昔 (Surabaya)** — Javanese entrepôt of Pires' *Geresik*,
  seat of shipwrights and merchants; https://en.wikipedia.org/wiki/Gresik
- **sulu 苏禄 (Jolo)** — pearl-and-wax sultanate whose tribute fleets
  reached the Ming court; https://en.wikipedia.org/wiki/Sultanate_of_Sulu
- **kedah 吉打** — ancient west-coast anchorage of the Malay peninsula;
  https://en.wikipedia.org/wiki/Kedah

### Mughal India / Persia / Arabia (10)

Context: Ashin Das Gupta & M. N. Pearson (eds.), *India and the Indian
Ocean, 1500–1800* (1987); Sanjay Subrahmanyam, *The Political Economy of
Commerce: Southern India, 1500–1650* (1990).

- **nagapattinam 内加帕塔姆** — Coromandel port of the Chola legacy in the
  cloth trade with Southeast Asia;
  https://en.wikipedia.org/wiki/Nagapattinam
- **masulipatnam 马苏利帕特南** — Golconda's sea gate, Pires'
  *Mesulapatão*; https://en.wikipedia.org/wiki/Machilipatnam
- **hughli 胡格利 (Bengal)** — the Portuguese settlement founded c. 1579 on
  the Hooghly; https://en.wikipedia.org/wiki/Hugli-Chuchura
- **syriam 沙廉 (Pegu)** — Filipe de Brito's teak-port fortress at the Pegu
  river mouth, 1600–1613; https://en.wikipedia.org/wiki/Thanlyin
- **dianga 迪昂 (Arakan)** — the Portuguese anchorage of the Arakan coast
  (at Sandoway); context https://en.wikipedia.org/wiki/Thandwe and
  https://en.wikipedia.org/wiki/History_of_Rakhine
- **khambhat 坎贝 / Cambay** — the Gulf-of-Khambhat emporium of Pires'
  *Cambaia*; https://en.wikipedia.org/wiki/Khambhat
- **diu 第乌** — Portuguese fortress from 1535, siege of 1538;
  https://en.wikipedia.org/wiki/Diu,_India
- **mocha 摩卡** — Red Sea port of the Ottoman-age coffee trade;
  https://en.wikipedia.org/wiki/Mocha,_Yemen
- **qalhat 哈尔哈特** — Hormuz-aligned city on the Gulf of Oman (Ibn
  Battuta's Qalhāt); https://en.wikipedia.org/wiki/Qalhat
- **hormuz 霍尔木兹** — the Portuguese fortress on Hormuz island until
  1622; https://en.wikipedia.org/wiki/Hormuz_Island

### Swahili / Red Sea (6)

Context: John Middleton, *The World of the Swahili* (1992); Duarte
Barbosa's East-Africa chapters; the *Kilwa Chronicle*.

- **zanzibar 桑给巴尔 / Unguja** — mangrove-pole and ivory anchorage in
  Kilwa's sphere; https://en.wikipedia.org/wiki/Zanzibar
- **kilwa 基尔瓦** — the *Kilwa Chronicle*'s sultanate city, outlet of the
  Sofala gold road; https://en.wikipedia.org/wiki/Kilwa_Kisiwani
- **sofala 索法拉** — the gold trade's Swahili terminus, Portuguese fort
  from 1505; https://en.wikipedia.org/wiki/Sofala
- **lamu 拉穆** — stone-town dhow port of the northern Swahili coast;
  https://en.wikipedia.org/wiki/Lamu
- **massawa 马萨瓦** — Red Sea port of the Ethiopian (amole salt-bar)
  trade; https://en.wikipedia.org/wiki/Massawa
- **zeila 泽拉** — the Horn's medieval port of the Ethiopian routes (Ibn
  Battuta); https://en.wikipedia.org/wiki/Zeila

## Lane sources (task P lanes)

### `canton_country_trade` — Malacca → Hoi An → Macau → Quanzhou → Ningbo → Hirado

- C. R. Boxer, *The Great Ship from Amacon: Macao and the Japan Trade*
  (1963) — the Macau terminus of the runs this lane feeds.
- Chang Pin-tsun, "Chinese Maritime Trade: The Case of Sixteenth-Century
  Fu-chien" (Princeton PhD thesis, 1983) — the Fujian ports' roles.
- Tonio Andrade, *How Taiwan Became Chinese* (2006) — the Taiwan-strait
  (chokepoint `taiwan_strait`) trade web.
- Roderich Ptak, *China's Seaborne Trade with South and Southeast Asia*
  (Ashgate Variorum, 2005).
- Malacca/Singapore approaches reuse the `aden_gujarat_malacca` sources
  (Pires' *Suma Oriental*; OWTRAD).

### `coromandel_bengal` — Goa → Colombo → Nagapattinam → Masulipatnam → Hughli

- Sanjay Subrahmanyam, *The Political Economy of Commerce: Southern India,
  1500–1650* (1990).
- S. Arasaratnam, *Merchants, Companies and Commerce on the Coromandel
  Coast, 1650–1740* (1986).
- K. S. Mathew, *Portuguese Trade with India in the Sixteenth Century*
  (1983) — the Goa leg.
- Ceylon approach per the Portuguese-era cinnamon-and-cloth literature
  cited in the `red_sea_india`/`aden_gujarat_malacca` sections.

### `swahili_coast` — Mozambique Island → Mombasa → Mogadishu

- John Middleton, *The World of the Swahili* (1992).
- Duarte Barbosa, East-Africa chapters (c. 1516) — Mombasa and Mogadishu
  as trading cities.
- Eric Axelson, *Portuguese in South-East Africa, 1488–1600* — the
  Mozambique channel fortress economy and the `cape_guardafui` fringing.

### `pacific_america` — Acapulco → Panama → Guayaquil → Callao → Valparaíso

- Huguette & Pierre Chaunu, *Séville et l'Atlantique* — the Pacific
  companion traffic of the fleet system.
- Peter T. Bradley, *The Lure of Peru: Maritime Intrusion into the South
  Sea, 1598–1701* (1989) — the Callao–Panama–Acapulco coastal runs.
- O. H. K. Spate, *The Spanish Lake* (1979) — the South Sea system.
- Antonio de Morga, *Sucesos de las Islas Filipinas* (1609) — Panama–Peru
  shipping notes.

### `west_africa` — Madeira → Safi → Saint-Louis → Elmina → Accra → Luanda

- John Vogt, *Portuguese Rule on the Gold Coast, 1469–1682* (1979) — the
  Elmina–Accra castle trade.
- A. F. C. Ryder, *Benin and the Europeans, 1485–1699* (1969) — the bight
  approaches.
- P. E. H. Hair, Adam Jones & Robin Law (eds.), *Barbot on Guinea*
  (Sources of African History, vol. 1) — Guinea-coast toponymy.
- Beatrix Heintze, *Studien zur Geschichte Angolas im 16. Jahrhundert* —
  Luanda (São Paulo de Luanda, founded 1576) and its trade.
- The Madeira and Moroccan legs reuse the `carreira_da_india` sources
  (Cadamosto's navigations for the Saharan coast).

### `hanseatic_north_winter` variant (Baltic freeze, months 12–3)

- The Hamburg *Bergenfahrer*: Ernst Baasch, *Die Hamburger
  Bergenfahrer-Chronik* and the Hamburg Bergen-trade literature — the
  direct North-Sea Hamburg–Bergen run used as the winter routing (the
  base lane's Baltic legs sit in the §4.18 freeze in months 12–3; the
  variant stays west of the Danish straits).
- Philippe Dollinger, *The German Hansa* (1964) — winter routing practice
  and the Danish-sounds context.
