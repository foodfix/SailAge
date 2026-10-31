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

## Phase 6, task D — ocean seasonal data (`wind_regions`, `ocean_currents`, `ice_regions`)

### Scope & method (Phase-6 decision 3: hand-authored, cited, nothing vendored)

The three files authored by Phase-6 task D are original data compiled from
published climatology; every value below is a fact recorded from the cited
sources, and **nothing is copied or vendored from any source**. Authoring
conventions common to all three files:

- Direction tokens in `wind_regions.json` are **wind-FROM** 8-compass
  directions (`N NE E SE S SW W NW`) plus `VAR`; month keys are exactly
  `"1"`–`"12"`.
- Polygons may include land: only water tiles inside a polygon carry
  semantics (the §4.16/§6.5 rasterization and validator group 9's
  water-coverage check consume water tiles). All rings are closed (first
  pair repeated last) and no segment spans more than 180° of longitude
  (long edges carry an intermediate vertex) — the antimeridian is only ever
  touched at an edge, never crossed by a segment.
- Regions tile all ocean between 70°N–60°S: self-checked at the tile level
  (0 overlapping water tiles; ~0.01% of band water tiles — sub-degree
  coastal slivers only — fall back to the documented `VAR` fallback).
  Where two polygons share an edge, tile-centre membership at the seam may
  resolve to either side; overlapping polygons were authored out
  (strongest-then-id-order never needs to arbitrate a real overlap).
- Current `path` arrays are the system's flow **axis in downstream order**;
  `width_tiles` is odd (3 or 5) per the §4.17 corridor-expansion pin.
  Paths are polyline axes; segments crossing the antimeridian are
  intentional (the raster is wrap-aware on x, §4.17/§6.5).

### Sources used across all three files

Public-domain or fact-cited works; URLs are landing pages (no data copied):

- NOAA Physical Sciences Laboratory — NCEP/NCAR Global Reanalysis
  (surface-wind climatology background),
  https://psl.noaa.gov/data/reanalysis/reanalysis.shtml
- NOAA AOML — Global Drifter Program (GDP), climatological mean surface
  currents, https://www.aoml.noaa.gov/phod/gdp/
- NASA JPL — OSCAR ocean surface currents project (current geometry
  cross-check), https://podaac.jpl.nasa.gov/
- NOAA Office of Coast Survey — Historical Map & Chart Collection (host of
  the digitized U.S. Hydrographic Office pilot charts),
  https://historicalcharts.noaa.gov/
- M. F. Maury, *The Physical Geography of the Sea* (1855) — the classic
  wind/current routes of the sailing era.
- H. U. Sverdrup, M. W. Johnson & R. H. Fleming, *The Oceans: Their
  Physics, Chemistry, and General Biology* (1942) — gyre geometry, boundary
  currents, monsoon circulation.
- C. S. Ramage, *Monsoon Meteorology* (1971) — Asian/Indian monsoon
  seasonal wind regimes and inter-monsoon variability.
- M. Tomczak & J. S. Godfrey, *Regional Oceanography: An Introduction*
  (2nd ed., 2003; author-hosted free edition),
  http://www.es.flinders.edu.au/~mattom/regoc/pdfversion.html — regional
  current systems (Indian Ocean monsoon drifts, Indonesian throughflow,
  East Australian/West Australian).
- Admiralty / U.S. Hydrographic Office sailing-direction and pilot-chart
  series (as era-knowledge records, facts only): *The North Sea Pilot*,
  *The Baltic Pilot*, *The Mediterranean Pilot*, *The West India Pilot*,
  *The Red Sea and Gulf of Aden Pilot*, *The India Pilot*, *The China Sea
  Pilot*, and the H.O. *Pilot Chart* series of the North Atlantic, North
  Pacific, South Atlantic and Indian oceans.

### `data/wind_regions.json` — 25 regions (per-region records)

Monthly prevailing (wind-FROM) tokens, condensed. `steady` unless marked
**variable**. All regions tile the 70°N–60°S ocean band; polygons are
rectilinear boxes/notched boxes as authored.

