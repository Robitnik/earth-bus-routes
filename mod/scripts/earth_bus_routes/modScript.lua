-- Runs when the mod is mounted (core/modmanager.lua: FS:findFiles('/scripts/', 'modScript.lua') + dofile).
-- 'manual' keeps the extension loaded across level changes; BeamNG.Earth unloads it itself on update / turn off / remove.
setExtensionUnloadMode('earthBusRoutes_main', 'manual')
