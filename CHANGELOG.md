# Changelog

## 0.7.0 (not released yet)

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
