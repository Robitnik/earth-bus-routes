# Changelog

## 0.10.3

- **The stop markers on the road are back.** Since 0.9.2 the light fill of the bay was handed to the game's drawer in a form it refuses, so the first frame of every trip failed and all the markers (corners, arrow, name) and the ghost turned themselves off for the session. Fixed; and if one part cannot be drawn now, only that part goes (the fill, the name), not the rest.
- **The next stops on the minimap.** The game's minimap shows the next stop as a dot in the colour of its bay (red coming, orange in it, grey out of service), with a pointer from the minimap's edge while it is out of view, and the eight after it as small yellow dots; the stop you drive to before a trip too. BeamNG.Earth's own map has no way for an add-on to mark places, so its GPS line stays as it was. "Stop markers in the world" turns both off.
- **All the languages of the game, in the menu and on the HUD.** English, Ukrainian, German, Spanish, French, Japanese, Korean, Polish, Portuguese (Brazil and Portugal), Russian, Simplified and Traditional Chinese. The add-on follows the game's interface language; a drop-down in the menu picks another (or "Auto"). The HUD follows the menu's choice. The texts were translated by a model and have not been read by native speakers: tell what sounds wrong. The Lua toasts and the add-on's option labels stay English.
- No data service update needed (stays 0.10.1).

## 0.10.2

