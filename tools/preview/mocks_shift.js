// Preview states of the shift pages (plan 006 B): the route card with the shift block, the layover, the empty run, the summary.
export function shiftMenuStates(common, stations, sel, route, start) {
  const shiftOn = { enabled: true, depotOn: true, durations: [60, 120, 240], realChain: true, hasDepot: true, active: false, result: null }
  const colour = route.colour
  const layover = { ref: "305", from: "Hradec Králové", to: "Náchod", colour, planned: 31800, departs: 31800, plannedLabel: "08:50", departsLabel: "08:50",
    nowLabel: "08:38", remaining: 720, late: 0, number: 3, away: false, loading: false, clockWound: false, endsIn: 9000 }
  const active = { ...shiftOn, active: true, source: "gtfs", trips: 2, number: 3, depot: "depot", state: "layover", endsLabel: "11:10" }
  const trips = [
    { ref: "305", from: "Náchod", to: "Hradec Králové", colour, points: 874, grade: "A", passengers: 63, revenue: 94.5, punctuality: 0.93, served: 10, planned: 10, missed: 0, minutes: 84, late: 0 },
    { ref: "305", from: "Hradec Králové", to: "Náchod", colour, points: 712, grade: "B", passengers: 41, revenue: 61.5, punctuality: 0.81, served: 9, planned: 10, missed: 1, minutes: 88, late: 420 },
    { ref: "305", from: "Náchod", to: "Hradec Králové", colour, points: 801, grade: "A", passengers: 52, revenue: 78, punctuality: 0.9, served: 10, planned: 10, missed: 0, minutes: 85, late: 0 },
  ]
  return {
    shiftcard: { ...common, screen: "route", stations, ...sel, route: { ...route, timetable: "gtfs" }, start, shift: shiftOn },
    shiftcardgen: { ...common, screen: "route", stations, ...sel, route, start, shift: { ...shiftOn, realChain: false, hasDepot: false } },
    shiftlayover: { ...common, screen: "shiftLayover", stations, shift: { ...active, layover } },
    shiftlate: { ...common, screen: "shiftLayover", stations, shift: { ...active, layover: { ...layover, late: 540, remaining: -540, nowLabel: "08:59", away: true } } },
    shiftrun: { ...common, screen: "shiftLayover", stations, shift: { ...active, trips: 0, number: 1, state: "run",
      run: { ref: "305", colour, to: "Hradec Králové", stop: "Náchod, aut. nádraží", dist: 2400, dueLabel: "07:40", late: 0, depot: "ČSAD vozovna Náchod", depotKind: "depot" }, layover: undefined } },
    shiftresult: { ...common, screen: "shiftResult", stations, shift: { ...shiftOn, result: { trips, count: 3, passengers: 156, points: 796, grade: "B", punctuality: 0.88,
      served: 29, planned: 30, missed: 1, skipped: 1, lateTrips: 1, revenue: 234, minutes: 258, durationMin: 240, source: "gtfs", depot: "depot" } } },
  }
}

export function shiftHudStates(base) {
  const clone = o => JSON.parse(JSON.stringify(o))
  const layover = { ref: "305", colour: "#2f9e8f", from: "Hradec Králové", to: "Náchod", planned: 31800, departs: 31800, remaining: 720, late: 0, number: 3, away: false, loading: false, endsIn: 9000, units: "km/h" }
  return {
    shifttrip: { ...clone(base), shift: { number: 2, source: "gtfs", endsIn: 7200, endClock: 40000, depot: "depot", done: 1, lateStart: 420 } },
    shiftlayover: { layover },
    shiftlate: { layover: { ...layover, late: 540, remaining: -540 } },
    shiftaway: { layover: { ...layover, away: true } },
    shiftrun: { service: { ref: "305", colour: "#2f9e8f", to: "Hradec Králové", stop: "Náchod, aut. nádraží", dist: 2400, due: 27600, late: 0, depot: "ČSAD vozovna Náchod", units: "km/h" } },
    shiftdone: { finished: true, result: { grade: "B", points: 796 }, shift: { count: 3 } },
  }
}