- `westerlies_n_atlantic` — N Atlantic & European westerlies; L-box
  (38–70°N, 76°W–1°W) + (48–70°N, 1°W–122°E). Months: winter SW, remaining
  W. Source: Maury (1855); H.O./Admiralty North Atlantic pilot charts;
  NCEP/NCAR reanalysis climatology. Covers the North Atlantic Drift zone,
  Iceland/Faroes, North Sea, Baltic and Norwegian coast.
- `mediterranean_winds` — Mediterranean belt; box (30–48°N, 1°W–54°E).
  Months: Oct–Apr W, May–Sep N (the etesian regime). Sources: *The
  Mediterranean Pilot* (Admiralty); NCEP/NCAR reanalysis. The May–Sep N
  token coarsens the seasonal etesians (peak Jul–Aug). The box's Atlantic
  fringe (Portugal/Morocco NW coast) shares the summer-northerly (nortada)
  and winter-W regime; the Black and Caspian seas are folded in (coarse).
- `westerlies_n_pacific_west` — NW Pacific; L-box (40–70°N, 122°E–180°) +
  (32–40°N, 132°E–180°). Months: Nov–Apr NW (winter monsoon outflow), May–Aug
  S, Sep–Oct W. Sources: H.O. Pilot Chart of the North Pacific; Ramage
  (1971). Covers Sea of Japan/Okhotsk/Kamchatka/Bering west side.
- `westerlies_n_pacific_east` — NE Pacific; L-box (32–70°N, 180°–130°W) +
  (38–70°N, 130°W–115°W) + (45–70°N, 115°W–76°W). Months: Nov–Mar SE
  (Aleutian-low cyclonic regime), Apr S, May–Sep NW, Oct S. Sources: H.O.
  Pilot Chart of the North Pacific; NCEP/NCAR reanalysis. The east limb
  (45–70°N) extends the region over Hudson Bay and the Canadian subarctic
  margin so the bay is tiled; Hudson Bay's local winter flow (NW-ly) is a
  recorded coarsening.
- `winds_gulf_of_mexico` — box (18–32°N, 98°W–83°W). Months: Oct–Mar N
  (winter "northers"), Apr–Sep SE. Sources: *The West India Pilot*; H.O.
  pilot charts. Includes the Bay of Campeche south to 18°N.
- `trades_n_atlantic` — box (8–38°N, 83°W–1°W) with the Africa-corner notch
  (30–38°N, 12°W–1°W). Months: NE year-round. Sources: Maury (1855);
  H.O./Admiralty North Atlantic pilot charts. Covers the Caribbean,
  Sargasso, Canaries basin and Morocco NW coast.
- `trades_central_america` — box (8–18°N, 98°W–83°W). Months: Jan–Apr NE,
  May–Sep SW, Oct–Dec NE. Sources: H.O. North Pacific pilot charts
  (Tehuantepec/Papagayo gap-wind coasts); NCEP/NCAR reanalysis. The winter
  NE / summer SW flip is the Pacific-Central-America regime; the localized
  gap jets themselves are sub-monthly and coarsened away.
- `winds_california` — box (18–38°N, 130°W–115°W). Months: NW year-round.
  Sources: H.O. North Pacific pilot charts; Sverdrup et al. (1942)
  (upwelling-wind regime). Includes the Baja offshore corridor and (coarse)
  the Gulf of California margin.
- `trades_n_pacific_main` — notched box (8–38°N, 180°–98°W) minus
  (18–38°N, 130°W–115°W) (the California box) and minus
  (32–38°N, 180°–130°W) (the NE-Pacific box). Months: NE year-round.
  Sources: Maury (1855); H.O. Pacific pilot charts. Covers Hawaii and the
  trade-wind core of the E-Pacific.
- `doldrums_pacific` — box (0–8°N, 180°–88°W). **VAR year-round,
  variable.** Justification: the equatorial calm belt/ITCZ has no
  prevailing compass direction (Maury 1855 named it; NCEP/NCAR reanalysis
  confirms weak variable surface flow).
- `doldrums_atlantic` — box (0–8°N, 88°W–44°E). **VAR year-round,
  variable.** Same ITCZ justification; spans the Atlantic equatorial belt
  and Gulf of Guinea, where the ITCZ sits at or south of 8°N year-round
  (Ramage 1971). Edges shared with the monsoon boxes at 44°E.
