-- The texts the Lua side shows to the player itself (the toasts of the game's message area), in the languages of the add-on.
-- The menu and the HUD have their own packs (ui/.../lang/<code>.js); the same 13 codes. The language is the one the player
-- chose in the menu (the menu tells us: main.uiLang, kept in /settings/earthBusRoutes/lang.json), else the game's interface
-- language (settings uiLanguage), else English. A text a language lacks falls back to English. {name}-style placeholders.
-- Pure but for the file and the game setting, both behind pcall: the tests run it.
local M = {}

M.CODES = { 'en', 'uk', 'de', 'es', 'fr', 'ja', 'ko', 'pl', 'pt_BR', 'pt_PT', 'ru', 'zh_Hans', 'zh_Hant' }
M.PATH = '/settings/earthBusRoutes/lang.json'

local PACKS = {
  en = {
    needsEarth = 'Earth Bus Routes needs BeamNG.Earth: {reason}',
    gps = 'GPS: {name}',
    taking = 'Taking you to {name}…',
    hudAdded = 'Bus HUD added to your UI layout. Move or remove it in Esc > UI Apps.',
    driveTo = 'Drive to {name}: the trip begins there.',
    cancelled = 'Cancelled',
    couldNotStart = 'Could not start: {why}',
    tripCancelled = 'Trip cancelled',
    missedStop = 'Missed stop: {name}',
    cancelledVehicle = 'Trip cancelled: you changed vehicle',
    driveCancelledTeleport = 'Drive-to-start cancelled: you were teleported',
    cancelledTeleport = 'Trip cancelled: you were teleported',
    serviceRun = 'Service run from {depot} to {stop}: the trip begins there.',
    noNextTrip = 'The dispatcher could not give you the next trip: the shift ends.',
    shiftNext = 'Shift: trip {n} done. Next: {ref} to {to} at {time}',
    shiftWound = ' (the clock moved on to {time})',
    shiftDropped = 'The shift was dropped because of an error.',
    shiftEnded = 'Shift ended',
    shiftEndedTeleport = 'Shift ended: you were teleported',
  },
  uk = {
    needsEarth = 'Earth Bus Routes потребує BeamNG.Earth: {reason}',
    gps = 'GPS: {name}',
    taking = 'Переношу вас до {name}…',
    hudAdded = 'Автобусний HUD додано до вашого інтерфейсу. Перемістити чи прибрати: Esc > UI Apps.',
    driveTo = 'Їдьте до {name}: рейс починається там.',
    cancelled = 'Скасовано',
    couldNotStart = 'Не вдалося почати: {why}',
    tripCancelled = 'Рейс скасовано',
    missedStop = 'Пропущено зупинку: {name}',
    cancelledVehicle = 'Рейс скасовано: ви змінили транспорт',
    driveCancelledTeleport = 'Проїзд до початку скасовано: вас телепортовано',
    cancelledTeleport = 'Рейс скасовано: вас телепортовано',
    serviceRun = 'Службовий рейс з {depot} до {stop}: рейс починається там.',
    noNextTrip = 'Диспетчер не зміг дати наступний рейс: зміна закінчується.',
    shiftNext = 'Зміна: рейс {n} завершено. Далі: {ref} до {to} о {time}',
    shiftWound = ' (годинник переведено на {time})',
    shiftDropped = 'Зміну скинуто через помилку.',
    shiftEnded = 'Зміну завершено',
    shiftEndedTeleport = 'Зміну завершено: вас телепортовано',
  },
  de = {
    needsEarth = 'Earth Bus Routes braucht BeamNG.Earth: {reason}',
    gps = 'GPS: {name}',
    taking = 'Du wirst nach {name} gebracht…',
    hudAdded = 'Bus-HUD zu deinem UI-Layout hinzugefügt. Verschieben oder entfernen unter Esc > UI-Apps.',
    driveTo = 'Fahre zu {name}: Dort beginnt die Fahrt.',
    cancelled = 'Abgebrochen',
    couldNotStart = 'Start nicht möglich: {why}',
    tripCancelled = 'Fahrt abgebrochen',
    missedStop = 'Haltestelle verpasst: {name}',
    cancelledVehicle = 'Fahrt abgebrochen: Fahrzeug gewechselt',
    driveCancelledTeleport = 'Anfahrt zum Start abgebrochen: Du wurdest teleportiert',
    cancelledTeleport = 'Fahrt abgebrochen: Du wurdest teleportiert',
    serviceRun = 'Dienstfahrt von {depot} nach {stop}: Dort beginnt die Fahrt.',
    noNextTrip = 'Die Disposition konnte dir keine nächste Fahrt geben: Die Schicht endet.',
    shiftNext = 'Schicht: Fahrt {n} beendet. Als Nächstes: {ref} nach {to} um {time}',
    shiftWound = ' (die Uhr wurde auf {time} gestellt)',
    shiftDropped = 'Die Schicht wurde wegen eines Fehlers verworfen.',
    shiftEnded = 'Schicht beendet',
    shiftEndedTeleport = 'Schicht beendet: Du wurdest teleportiert',
  },
  es = {
    needsEarth = 'Earth Bus Routes necesita BeamNG.Earth: {reason}',
    gps = 'GPS: {name}',
    taking = 'Te llevamos a {name}…',
    hudAdded = 'HUD del autobús añadido a tu interfaz. Muévelo o quítalo en Esc > Apps de IU.',
    driveTo = 'Conduce hasta {name}: allí empieza el viaje.',
    cancelled = 'Cancelado',
    couldNotStart = 'No se pudo empezar: {why}',
    tripCancelled = 'Viaje cancelado',
    missedStop = 'Parada omitida: {name}',
    cancelledVehicle = 'Viaje cancelado: cambiaste de vehículo',
    driveCancelledTeleport = 'Trayecto al inicio cancelado: te teletransportaron',
    cancelledTeleport = 'Viaje cancelado: te teletransportaron',
    serviceRun = 'Viaje en vacío de {depot} a {stop}: allí empieza el viaje.',
    noNextTrip = 'El despachador no pudo darte el siguiente viaje: el turno termina.',
    shiftNext = 'Turno: viaje {n} terminado. Siguiente: {ref} a {to} a las {time}',
    shiftWound = ' (el reloj avanzó a las {time})',
    shiftDropped = 'El turno se descartó por un error.',
    shiftEnded = 'Turno terminado',
    shiftEndedTeleport = 'Turno terminado: te teletransportaron',
  },
  fr = {
    needsEarth = 'Earth Bus Routes a besoin de BeamNG.Earth : {reason}',
    gps = 'GPS : {name}',
    taking = 'Vous êtes emmené à {name}…',
    hudAdded = 'HUD du bus ajouté à votre interface. Déplacez-le ou retirez-le dans Échap > Applis UI.',
    driveTo = 'Allez à {name} : la course commence là.',
    cancelled = 'Annulé',
    couldNotStart = 'Démarrage impossible : {why}',
    tripCancelled = 'Course annulée',
    missedStop = 'Arrêt manqué : {name}',
    cancelledVehicle = 'Course annulée : vous avez changé de véhicule',
    driveCancelledTeleport = 'Trajet vers le départ annulé : vous avez été téléporté',
    cancelledTeleport = 'Course annulée : vous avez été téléporté',
    serviceRun = 'Trajet à vide de {depot} à {stop} : la course commence là.',
    noNextTrip = 'Le régulateur n’a pas pu vous donner la course suivante : le service se termine.',
    shiftNext = 'Service : course {n} terminée. Suivante : {ref} vers {to} à {time}',
    shiftWound = ' (l’horloge est passée à {time})',
    shiftDropped = 'Le service a été abandonné à cause d’une erreur.',
    shiftEnded = 'Service terminé',
    shiftEndedTeleport = 'Service terminé : vous avez été téléporté',
  },
  ja = {
    needsEarth = 'Earth Bus Routes には BeamNG.Earth が必要です: {reason}',
    gps = 'GPS: {name}',
    taking = '{name} へ移動します…',
    hudAdded = 'バスHUDをUIレイアウトに追加しました。Esc > UIアプリで移動・削除できます。',
    driveTo = '{name} まで走行してください。便はそこから始まります。',
    cancelled = 'キャンセルしました',
    couldNotStart = '開始できません: {why}',
    tripCancelled = '便をキャンセルしました',
    missedStop = 'バス停を通過しました: {name}',
    cancelledVehicle = '便をキャンセルしました: 車両を変更しました',
    driveCancelledTeleport = '出発地への回送をキャンセルしました: テレポートされました',
    cancelledTeleport = '便をキャンセルしました: テレポートされました',
    serviceRun = '{depot} から {stop} への回送: 便はそこから始まります。',
    noNextTrip = '運行管理から次の便を受け取れませんでした。乗務を終了します。',
    shiftNext = '乗務: {n} 便が完了。次: {ref} {to} 行き {time} 発',
    shiftWound = '（時計を {time} に進めました）',
    shiftDropped = 'エラーのため乗務を中止しました。',
    shiftEnded = '乗務を終了しました',
    shiftEndedTeleport = '乗務を終了しました: テレポートされました',
  },
  ko = {
    needsEarth = 'Earth Bus Routes에는 BeamNG.Earth가 필요합니다: {reason}',
    gps = 'GPS: {name}',
    taking = '{name}(으)로 이동합니다…',
    hudAdded = '버스 HUD를 UI 레이아웃에 추가했습니다. Esc > UI 앱에서 옮기거나 제거할 수 있습니다.',
    driveTo = '{name}(으)로 가세요. 운행은 그곳에서 시작됩니다.',
    cancelled = '취소됨',
    couldNotStart = '시작할 수 없음: {why}',
    tripCancelled = '운행 취소됨',
    missedStop = '정류장 통과: {name}',
    cancelledVehicle = '운행 취소됨: 차량을 바꿨습니다',
    driveCancelledTeleport = '출발지 이동 취소됨: 순간이동되었습니다',
    cancelledTeleport = '운행 취소됨: 순간이동되었습니다',
    serviceRun = '{depot}에서 {stop}까지 회송: 운행은 그곳에서 시작됩니다.',
    noNextTrip = '배차 담당이 다음 운행을 주지 못했습니다. 근무가 끝납니다.',
    shiftNext = '근무: {n}번째 운행 완료. 다음: {ref}번, {to}행, {time}',
    shiftWound = ' (시계가 {time}(으)로 넘어갔습니다)',
    shiftDropped = '오류로 근무가 중단되었습니다.',
    shiftEnded = '근무 종료',
    shiftEndedTeleport = '근무 종료: 순간이동되었습니다',
  },
  pl = {
    needsEarth = 'Earth Bus Routes wymaga BeamNG.Earth: {reason}',
    gps = 'GPS: {name}',
    taking = 'Przenoszę cię do: {name}…',
    hudAdded = 'HUD autobusu dodany do twojego interfejsu. Przesuń lub usuń go w Esc > Aplikacje UI.',
    driveTo = 'Jedź do: {name}. Tam zaczyna się kurs.',
    cancelled = 'Anulowano',
    couldNotStart = 'Nie można rozpocząć: {why}',
    tripCancelled = 'Kurs anulowany',
    missedStop = 'Pominięty przystanek: {name}',
    cancelledVehicle = 'Kurs anulowany: zmieniono pojazd',
    driveCancelledTeleport = 'Dojazd na start anulowany: zostałeś przeniesiony',
    cancelledTeleport = 'Kurs anulowany: zostałeś przeniesiony',
    serviceRun = 'Przejazd serwisowy z {depot} do {stop}: tam zaczyna się kurs.',
    noNextTrip = 'Dyspozytor nie mógł dać ci kolejnego kursu: zmiana się kończy.',
    shiftNext = 'Zmiana: kurs {n} zakończony. Następny: {ref} do {to} o {time}',
    shiftWound = ' (zegar przeskoczył na {time})',
    shiftDropped = 'Zmiana została porzucona z powodu błędu.',
    shiftEnded = 'Zmiana zakończona',
    shiftEndedTeleport = 'Zmiana zakończona: zostałeś przeniesiony',
  },
  pt_BR = {
    needsEarth = 'O Earth Bus Routes precisa do BeamNG.Earth: {reason}',
    gps = 'GPS: {name}',
    taking = 'Levando você para {name}…',
    hudAdded = 'HUD do ônibus adicionado ao seu layout de UI. Mova ou remova em Esc > Apps de UI.',
    driveTo = 'Dirija até {name}: a viagem começa lá.',
    cancelled = 'Cancelado',
    couldNotStart = 'Não foi possível iniciar: {why}',
    tripCancelled = 'Viagem cancelada',
    missedStop = 'Parada perdida: {name}',
    cancelledVehicle = 'Viagem cancelada: você trocou de veículo',
    driveCancelledTeleport = 'Deslocamento até o início cancelado: você foi teletransportado',
    cancelledTeleport = 'Viagem cancelada: você foi teletransportado',
    serviceRun = 'Viagem de serviço de {depot} até {stop}: a viagem começa lá.',
    noNextTrip = 'O despachante não conseguiu dar a próxima viagem: o turno termina.',
    shiftNext = 'Turno: viagem {n} concluída. Próxima: {ref} para {to} às {time}',
    shiftWound = ' (o relógio avançou para {time})',
    shiftDropped = 'O turno foi descartado por causa de um erro.',
    shiftEnded = 'Turno encerrado',
    shiftEndedTeleport = 'Turno encerrado: você foi teletransportado',
  },
  pt_PT = {
    needsEarth = 'O Earth Bus Routes precisa do BeamNG.Earth: {reason}',
    gps = 'GPS: {name}',
    taking = 'A levá-lo para {name}…',
    hudAdded = 'HUD do autocarro adicionado ao seu esquema de IU. Mova-o ou remova-o em Esc > Apps de IU.',
    driveTo = 'Conduza até {name}: a viagem começa lá.',
    cancelled = 'Cancelado',
    couldNotStart = 'Não foi possível iniciar: {why}',
    tripCancelled = 'Viagem cancelada',
    missedStop = 'Paragem falhada: {name}',
    cancelledVehicle = 'Viagem cancelada: mudou de veículo',
    driveCancelledTeleport = 'Deslocação até ao início cancelada: foi teletransportado',
    cancelledTeleport = 'Viagem cancelada: foi teletransportado',
    serviceRun = 'Viagem de serviço de {depot} até {stop}: a viagem começa lá.',
    noNextTrip = 'O despachante não conseguiu dar a próxima viagem: o turno termina.',
    shiftNext = 'Turno: viagem {n} concluída. Seguinte: {ref} para {to} às {time}',
    shiftWound = ' (o relógio avançou para {time})',
    shiftDropped = 'O turno foi descartado devido a um erro.',
    shiftEnded = 'Turno terminado',
    shiftEndedTeleport = 'Turno terminado: foi teletransportado',
  },
  ru = {
    needsEarth = 'Earth Bus Routes нужен BeamNG.Earth: {reason}',
    gps = 'GPS: {name}',
    taking = 'Переношу вас к: {name}…',
    hudAdded = 'Автобусный HUD добавлен в ваш интерфейс. Переместить или убрать: Esc > UI Apps.',
    driveTo = 'Езжайте к: {name}. Рейс начинается там.',
    cancelled = 'Отменено',
    couldNotStart = 'Не удалось начать: {why}',
    tripCancelled = 'Рейс отменён',
    missedStop = 'Пропущена остановка: {name}',
    cancelledVehicle = 'Рейс отменён: вы сменили транспорт',
    driveCancelledTeleport = 'Проезд к началу отменён: вас телепортировали',
    cancelledTeleport = 'Рейс отменён: вас телепортировали',
    serviceRun = 'Служебный рейс из {depot} до {stop}: рейс начинается там.',
    noNextTrip = 'Диспетчер не смог дать следующий рейс: смена заканчивается.',
    shiftNext = 'Смена: рейс {n} завершён. Далее: {ref} до {to} в {time}',
    shiftWound = ' (часы переведены на {time})',
    shiftDropped = 'Смена сброшена из-за ошибки.',
    shiftEnded = 'Смена завершена',
    shiftEndedTeleport = 'Смена завершена: вас телепортировали',
  },
  zh_Hans = {
    needsEarth = 'Earth Bus Routes 需要 BeamNG.Earth：{reason}',
    gps = 'GPS：{name}',
    taking = '正在送你前往 {name}…',
    hudAdded = '公交 HUD 已添加到你的界面布局。可在 Esc > UI 应用 中移动或移除。',
    driveTo = '请驶往 {name}：行程从那里开始。',
    cancelled = '已取消',
    couldNotStart = '无法开始：{why}',
    tripCancelled = '行程已取消',
    missedStop = '错过站点：{name}',
    cancelledVehicle = '行程已取消：你更换了车辆',
    driveCancelledTeleport = '前往起点已取消：你被传送了',
    cancelledTeleport = '行程已取消：你被传送了',
    serviceRun = '从 {depot} 到 {stop} 的空驶：行程从那里开始。',
    noNextTrip = '调度员无法给你下一个行程：班次结束。',
    shiftNext = '班次：第 {n} 个行程完成。下一个：{ref} 路开往 {to}，{time}',
    shiftWound = '（时钟已调到 {time}）',
    shiftDropped = '由于出错，班次已放弃。',
    shiftEnded = '班次结束',
    shiftEndedTeleport = '班次结束：你被传送了',
  },
  zh_Hant = {
    needsEarth = 'Earth Bus Routes 需要 BeamNG.Earth：{reason}',
    gps = 'GPS：{name}',
    taking = '正在送你前往 {name}…',
    hudAdded = '公車 HUD 已加入你的介面配置。可在 Esc > UI 應用程式 中移動或移除。',
    driveTo = '請駛往 {name}：行程從那裡開始。',
    cancelled = '已取消',
    couldNotStart = '無法開始：{why}',
    tripCancelled = '行程已取消',
    missedStop = '錯過站點：{name}',
    cancelledVehicle = '行程已取消：你更換了車輛',
    driveCancelledTeleport = '前往起點已取消：你被傳送了',
    cancelledTeleport = '行程已取消：你被傳送了',
    serviceRun = '從 {depot} 到 {stop} 的空車行駛：行程從那裡開始。',
    noNextTrip = '調度員無法給你下一個行程：班次結束。',
    shiftNext = '班次：第 {n} 個行程完成。下一個：{ref} 路開往 {to}，{time}',
    shiftWound = '（時鐘已調到 {time}）',
    shiftDropped = '由於發生錯誤，班次已放棄。',
    shiftEnded = '班次結束',
    shiftEndedTeleport = '班次結束：你被傳送了',
  },
}
M.PACKS = PACKS

local chosen = nil           -- the menu's choice: a code, or nil for the game's language ("auto")

local function isCode(c)
  for _, k in ipairs(M.CODES) do if k == c then return true end end
  return false
end
M.isCode = isCode

-- A language tag of the game ("de_DE", "zh-Hans", "es-419", "pt-BR") -> one of our codes, or nil (as langs.js fromTag)
function M.fromTag(tag)
  local s = tostring(tag or ''):gsub('_', '-'):lower()
  if s == '' then return nil end
  if s:sub(1, 2) == 'zh' then return (s:find('hant', 1, true) or s:find('-tw', 1, true) or s:find('-hk', 1, true) or s:find('-mo', 1, true)) and 'zh_Hant' or 'zh_Hans' end
  if s:sub(1, 2) == 'pt' then return s:find('^pt%-pt') and 'pt_PT' or 'pt_BR' end
  local two = s:sub(1, 2)
  if two == 'be' then return 'uk' end
  return isCode(two) and two or nil
end

-- The language in use: the menu's choice, else the game's interface language, else English
function M.lang()
  if chosen then return chosen end
  local st = rawget(_G, 'settings')
  if st and st.getValue then
    local ok, v = pcall(st.getValue, 'uiLanguage')
    if ok then
      local c = M.fromTag(v)
      if c then return c end
    end
  end
  return 'en'
end

-- code: one of the codes, or 'auto' / nil: the game's language. Kept in a file (the menu tells us on each opening).
function M.set(code, noSave)
  local new = isCode(code) and code or nil
  if new == chosen then return end
  chosen = new
  if noSave then return end
  local w = rawget(_G, 'jsonWriteFile')
  if w then pcall(w, M.PATH, { format = 1, lang = chosen or 'auto' }, true) end
end

function M.load()
  local r = rawget(_G, 'jsonReadFile')
  if not r then return end
  local ok, d = pcall(r, M.PATH)
  if ok and type(d) == 'table' then chosen = isCode(d.lang) and d.lang or nil end
end

-- The text of a key in the language in use ({name} placeholders from `vars`); an unknown key comes back as it is
function M.t(key, vars)
  local pack = PACKS[M.lang()]
  local s = (pack and pack[key]) or PACKS.en[key] or key
  if vars then
    s = s:gsub('{(%w+)}', function(k)
      local v = vars[k]
      if v == nil then return nil end
      return tostring(v)
    end)
  end
  return s
end

return M
