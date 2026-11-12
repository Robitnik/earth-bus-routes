-- texts.lua: the toasts in the language of the add-on (the menu's choice, else the game's, else English)
local H = dofile('tests/harness.lua')
local T = {}

local function fresh()
  H.reset()
  _G.settings, _G.jsonWriteFile, _G.jsonReadFile = nil, nil, nil
  package.loaded['earthBusRoutes/texts'] = nil
  return require('earthBusRoutes/texts')
end

local function placeholders(s)
  local t = {}
  for k in s:gmatch('{(%w+)}') do t[#t + 1] = k end
  table.sort(t)
  return table.concat(t, ',')
end

function T.every_language_has_every_text_with_the_same_placeholders()
  local texts = fresh()
  local base = texts.PACKS.en
  local n = 0
  for _ in pairs(base) do n = n + 1 end
  assert(n >= 18, 'the toasts: ' .. n)
  for _, code in ipairs(texts.CODES) do
    local pack = assert(texts.PACKS[code], 'a pack for ' .. code)
    for k, v in pairs(base) do
      assert(type(pack[k]) == 'string' and pack[k] ~= '', code .. ' lacks ' .. k)
      assert(placeholders(pack[k]) == placeholders(v), code .. '.' .. k .. ' placeholders ' .. placeholders(pack[k]) .. ' instead of ' .. placeholders(v))
      assert(not pack[k]:find('[\r\n]'), code .. '.' .. k .. ': a line break')
    end
    for k in pairs(pack) do assert(base[k], code .. ' has an extra text ' .. k) end
  end
end

function T.a_game_language_tag_becomes_one_of_the_codes()
  local texts = fresh()
  local cases = { ['de_DE'] = 'de', ['en-US'] = 'en', ['es_419'] = 'es', ['es_ES'] = 'es', ['fr_FR'] = 'fr', ['ja_JP'] = 'ja', ['ko_KR'] = 'ko',
    ['pl_PL'] = 'pl', ['pt_BR'] = 'pt_BR', ['pt_PT'] = 'pt_PT', ['pt-PT'] = 'pt_PT', ['ru_RU'] = 'ru', ['zh_Hans'] = 'zh_Hans', ['zh-Hant'] = 'zh_Hant',
    ['zh-TW'] = 'zh_Hant', ['zh-CN'] = 'zh_Hans', ['uk_UA'] = 'uk', ['be_BY'] = 'uk' }
  for tag, code in pairs(cases) do assert(texts.fromTag(tag) == code, tag .. ' -> ' .. tostring(texts.fromTag(tag))) end
  assert(texts.fromTag('xx_XX') == nil and texts.fromTag('') == nil and texts.fromTag(nil) == nil)
end

function T.the_language_is_the_menus_choice_else_the_games_else_english()
  local texts = fresh()
  assert(texts.lang() == 'en', 'no setting: English')
  _G.settings = { getValue = function(k) assert(k == 'uiLanguage') return 'de_DE' end }
  assert(texts.lang() == 'de' and texts.t('shiftEnded') == 'Schicht beendet')
  texts.set('ja', true)
  assert(texts.lang() == 'ja' and texts.t('shiftEnded') == '乗務を終了しました', 'the menu chose Japanese')
  texts.set('auto', true)
  assert(texts.lang() == 'de', 'auto: the game again')
  _G.settings = { getValue = function() return 'xx_XX' end }
  assert(texts.lang() == 'en', 'an unknown game language: English')
  _G.settings = { getValue = function() error('no settings') end }
  assert(texts.lang() == 'en', 'a failing setting: English')
  texts.set('klingon', true)
  assert(texts.lang() == 'en', 'an unknown code is not a choice')
end

function T.placeholders_are_filled_and_unknown_things_pass_through()
  local texts = fresh()
  texts.set('en', true)
  assert(texts.t('taking', { name = 'Police n.Met.' }) == 'Taking you to Police n.Met.…')
  assert(texts.t('shiftNext', { n = 3, ref = '363', to = 'Hradec', time = '14:05' }) == 'Shift: trip 3 done. Next: 363 to Hradec at 14:05')
  texts.set('de', true)
  assert(texts.t('missedStop', { name = 'Šimkova' }) == 'Haltestelle verpasst: Šimkova')
  assert(texts.t('taking', {}):find('{name}', 1, true), 'a missing value stays as written, no error')
  assert(texts.t('no such key') == 'no such key')
  assert(texts.t('cancelled') == 'Abgebrochen')
  -- a language that lacked a text would show the English one
  texts.PACKS.de.cancelled = nil
  assert(texts.t('cancelled') == 'Cancelled')
end

function T.the_choice_is_kept_in_a_file_and_read_at_load()
  local texts = fresh()
  local written = {}
  _G.jsonWriteFile = function(path, t) written[#written + 1] = { path = path, t = t } return true end
  texts.set('pl')
  assert(#written == 1 and written[1].path == '/settings/earthBusRoutes/lang.json' and written[1].t.lang == 'pl')
  texts.set('pl')
  assert(#written == 1, 'the same choice again: not written again')
  texts.set('auto')
  assert(#written == 2 and written[2].t.lang == 'auto')
  -- a new session reads it
  local t2 = fresh()
  _G.jsonReadFile = function(path) assert(path == '/settings/earthBusRoutes/lang.json') return { format = 1, lang = 'fr' } end
  t2.load()
  assert(t2.lang() == 'fr')
  _G.jsonReadFile = function() return { lang = 'auto' } end
  t2.load()
  assert(t2.lang() == 'en')
  _G.jsonReadFile = function() error('no file') end
  t2.load()                                -- no error
  assert(t2.lang() == 'en')
end

return T
