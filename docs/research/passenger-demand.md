# How many people wait at a stop (the passenger demand model, 0.13.1)

Seen in the game on 0.13.0: 30 people at a stop in the fields. The old model gave every stop 0.3 people a minute (times a weight that
was only relative to the other stops of the line), so a regional line with a bus every 1-2 hours collected 15-30 people anywhere.

## What the numbers rest on

- **Trips per person a day:** 2.7 on average in the EU (review of the national travel surveys); 2.9-3.2 in Denmark's survey; the EU
  "New mobility patterns" survey of 2021 gives about 2 for its definition. [EC, New Mobility Patterns in European Cities (2022)](https://transport.ec.europa.eu/system/files/2022-12/2022%20New%20Mobility%20Patterns%20in%20European%20Cities%20Task%20A%20Executive%20summary.pdf),
  [DTU Transport, TU Denmark 2022](https://www.man.dtu.dk/english/-/media/institutter/management/scientific-advice/modelcenter/tu_2023/tu_denmark_2022.pdf).
- **Share of trips by public transport:** about 10 % in the EU on average (same EC survey); the model uses 5 % for villages, 7 % for
  small towns, 10 % for towns of 10-50 thousand, 15 % up to 300 thousand and 22 % for big cities (a judgement: rural shares are lower,
  big cities higher; not one source).
- **How people come to the stop:** with a bus every 10-12 minutes or more often they come at random; with longer gaps most time their
  coming to the timetable (Seddon and Day 1974; Fan and Machemehl 2002; Fonzone et al.). So the people a bus takes are those who want
  to travel in the time since the bus before, not people piling up minute by minute; the model takes the day's demand of the stop
  times the share of the day in that time (weighted by the hour of the day), at most 3 hours.
  [Fonzone et al.](https://eprints.whiterose.ac.uk/id/eprint/85338/1/Fonzone%20et%20al%20-%20ISTTT61-WRR.pdf),
  [MIT 1.258J, random incidence](https://live.ocw.mit.edu/courses/1-258j-public-transportation-systems-spring-2017/45747c1e2881ec58cf72b1f4f99474dd_Tsn0xSQjo14.pdf).
- **Catchment:** 400 m round a stop (the usual walking distance), 0.5 km2. People per km2 of a built-up area: 1 200 in a village,
  2 500 in a town under 20 000, 4 000 under 200 000, 6 000 in a big city (a judgement for European towns).

No published figure of "people per departure at a rural stop" was found (operators count boardings per hour of service); the outcome
was checked against what a regional bus in Czechia or Ukraine looks like.

## The model (mod/lua/ge/extensions/earthBusRoutes/demand.lua)

For each stop of the line:

1. The town it is in: the nearest town (GeoNames, from the data service's speed-limit answer, with its population since service
   0.13.1) whose built-up radius reaches the stop. Outside every town: 40 people (a few houses, a farm, a junction). No towns known at
   all: the spacing of the stops (under 450 m town, over 2 km country).
2. Its people: the people within 400 m (density x 0.5 km2, more in the centre), at most the town's population shared among the line's
   stops in it; times a draw of up to 2 for the centre of a town over 5 000 people; divided among the lines of a town that size
   (1 + population / 8 000, at most 6); times 2.5 at a bus station.
3. A day's boardings in one direction: people x 2.7 x bus share x 0.5.
4. A bus takes: that x the share of the day in the time since the bus before (the hour profile: morning and afternoon peaks), x the
   density option (low 0.6, normal 1, high 1.6), x 1.2 in rain or snow; a Poisson draw, the same for the same trip.

With a bus every hour (normal density, weekday):

| Stop | 07:30 | 12:00 |
|---|---|---|
| in the fields | 0-0.3 | 0-0.1 |
| village of 300 | 1.2 | 0.9 |
| town of 20 000, its edge / centre | 8 / 10 | 3 / 8 |
| its bus station | 24 | 10 |
| centre of a city of 1 000 000, a bus every 5 min | 1.5-2 | |
