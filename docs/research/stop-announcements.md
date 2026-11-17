# How buses announce stops, by country (the sentences of the stop announcer)

Source of the wording in `companion/bus_routes_data.py` (`PHRASES`). **Written from what is generally known of each country's buses,
not checked against recordings:** the web search of 2026-11-17 found no page that quotes a recorded announcement for Hungary, Romania,
Luxembourg, Portugal, Croatia or Bulgaria (operators publish timetables, not scripts). Tell what sounds wrong and it is changed in one
line per language.

| Country | Language | Stop ahead | Next stop (after the doors close) | Terminus |
|---|---|---|---|---|
| Ukraine | uk | "Зупинка X" | "Наступна зупинка: X" | "Кінцева зупинка X" |
| Czechia | cs | "X" (the stop's name; "na znamení" for a request stop) | "Příští zastávka: X" | "Konečná zastávka" |
| Slovakia | sk | "X" | "Nasledujúca zastávka: X" | "Konečná zastávka" |
| Poland | pl | "Przystanek X" ("na żądanie") | "Następny przystanek: X" | "Przystanek końcowy" |
| Germany, Switzerland | de | "X" | "Nächster Halt: X" | "Endhaltestelle" |
| Austria | de_AT | "X" | "Nächste Haltestelle: X" | "Endstation" |
| Hungary | hu | "X" | "Következik: X" | "végállomás, kérjük szálljanak le" |
| Romania, Moldova | ro | "Stația X" | "Următoarea stație: X" | "Capăt de linie" |
| France, Luxembourg, Wallonia, Brussels | fr | "X" | "Prochain arrêt : X" | "Terminus" |
| Netherlands, Flanders | nl | "X" | "Volgende halte: X" | "Eindhalte" |
| Italy | it | "X" | "Prossima fermata: X" | "Capolinea" |
| Spain | es | "X" | "Próxima parada: X" | "Final de trayecto" |
| Portugal | pt | "X" | "Próxima paragem: X" | "Fim de linha" |
| Sweden | sv | "X" | "Nästa hållplats: X" | "Slutstation" |
| Denmark | da | "X" | "Næste stop: X" | "Endestation" |
| Norway | no | "X" | "Neste holdeplass: X" | "Endeholdeplass" |
| Finland | fi | "X" | "Seuraava pysäkki: X" | "Päätepysäkki" |
| Estonia | et | "X" | "Järgmine peatus: X" | "Lõpp-peatus" |
| Latvia | lv | "X" | "Nākamā pietura: X" | "Galapunkts" |
| Lithuania | lt (read by the Latvian voice) | "X" | "Kita stotelė: X" | "Galinė stotelė" |
| Slovenia | sl | "X" | "Naslednja postaja: X" | "Končna postaja" |
| Croatia | hr (read by the Slovenian voice) | "X" | "Sljedeće stajalište: X" | "Posljednje stajalište" |
| Bulgaria | bg | "Спирка X" | "Следваща спирка: X" | "Последна спирка" |
| Greece, Cyprus | el | "X" | "Επόμενη στάση: X" | "Τέλος διαδρομής" |
| United Kingdom, Ireland, Malta | en_GB | "X" | "Next stop: X" | "This is the last stop" |
| United States | en_US | "X" | "Next stop: X" | "This is the last stop" |

## Voices (rhasspy/piper-voices, the engine release 2023.11.14-2)

The 2023 engine cannot read the voices retrained in 2025-2026 that use two-letter symbols in their config; their configs are
patched on download (`fit_config`) by dropping those symbols (diphthongs of English and Czech are read as separate sounds). For
those languages the older revision `v1.0.0` of the voices is used. Bulgarian, Estonian and Greek exist only in the new form (the
revision of 2026-11-15 is pinned: the voices are retrained in place).

The Lithuanian voices need a phonemizer the 2023 engine lacks; Croatia and Lithuania take the nearest voice of a neighbour.
Ukrainian uses the `ukrainian_tts` voice with speaker 2 (tetiana); the `high` Ukrainian voices were not loadable by the engine.