- **The settings are back.** BeamNG.Earth takes at most 16 options for an add-on (and 300 letters of help each); 0.10.0 had 20, so Earth dropped all of them and none showed in the game. Now 16: "Next trip from here", the LED board and the depot start are always on (the shift's start still has its depot checkbox), and "AI buses on the lines" is one choice: off, or how many (1, 2, 3, 4 or 6). A test checks the list against Earth's own rules.
- No data service update needed (stays 0.10.1).

## 0.10.1

- **No more five-minute waits for a route.** The moving buses of 0.10.0 loaded up to 30 lines in the background, and the data service asks the public servers one at a time, so the route you picked waited behind them (300 s and more). Background loads now take only what the service keeps on this computer (a timetable line whose road was never asked for moves straight between its stops on the map); they never ask a public server.
- **The open menu no longer stutters.** The moving dots and the departure board were sent with the whole menu (hundreds of map stops) every 2 seconds; they now come as a small update of their own every 3 seconds.
- The departure board on a station's lines page sits below the lines instead of squeezing them into a strip.
- Data service 0.10.1 (update it too: `/v1/route?id=..&cached=1`).

## 0.10.0

A big one: shifts, a career, events on the road, a ghost, driving rules, and real buses of the lines (experimental, off by default). Everything new has its switch in the add-on settings.

- **Next trip from here.** A card at the top of the Stops tab shows the nearest departure from the stop you stand at (a real timetable time in Czechia, "estimated" elsewhere); one press starts it. Within 20 minutes you wait at the stop, later the game clock jumps to it.
- **LED board and live comfort on the HUD.** The next stop, "on request" (the OpenStreetMap `request_stop` tag) and "stop requested", with the game's own bell. People standing beyond the seats, a coffee cup that sways with the ride, and a hard brake with people standing makes one fall (-30 comfort, at most once in 20 s).
- **Shifts with a dispatcher.** "Start a shift" (1, 2 or 4 hours of game time): trips follow one another with layovers at the termini; a late bus eats its layover, the next trip may start late, a trip too late is lost. In Czechia the chain comes from the real timetable (data service `/v1/shift`), elsewhere it is the same line there and back. Optional start with an empty service run from the nearest bus depot. A summary page at the end.
- **Transfers, events, tickets.** The dispatcher asks you to wait for another line at a hub: wait with the doors open and its passengers board (+service); leave early and they miss it (-service). Short events: a school group, a wheelchair user, a crowd after a match, a stop out of service (grey marker, drive past), "stop please", a forgotten bag; at most one per 10 minutes. On suburban and intercity lines the driver sells tickets: a quarter of the boarders, +1.5 s each, at most +12 s a stop.
- **Ghost of your best trip** on the same line from the same stop: a translucent bus on the road and "+0:12" on the HUD.
- **Career.** Credits per shift and trip, ranks (Trainee, Driver, Experienced, Mentor) from shift hours and grades, a Profile tab, the lines you have driven drawn on the map with ticks on the towns and stations you visited, 25 achievements. Free play stays fully open; the career only counts.
- **Rules.** The turn signal when pulling out of a stop (off for the trip if the vehicle never reports it), the speed limit of the road (OpenStreetMap `maxspeed`, else the country's built-up and open-road limits) with a sign on the HUD, a warning for doors open while moving.
- **Buses of the lines on the map.** Every trip that runs near you moves as a dot on the Map tab and a live departure board shows the next buses of a station (data service `/v1/departures`).
- **Real AI buses (EXPERIMENTAL, off by default: "AI buses on the lines" in the add-on settings).** A few real buses drive their lines' routes by the timetable on the game's AI plus our driver (traffic lights, stop signs, giving way, the bay at the stop, doors, indicators), made and put away out of your sight, never left stuck (a watchdog ladder in the bus and a second one in the pool). A transfer you wait for can become a bus you see arrive. **None of this has been tried in the game yet**, which is why it is off; try it with 1 or 2 buses and tell what happens.
- Faster: finding where on the route a bus is no longer scans the whole line twice a second.
- Data service 0.10.0 (update it on the Add-ons page too): `/v1/shift`, `/v1/depot`, `/v1/connections`, `/v1/departures`, speed limits in routes.

## 0.9.2

- **Stop markers as in the game's own bus mode.** The next stop's bay on the road gets the game's four corner markers (the shape its bus mode uses): red while you come, orange while the bus is in the bay, green when the stop is done, then they fade. Over them: a light fill of the same colour, an arrow of the way to stand, and one line with the stop's name and how many wait (no more boxes for line breaks; the line and its end are on the HUD). The stops after it are only outlined; the tall pole and the ball are gone. The fill was not drawn before (the drawer the game has is drawTriSolid).
- No data service update needed.

## 0.9.1

- **A slow OpenStreetMap request no longer holds up the menu.** The mod asked the data service one thing at a time, so the map of towns (answered from the disk in milliseconds) waited behind a route that Overpass took three minutes to refuse. Up to three requests now run at once (the service still asks the public servers one at a time); a background prefetch gives way to what you wait for.
- The stops round you asked while the national timetables were still downloading are no longer kept for the session: once they are ready the lines come from them (361, 375 at Police).
- Data service 0.9.1.

## 0.9.0

- **Stations and stops on the map.** The Map tab shows every stop round you as a dot; bus stations and the busiest stops get a chip with their name. A town's chip brings the map closer, with a chip for each of its stops ("‹ Whole map" goes back, "Its stations as a list" is the old list). Pick a stop or a station: its lines are shown, with **Route there (GPS)**, **Teleport** and **Lines here** (its From here / To here / Through tabs).
- The stops come from the data service's own data (the timetables and every stop it has seen): 20 ms for 25 km, nothing asked of the public servers.
- Data service 0.9.0 (update it on the Add-ons page too): `/v1/mapstops`; the timetable index has the line numbers of each stop (built again once, about a minute).

## 0.8.0

- **Every bus line of the country, with its real timetable (Czechia first).** The data service downloads the national timetable register once (CIS JŘ through the JrUtil project: 13 000 lines, 37 000 stops; 124 MB, about a minute to download and prepare, shown in the progress line), keeps it on this computer and refreshes it weekly. Lines the map lacks now appear: at Police nad Metují bus station 361 and 375 (and 360, 363, 305, each both ways) are listed under From here / To here / Through. A line made from the timetable has all its stops in the right order; the road through them comes from the routing server.
- **The real timetable is used**: the departures of the line on that weekday (the first shown is the real first bus) and the time at every stop, instead of the generated ones. A "Real timetable" badge marks such a line. The made-up opposite direction of a line is still generated.
- **The stops and lines of a place come at once** from the timetable even when the map server is slow or down (waits for it 1.5 s, then answers; the map's lines and stations are added the next time). Stops by name and lines by number are found in the timetable too.
- Off switch: start the service with the environment variable `BNE_BUSDATA_GTFS=0`. Timetables © CIS JŘ (the Ministry of Transport; no conditions), stop positions © OpenStreetMap contributors / open data of towns (see the footer).
- Data service 0.8.0 (update it on the Add-ons page too).

## 0.7.0

- **Towns are found as you type, in milliseconds.** The data service keeps the towns and villages of the countries round you on this computer (GeoNames: Czechia 1.6 MB, Poland 2 MB, plus the world's big towns, downloaded once in the background and refreshed monthly). Typing "Pol" shows Police nad Metují at once (2 to 30 ms); Enter adds the geocoder's answer in one request (under a second, was three requests and up to two minutes when it fell back to Overpass). The map database is asked only when neither knows the name.
- **The map of towns opens at once** from the same files (8 ms; was an Overpass query that often failed after minutes).
- Data service 0.7.0 (update it on the Add-ons page too). Towns © GeoNames, CC BY 4.0 (in the menu's footer).
- **"From here" / "To here" / "Through" read the line's own words when its list of stops is out of order.** At Police nad Metují the OSM relation of 360 to Teplice lists its stops shuffled (the bus station 8th of 16) and 363 starts its list at the school next door: both were under "Through". A station in the middle of the list that the line's tags *and* name call its start or end is now that end (when the two disagree, the order stays). "aut.st." and "autobusové stanoviště" are one name.
- **A relation whose stops the road cannot follow** (two or more steps backwards) is laid out by the road, like an old relation: 360 from Police now starts at the bus station, then the school.

## 0.6.0 (after the first playtest)

- **Stops are zones along the road, not points.** A stop counts when the bus is level with it on the road (35 m along it), even when the platform is across a wide street; a stop the bus drives past is passed, so the stop number always moves on (a missed first stop no longer holds the trip back). The place along the road is tracked so a road driven out and back (or a loop crossing itself) is not confused.
- **A trip that begins away from its first stop waits for the bus there** like for any other stop.
- **No teleport and no turning of the bus when you got there yourself** (within 250 m of the start stop, or when you drove to it with the GPS). The bus is only turned after our own teleport.
- **The platform on the right of the way of travel.** The data service now also fetches the bus stops near the road (the other direction's platforms); the stop of a line is the one on your side, and the generated opposite direction uses the platform across the road.
- **Circular lines start where the map says**: 363 at Police nad Metují starts and ends at the bus station, not the school.
- **Stop markers in the world**: a yellow zone on the road at the next stop (the two after it lighter), a pole and a text over it ("305 → Hradec Králové / stop / 3 waiting"), drawn with BeamNG.Earth's coordinates. Option "Stop markers in the world". If the game or Earth cannot draw them, they turn themselves off and the GPS stays.
- **A timetable that follows the road**: each leg has its own speed (town streets slow, open road 60 km/h), plus time for slowing down for stops. 305 Náchod to Hradec Králové runs about 69 minutes, not 101, so a fast driver is no longer an hour and a half early.
- **Search is fast and finds towns**: the data service asks a geocoder (Photon) for towns and stops by name (under a second), keeps the answers and keeps the old slow way as a fallback. Results show the towns as chips: a town opens its stations; in the route builder a town adds its main station.
- **Map of towns**: a "Map" tab with a chip for every town and village round you; a chip opens the town's stations. In the route builder "Towns on the map" shows chips too; one click adds the town's main station and the road is found.
- **Progress**: a bar under the title says what the data service is doing ("OpenStreetMap server 2 of 4: route · 18 s · 1 more waiting"), updated every second.
- Data service 0.6.0 (update it on the Add-ons page too): `/v1/search` via the geocoder, `/v1/towns`, `/v1/progress`, route answers with the near bus stops, quiet fallbacks.

## Data service 0.4.1

- A client that hangs up while the answer is sent (the game cancelling a request) no longer prints a traceback: BeamNG.Earth's Add-ons page showed it as "stopped with an error".

## 0.5.0

- **Search by line number**: the first screen has a search box for a station name *or* a line number ("363", "N1"). A number lists the lines with it within 40 km, each direction and variant; pick one to see its card and start it from its first stop (teleport, or drive there with the GPS). A name lists stations, nearest first; pick one to open its three tabs.
- **Much faster search**: the data service keeps an index of every stop, station and line it has ever seen, so results appear as you type, in milliseconds, even offline. The public servers are asked in addition (Enter or the button) and fill in what the index did not know; whatever they find is indexed for next time. Before, every search waited for Overpass, often a minute.
- Matching ignores accents and case ("nachod" finds Náchod).
- In the route builder, the same search box also takes a line number: it lists the lines, and a picked line offers its stations, in the order of the line, to add to your route.
- Needs data service 0.4.0 (an older one still searches by name, the slow way; number search needs the new one).

## 0.4.1

- **Opposite direction for every line**: when the map has no line the other way (OpenStreetMap often maps one direction only, as with 305), "Opposite direction" drives the same road and the same stops in reverse; it is marked as such. A real opposite line from the map still wins when there is one. Also after a trip: "Drive back".

## 0.4.0

- **Three tabs at a station**: *From here* (lines that start at it), *To here* (lines that end at it), *Through here* (lines that call on their way). A circular line is in the first two. The tab with lines opens first; each shows how many lines it has.
- **A line that ends here can be driven from its start**: Broumov to Náchod appears at Náchod under *To here*, and starts at Broumov.
- **Two ways to get to the start**: "Teleport to the start and go" (as before), or "I will drive to the start": the GPS leads there, the HUD counts the distance, and the trip begins by itself when you arrive and stop (the first departure after the clock plus two minutes). A teleport or a new start cancels the wait.
- **Through lines** start from this stop or from the first one, as before.
- Needs data service 0.3.0 for the exact place of a station in a line (the order of stops); with an older service the tabs are guessed from the names of the line's ends (marked with ~).

## 0.3.2

- Loops and roads driven out and back (line 363 at Police nad Metují): the stops of a PTv2 line get their places along the road in the
  order the relation lists them, choosing between the several places a stop is passed (best total fit), and a loop is turned to start
  at its first stop. Before, nearly all stops piled up at the end of the road, with no ride time between them.

## 0.3.1

- Text fields (station search, line number, name) work in the game: the game is told that a field has the focus (`setCEFTyping`), so the keys are no longer taken as controls.

## 0.3.0

- **Manual mode, "Build your own route"**: choose the stations one after another (the nearest bus stations and stops, or a search
  by name up to 40 km away); the road between them is found (OSRM) and shown on a small map; the bus calls at every stop on the
  way (switch single ones off) or only at your stations; give the line a number, a name and a colour. Straight lines when no
  road is found. Up to 25 stations.
- **My routes**: save, open, edit and delete your routes (`/settings/earthBusRoutes/myroutes.json`).
- A built route runs like any line: timetable, passengers, HUD, score, **the way back** (the stations the other way round).
- **Continue this line as your own**: an incomplete OpenStreetMap line becomes the start of a route of your own.
- After a trip: **build the next leg from here** (the end of the route is the first station of the new one).
- Data service 0.2.0 (needs updating on the Add-ons page): `/v1/path`, `/v1/along`, `/v1/stations`, `/v1/search`.
- Requests the player waits for go before background prefetching.

## 0.2.1

- Lines with several variants to the same destination (a way via a village, a short run) are told apart by the relation's name instead of showing the same button twice.

## 0.2.0

- Menu: stops near you, lines and directions, route card (length, ride time, stops, how often it runs), start from this stop or from
  the first one, departure time with the game clock set to it, opposite direction, results with grade and your best.
- HUD app `EarthBusHud`: destination blind, next stop with delay and distance, line diagram, passengers on board, score.
- Generated timetable (city, regional, night; rush hours; weekends) and a passenger flow that follows the time of day.
- Bus stations (`amenity=bus_station`) take their numbered platforms under the station's name.
- The data comes through the Earth Bus Routes data service (`Robitnik/earth-bus-routes-data`): the game's sandbox cannot reach the internet.

## 0.1.0

- Skeleton: checks for BeamNG.Earth, five options.
