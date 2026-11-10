# Changelog

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
