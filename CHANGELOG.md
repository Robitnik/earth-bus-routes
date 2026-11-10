# Changelog

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
