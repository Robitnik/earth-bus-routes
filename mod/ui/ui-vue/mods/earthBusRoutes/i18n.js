// The menu's two languages. The game language Ukrainian / Russian / Belarusian -> Ukrainian, anything else English; a switch on the
// page overrides it (kept in localStorage when the browser lets us).
import { ref } from "vue"

const DICT = {
  en: {
    "title": "Bus routes",
    "crumb.stops": "Stops near you",
    "back": "Back", "close": "Close", "refresh": "Refresh", "retry": "Try again",
    "near.title": "Stops near you", "near.sub": "Pick the stop you want to start from.",
    "near.empty": "No bus stops within 600 m.", "near.emptyHint": "Drive to a town or village with bus service and press Refresh.",
    "near.station": "Bus station", "near.platforms": "{n} platforms", "near.lines": "{n} lines",
    "near.loading": "Loading stops and lines from OpenStreetMap…", "near.loadingHint": "The first visit to a place can take up to a minute. After that it is instant.",
    "near.position": "Your position",
    "svc.downTitle": "The data service is not running",
    "svc.downText": "Bus routes come from OpenStreetMap through a small program on this computer, because the game itself cannot reach the internet.",
    "svc.downSteps": "Open Esc > BeamNG.Earth > Add-ons, add the repository Robitnik/earth-bus-routes-data, press Start and turn on 'Starts with BeamNG.Earth'.",
    "svc.ok": "Data service {v} is running", "svc.off": "Data service not reachable",
    "err.generic": "Something went wrong: {e}",
    "lines.title": "Lines at {name}", "lines.sub": "Pick a line and its direction.",
    "lines.variant": "to {to}", "lines.loading": "Loading the route…", "lines.loadingHint": "A new route is fetched from the public map server: up to a minute when it is busy. It is kept for next time.",
    "route.from": "From", "route.to": "To", "route.operator": "Operator", "route.network": "Network",
    "route.length": "Length", "route.time": "Ride", "route.stops": "Stops", "route.first": "First departure", "route.last": "Last departure",
    "route.min": "{n} min", "route.km": "{n} km", "route.mi": "{n} mi",
    "route.interval": "How often it runs", "route.every": "every {n} min", "route.none": "no service",
    "route.kind.city": "City line", "route.kind.regional": "Regional line", "route.kind.night": "Night line",
    "route.incomplete": "The map data of this line is incomplete: the road under some stretches is guessed.",
    "route.loop": "Circular line",
    "route.stopsTitle": "Stops of the line", "route.youHere": "You are here",
    "start.title": "Start the trip", "start.here": "From this stop", "start.first": "From the first stop",
    "start.time": "Departure time", "start.now": "Now",
    "start.next": "Next departures", "start.tomorrow": "tomorrow", "start.none": "No departures.",
    "start.reverse": "Opposite direction", "start.reverseHint": "Drive the line the other way: {to}",
    "start.go": "Start trip", "start.goHint": "The clock of the game is set to the departure. You are taken to the stop if you are not there.",
    "start.needBus": "Sit in a bus first. Other vehicles work but score half.",
    "start.teleporting": "Taking you to the stop…",
    "trip.title": "Trip in progress", "trip.text": "Line {ref} to {to}. The HUD shows the details.", "trip.cancel": "Cancel trip", "trip.back": "Back to the game",
    "res.title": "Trip finished", "res.points": "points", "res.record": "New best on this line", "res.best": "Your best on this line: {n}",
    "res.passengers": "Passengers", "res.stops": "Stops served", "res.time": "Time", "res.income": "Fares",
    "res.punctuality": "Punctuality", "res.service": "Service", "res.comfort": "Comfort", "res.safety": "Safety",
    "res.back": "Drive back", "res.another": "Another line from here", "res.close": "Close", "res.noSchedule": "Driven without a timetable: punctuality is not counted.",
    "res.totals": "All trips: {trips} trips, {pax} passengers",
    "stats.title": "Your totals", "stats.line": "{trips} trips, {pax} passengers",
    "credit": "Map data © OpenStreetMap contributors",
    "lang": "Language", "units.m": "m", "units.km": "km",
    "day.1": "Monday", "day.2": "Tuesday", "day.3": "Wednesday", "day.4": "Thursday", "day.5": "Friday", "day.6": "Saturday", "day.7": "Sunday",
    "note.Left early": "Left early", "note.Stop skipped": "Stop skipped", "note.Moving with doors open": "Moving with doors open", "note.Collision": "Collision",
  },
  uk: {
    "title": "Автобусні маршрути",
    "crumb.stops": "Зупинки поруч",
    "back": "Назад", "close": "Закрити", "refresh": "Оновити", "retry": "Спробувати знову",
    "near.title": "Зупинки поруч", "near.sub": "Оберіть зупинку, з якої почати.",
    "near.empty": "У радіусі 600 м немає автобусних зупинок.", "near.emptyHint": "Поїдьте в місто чи село з автобусним сполученням і натисніть «Оновити».",
    "near.station": "Автовокзал", "near.platforms": "платформ: {n}", "near.lines": "маршрутів: {n}",
    "near.loading": "Завантажую зупинки й маршрути з OpenStreetMap…", "near.loadingHint": "Перший візит у нове місце може тривати до хвилини. Далі миттєво.",
    "near.position": "Ваша позиція",
    "svc.downTitle": "Службу даних не запущено",
    "svc.downText": "Маршрути беруться з OpenStreetMap через маленьку програму на цьому комп'ютері, бо сама гра не має виходу в інтернет.",
    "svc.downSteps": "Esc > BeamNG.Earth > Add-ons: додайте репозиторій Robitnik/earth-bus-routes-data, натисніть Start і ввімкніть «Starts with BeamNG.Earth».",
    "svc.ok": "Служба даних {v} працює", "svc.off": "Служба даних недоступна",
    "err.generic": "Щось пішло не так: {e}",
    "lines.title": "Маршрути на зупинці {name}", "lines.sub": "Оберіть маршрут і напрямок.",
    "lines.variant": "до {to}", "lines.loading": "Завантажую маршрут…", "lines.loadingHint": "Новий маршрут беруть із публічного сервера карт: до хвилини, коли він завантажений. Далі він зберігається.",
    "route.from": "Звідки", "route.to": "Куди", "route.operator": "Перевізник", "route.network": "Мережа",
    "route.length": "Довжина", "route.time": "У дорозі", "route.stops": "Зупинок", "route.first": "Перший рейс", "route.last": "Останній рейс",
    "route.min": "{n} хв", "route.km": "{n} км", "route.mi": "{n} миль",
    "route.interval": "Як часто їздить", "route.every": "кожні {n} хв", "route.none": "не їздить",
    "route.kind.city": "Міський маршрут", "route.kind.regional": "Приміський маршрут", "route.kind.night": "Нічний маршрут",
    "route.incomplete": "Дані карти для цього маршруту неповні: дорога на деяких ділянках вгадана.",
    "route.loop": "Кільцевий маршрут",
    "route.stopsTitle": "Зупинки маршруту", "route.youHere": "Ви тут",
    "start.title": "Почати рейс", "start.here": "З цієї зупинки", "start.first": "З початкової зупинки",
    "start.time": "Час відправлення", "start.now": "Зараз",
    "start.next": "Найближчі відправлення", "start.tomorrow": "завтра", "start.none": "Відправлень немає.",
    "start.reverse": "Зворотний напрямок", "start.reverseHint": "Їхати маршрутом навпаки: {to}",
    "start.go": "Почати рейс", "start.goHint": "Годинник гри перейде на час відправлення. Якщо ви не на зупинці, вас перенесе.",
    "start.needBus": "Сядьте в автобус. Інший транспорт теж підійде, але бали вдвічі менші.",
    "start.teleporting": "Переношу вас на зупинку…",
    "trip.title": "Рейс триває", "trip.text": "Маршрут {ref} до {to}. Подробиці на HUD.", "trip.cancel": "Скасувати рейс", "trip.back": "Повернутися в гру",
    "res.title": "Рейс завершено", "res.points": "балів", "res.record": "Новий рекорд на цьому маршруті", "res.best": "Ваш рекорд на цьому маршруті: {n}",
    "res.passengers": "Пасажирів", "res.stops": "Зупинок обслужено", "res.time": "Час", "res.income": "Виручка",
    "res.punctuality": "Пунктуальність", "res.service": "Обслуговування", "res.comfort": "Комфорт", "res.safety": "Безпека",
    "res.back": "Їхати назад", "res.another": "Інший маршрут звідси", "res.close": "Закрити", "res.noSchedule": "Їхали без розкладу: пунктуальність не рахується.",
    "res.totals": "Усього: рейсів {trips}, пасажирів {pax}",
    "stats.title": "Ваша статистика", "stats.line": "рейсів {trips}, пасажирів {pax}",
    "credit": "Дані карти © OpenStreetMap contributors",
    "lang": "Мова", "units.m": "м", "units.km": "км",
    "day.1": "Понеділок", "day.2": "Вівторок", "day.3": "Середа", "day.4": "Четвер", "day.5": "П'ятниця", "day.6": "Субота", "day.7": "Неділя",
    "note.Left early": "Поїхали раніше часу", "note.Stop skipped": "Зупинку пропущено", "note.Moving with doors open": "Рух з відчиненими дверима", "note.Collision": "Зіткнення",
  },
}

function stored() {
  try { return localStorage.getItem("earthBusRoutes.lang") } catch (e) { return null }
}
const auto = (typeof navigator !== "undefined" && /^(uk|ru|be)/i.test(navigator.language || "")) ? "uk" : "en"
export const lang = ref(stored() === "uk" || stored() === "en" ? stored() : auto)

export function setLang(l) {
  lang.value = l
  try { localStorage.setItem("earthBusRoutes.lang", l) } catch (e) { /* private window: the choice lasts this session */ }
}

export function t(key, params) {
  let s = (DICT[lang.value] && DICT[lang.value][key]) || DICT.en[key] || key
  if (params) for (const k of Object.keys(params)) s = s.split("{" + k + "}").join(String(params[k]))
  return s
}

export function noteText(text) { return (DICT[lang.value] && DICT[lang.value]["note." + text]) || text }