- `tropics_w_pacific` — L-box (4–22°N, 118°E–132°E) + (4–32°N,
  132°E–180°). Months: Jan–Mar NE, Apr E, May–Sep **VAR**, Oct–Dec NE.
  **variable**. VAR justification: the typhoon regime — the region is the
  world's principal tropical-cyclone basin in Jun–Sep, with no steady
  prevailing direction (Ramage 1971; *The China Sea Pilot*).
- `monsoon_south_china_sea` — box (4–24°N, 100°E–118°E). Months: Oct–Mar
  NE (northeast monsoon), Jun–Aug SW (southwest monsoon), Apr/May/Sep
  **VAR** (inter-monsoon transitions). **variable**. Sources: Ramage
  (1971); *The China Sea Pilot*.
- `monsoon_e_china` — L-box (22–40°N, 118°E–132°E) + (40–41°N, 118°E–122°E).
  Months: Jan–Apr NE (winter monsoon/cold-air outflow), May–Aug S (summer
  monsoon inflow), Sep E. Sources: Ramage (1971); *The China Sea Pilot*.
  Covers the East China/Yellow/Bohai seas and Korea Strait approaches.
- `monsoon_arabian_sea` — box (0–30°N, 44°E–75°E). Months: Jan–Apr NE,
  May–Oct SW, Nov–Dec NE. Sources: Ramage (1971); *The India Pilot*;
  Sverdrup et al. (1942). The SW monsoon (Findlater jet) is among the
  steadiest winds on Earth — hence `steady`. The Persian Gulf's local
  Shamal (NW) is a recorded coarsening of the box's north tip.
- `red_sea_northerlies` — box (12–30°N, 32°E–44°E). Months: N year-round.
  Sources: *The Red Sea and Gulf of Aden Pilot* (Admiralty); NCEP/NCAR
  reanalysis. The famous channel northerlies; the southern reach's summer
  S/SW shift is a recorded coarsening.
- `monsoon_bay_of_bengal` — box (0–30°N, 75°E–100°E). Months: Jan–Apr NE,
  May–Sep SW, Oct–Dec NE. Sources: Ramage (1971); *The India Pilot*. Same
  seasonal flip as the Arabian Sea; `steady` for the same reason.
- `trades_s_atlantic` — box (32–0°S, 80°W–22°E). Months: SE year-round.
  Sources: Maury (1855); H.O. South Atlantic pilot charts.
- `trades_s_indian` — box (32–0°S, 22°E–100°E). Months: SE year-round.
  Sources: H.O. Indian Ocean pilot charts; Sverdrup et al. (1942)
  (Mascarene high trades).
- `trades_indonesian_seas` — box (12°S–4°N, 100°E–135°E). Months: Nov–Mar
  W (Asian NE monsoon crossing the equator), May–Sep E (Australian winter
  monsoon), Apr/Oct **VAR** (inter-monsoon). **variable**. Sources:
  Tomczak & Godfrey (2003); Ramage (1971). Covers Malacca approaches,
  Java/Banda/Flores/Timor seas, Makassar Strait and the Sulawesi Sea.
- `trades_s_pacific_west` — box (32°S–4°N, 135°E–180°). Months: SE
  year-round. Sources: H.O. Pacific pilot charts. Covers the Coral Sea,
  Tasman margin and (coarse, 0–4°N limb) the equatorial W-Pacific.
- `trades_s_pacific_east` — box (32–0°S, 180°–80°W). Months: SE year-round.
  Sources: H.O. Pacific pilot charts; Sverdrup et al. (1942) (South
  Pacific high trades).
- `trades_australia` — box (32–12°S, 100°E–135°E). Months: SE year-round.
  Sources: H.O. Indian Ocean pilot charts; Tomczak & Godfrey (2003)
  (SE trades over NW Australia).
- `westerlies_s_eastern` — box (60–32°S, 20°E–180°). Months: W year-round.
  Sources: Maury (1855); H.O. Indian Ocean pilot charts ("roaring
  forties": steady west winds).
- `westerlies_s_pacific_atlantic` — box (60–32°S, 180°–20°E). Months: W
  year-round. Sources: Maury (1855); H.O. South Atlantic pilot charts.
  Drake-passage westerlies included.

### `data/ocean_currents.json` — 23 systems (per-system records)

`strength`: 3 = western-boundary jets, 2 = most gyre limbs, 1 = slow
drifts — per the task's strength map. Widths: 5 tiles for the three jets +
Antarctic Circumpolar + Monsoon drift, 3 tiles elsewhere. Axis geometry and
flow direction are facts from the cited sources; axes are smoothed to
5–12-point polylines.

- `gulf_stream` (3, w5) — Florida Straits → Cape Hatteras → Grand Banks.
  Sources: GDP climatology; Sverdrup et al. (1942); Maury (1855) (the Gulf
  Stream's first modern charting).
- `north_atlantic_drift` (1, w3) — Grand Banks tail → British Isles →
  Norwegian Sea. Sources: GDP climatology; Sverdrup et al. (1942).
- `canaries_current` (2, w3) — S-flow off NW Africa. Sources: GDP
  climatology; Sverdrup et al. (1942).
- `north_equatorial_atlantic` (2, w3) — W-flow, 13–15°N Atlantic. Sources:
  GDP climatology; Maury (1855).
- `labrador_current` (2, w3) — S-flow from the Labrador Sea to the Grand
  Banks. Sources: GDP climatology; Sverdrup et al. (1942).
- `kuroshio` (3, w5) — east of Luzon → east of Taiwan → south of Japan →
  extension. Sources: GDP climatology; Sverdrup et al. (1942); Tomczak &
  Godfrey (2003).
- `oyashio` (2, w3) — SW-flow off Kamchatka/Kurils to off Hokkaido.
  Sources: GDP climatology; Tomczak & Godfrey (2003).
- `north_pacific_drift` (1, w3) — Kuroshio-extension tail eastward across
  the dateline to the US west coast. Sources: GDP climatology; Sverdrup et
  al. (1942). Path crosses the antimeridian (wrap-aware segment).
- `north_equatorial_pacific` (2, w3) — W-flow 13–17°N, Philippines to
  Central America (crosses the antimeridian). Sources: GDP climatology;
  Maury (1855).
- `california_current` (2, w3) — S-flow off the US/Mexico west coast.
  Sources: GDP climatology; Sverdrup et al. (1942).
- `humboldt_current` (2, w3) — N-flow along Chile/Peru, turning west at the
  equator. Sources: GDP climatology; Sverdrup et al. (1942).
- `south_equatorial_pacific` (2, w3) — W-flow 5–14°S across the basin
  (crosses the antimeridian). Sources: GDP climatology; Maury (1855).
- `south_equatorial_atlantic` (2, w3) — W-flow 7–10°S from the Gulf of
  Guinea into the open S-Atlantic. Sources: GDP climatology; Sverdrup et
  al. (1942).
- `brazil_current` (2, w3) — S-flow along the Brazil coast. Sources: GDP
  climatology; Sverdrup et al. (1942).
- `benguela_current` (2, w3) — N-flow up the SW-African coast. Sources: GDP
  climatology; Sverdrup et al. (1942).
- `agulhas_current` (3, w5) — S-flow in the Mozambique channel along the
  African coast, retroflecting east/southeast south of Madagascar. Sources:
  GDP climatology; Sverdrup et al. (1942); Tomczak & Godfrey (2003).
- `antarctic_circumpolar` (2, w5) — eastward ring at ~49–52°S, closing the
  circle through the dateline. Sources: Sverdrup et al. (1942); Tomczak &
  Godfrey (2003); OSCAR geometry.
- `somali_current` (2, w3, `reversal {"summer_months": [6,7,8,9],
  "direction": "reverse"}`) — coast-parallel axis off Somalia, stored in
  **downstream order of the non-summer (NE-monsoon, Dec–May) regime**
  (southward along the coast); the pinned summer flip yields the strong
  SW-monsoon jet flowing northeastward. Sources: Sverdrup et al. (1942);
  Tomczak & Godfrey (2003); Ramage (1971). See "Open questions" below for
  the stored-vector wording.
- `monsoon_drift` (1, w5) — eastward N-Indian equatorial drift axis
  ~5–7°N, Somalia to the Andaman Sea. Sources: Sverdrup et al. (1942);
  Tomczak & Godfrey (2003) (the monsoon current's annual-mean axis; the
  seasonal W/E flip is sub-resolution for a strength-1 drift).
- `south_equatorial_indian` (2, w3) — W-flow 11–16°S. Sources: GDP
  climatology; Tomczak & Godfrey (2003).
- `west_australian_current` (1, w3) — weak N-flow offshore of WA. Sources:
  Tomczak & Godfrey (2003); GDP climatology.
- `east_australian_current` (2, w3) — S-flow along the east Australian
  coast into the Tasman. Sources: Tomczak & Godfrey (2003); GDP
  climatology.
- `indonesian_throughflow` (2, w3) — Pacific-to-Indian flow: Sulawesi Sea →
  Makassar Strait → Flores Sea → open Indian Ocean south of Java. Sources:
  Tomczak & Godfrey (2003); GDP climatology.

### `data/ice_regions.json` — locked initial set (3 regions)

Months wrap the year end per §4.18; polygons cover the seas' waters (and
may include land — only water tiles freeze); all stay south of the
permanent `I` band (≥ 70°N).

- `baltic_ice` — months 12, 1, 2, 3. Baltic seasonal ice (freeze-up
  Nov–Dec in the northern Bothnian Bay, break-up Apr–May in the far north;
  coarsened to the locked 12–3 window for the whole basin). Polygon covers
  the Baltic proper, Gulf of Finland, Gulf of Riga and the Gulf of Bothnia
  to its head (~66°N) and **excludes the Kattegat/Skagerrak/Danish-sound
  waters** — the Baltic exits stay navigable all winter, so the winter
  reachability of the Baltic ports rides on the `hanseatic_north` lane
  variant (task P), not on the ice. Sources: Finnish Meteorological
  Institute Baltic ice-climate statistics,
  https://en.ilmatieteenlaitos.fi/ ; *The Baltic Pilot* (Admiralty).
- `hudson_bay_ice` — months 11, 12, 1, 2, 3, 4. Hudson Bay freezes
  west/east-first from Nov and clears from Jun (coarsened to 11–4). Polygon
  covers the bay, James Bay and Hudson Strait. Sources: Canadian Ice
  Service regional ice climatology,
  https://www.canada.ca/en/environment-climate-change/services/ice-forecasts.html
  ; A. J. W. Catchpole, Hudson Bay sea-ice studies (1980s, historical
  climatology).
- `white_sea_ice` — months 11, 12, 1, 2, 3, 4. The White Sea freezes
  Oct–Nov and clears May–Jun (coarsened to 11–4). Polygon covers the basin,
  Kandalaksha/Onega/Dvina/Mezen bays and the Gorlo/Voronka entrance, north
  edge ~67°N — well south of the permanent `I` band. Sources: Arctic and
  Antarctic Research Institute (AARI) Russian Arctic seas ice climate,
  http://www.aari.ru/ .

### Open questions & coarsening notes (reported, not invented)

1. **Somali stored-vector wording.** `10-*` §4.17 calls the raster vector
   the "annual-mean" flow, flipped during `reversal.summer_months` at
   lookup. The annual-mean Somali flow is dominated by the strong
   SW-monsoon jet (N-ward); flipping that at lookup would put the S-ward
   state in summer — backwards. Task D therefore stores the axis in the
   **non-summer regime's** downstream order (winter, S-ward) so the pinned
   `summer_months: [6,7,8,9]` flip produces the true summer jet. Task E/F
   implementers should read "annual-mean" as "the stored, non-flipped
   state"; no schema change is needed.
2. The `winds_california` / `trades_n_pacific_main` boundary at 115°W
   slices the Gulf of California lengthwise; its tiles resolve either way
   (NW- vs NE-token). Coarse by design; the real gulf has an N-winter /
   S-summer local regime of its own.
3. `westerlies_n_pacific_east` carries the Aleutian regime's SE-winter
   token east to 76°W at high latitudes (Hudson Bay margin). Hudson Bay's
   local winter flow is NW-ly; accepted coarse to keep the region count at
   the §4.16 cap of 25 (the set is exactly at the cap — any future new
   region must merge or remove another).
4. ~158 water tiles (0.013% of the 70°N–60°S band) sit in sub-degree
   coastal slivers outside every polygon and fall back to the documented
   `VAR` + `variable` default; no antimeridian column remains unassigned.
5. `ui_strings.json`: **no new keys** — none of this task's content is
   UI-frame text; all display strings live in the three data files as
   L10nStrings.


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
