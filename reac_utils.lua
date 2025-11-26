--==============================================================
-- REACTOR UTILITIES (extended)
-- Save as: reac_utils.lua
--==============================================================

--[[
README
-------
Verwaltet Draconic Reactor Operationen und Peripherie.
Enthält:
 - Laufende Schätzung der Energieerzeugung
 - Berechnung sicherer Burn-Pläne (Hysterese / zyklisches Heizen)
 - Sanftes Ramping von Flux-Gates
 - Watchdog-Checks während eines Burns
Erwartete modem labels:
  draconic_reactor_0  → Reactor stabilizer
  flow_gate_0         → Input flux gate (into reactor)
  flow_gate_1         → Output flux gate (to storage/core)
  monitor_1           → Status display monitor
]]

------------------------------------------------------------
-- IMPORT CONFIG
------------------------------------------------------------
local cfg = require("config")
local p = cfg.peripherals
local reac_utils = {}
local isBurning = false
------------------------------------------------------------
-- PERIPHERAL OBJECTS (declared global to module)
------------------------------------------------------------
reac_utils.reactor  = nil
reac_utils.gateIn   = nil
reac_utils.gateOut  = nil
reac_utils.mon      = nil
reac_utils.info     = {}

------------------------------------------------------------
-- RUNTIME ESTIMATION / BURN PLANNING STATE
------------------------------------------------------------
-- Ring buffer of recent RF/sec samples (positive = net increase of saturation)
reac_utils._rateSamples = {}
reac_utils._rateSampleWindow = cfg.reactor and cfg.reactor.rateSampleWindow or 5   -- seconds
reac_utils._lastSampleTS = nil
reac_utils._lastSampleSat = nil
reac_utils._estimatedGen = 0         -- RF per second (smoothed delta of saturation)
reac_utils._inBurn = false

------------------------------------------------------------
-- DEFAULT SAFETY PARAMS
------------------------------------------------------------
cfg.reactor = cfg.reactor or {}
cfg.reactor.chargeInflow = cfg.reactor.chargeInflow or 2000000000
cfg.reactor.maxOutflow = cfg.reactor.maxOutflow or 2000000000
cfg.reactor.defaultTemp = cfg.reactor.defaultTemp or 8000
cfg.reactor.defaultField = cfg.reactor.defaultField or 0.5
cfg.reactor.maxOvershoot = cfg.reactor.maxOvershoot or 200
cfg.reactor.shutDownField = cfg.reactor.shutDownField or 0.15
cfg.reactor.minFuel = cfg.reactor.minFuel or 0.02

-- Tuning parameters for planning
cfg.reactor.maxTickLag = cfg.reactor.maxTickLag or 0.5         -- worst-case delay in seconds
cfg.reactor.safetyMarginFrac = cfg.reactor.safetyMarginFrac or 0.05 -- extra fraction
cfg.reactor.minSafeSaturationFrac = cfg.reactor.minSafeSaturationFrac or 0.10
cfg.reactor.abortBurnFrac = cfg.reactor.abortBurnFrac or 0.08  -- immediate abort threshold
cfg.reactor.rateSampleWindow = cfg.reactor.rateSampleWindow or 5

------------------------------------------------------------
-- INTERNAL LOGGER
------------------------------------------------------------
local function logError(msg)
    local f = fs.open("reactor_error.log", "a")
    if f then
        f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. msg)
        f.close()
    end
    print("[!] " .. msg)
end

------------------------------------------------------------
-- SAFE WRAPPER FUNCTION
------------------------------------------------------------
local function safeWrap(name)
    if not name or name == "" then return nil end
    if peripheral.isPresent(name) then
        return peripheral.wrap(name)
    end
    return nil
end

------------------------------------------------------------
-- SETUP FUNCTION
------------------------------------------------------------
function reac_utils.setup()
    print("[INFO] Initializing reactor peripherals...")

    -- Attempt to find or wrap peripherals by label
    reac_utils.reactor = safeWrap(p.reactor) or safeWrap("draconic_reactor_0")
    reac_utils.gateIn  = safeWrap(p.fluxIn)  or safeWrap("flow_gate_0")
    reac_utils.gateOut = safeWrap(p.fluxOut) or safeWrap("flow_gate_1")
    reac_utils.mon     = safeWrap(p.monitors and p.monitors[1]) or safeWrap("monitor_1")

    -- Validation
    if not reac_utils.reactor then error("Reactor stabilizer not found!") end
    if not reac_utils.gateIn then  error("Input flux gate not found!") end
    if not reac_utils.gateOut then error("Output flux gate not found!") end

    -- Set gates into manual control mode
    if reac_utils.gateIn.setOverrideEnabled then
        pcall(function()
            reac_utils.gateIn.setOverrideEnabled(true)
            reac_utils.gateIn.setFlowOverride(0)
        end)
    end
    if reac_utils.gateOut.setOverrideEnabled then
        pcall(function()
            reac_utils.gateOut.setOverrideEnabled(true)
            reac_utils.gateOut.setFlowOverride(0)
        end)
    end

    -- Initialize sampling state
    reac_utils._rateSamples = {}
    reac_utils._lastSampleTS = nil
    reac_utils._lastSampleSat = nil
    reac_utils._estimatedGen = 0
    reac_utils._inBurn = false

    print("[SUCCESS] Reactor peripherals initialized successfully.")
end

------------------------------------------------------------
-- REACTOR STATUS
------------------------------------------------------------
function reac_utils.checkReactorStatus()
    if not reac_utils.reactor then
        logError("Reactor not initialized.")
        return
    end

    local ok, data = pcall(reac_utils.reactor.getReactorInfo)
    if not ok or not data then
        logError("Failed to read reactor info.")
        return
    end
    reac_utils.info = data
end

------------------------------------------------------------
-- EMERGENCY CHECK
------------------------------------------------------------
function reac_utils.isEmergency()
    local i = reac_utils.info
    if not i or not i.temperature then return false end

    if i.status == "cold" or i.status == "offline" or i.status == "warming_up" or i.status == "charging" then 
        return false 
    end

    local fieldPct = 0
    if i.maxFieldStrength and i.maxFieldStrength > 0 then
        fieldPct = (i.fieldStrength / i.maxFieldStrength)
    end
    local fuelPct  = 1.0
    if i.maxFuelConversion and i.maxFuelConversion > 0 then
        fuelPct = 1.0 - (i.fuelConversion / i.maxFuelConversion)
    end

    return (i.temperature > cfg.reactor.defaultTemp + cfg.reactor.maxOvershoot)
        or (fieldPct < cfg.reactor.shutDownField)
        or (fuelPct < cfg.reactor.minFuel)
end

------------------------------------------------------------
-- FAILSAFE SHUTDOWN
------------------------------------------------------------
function reac_utils.failSafeShutdown()
    if reac_utils.reactor and reac_utils.reactor.stopReactor then
        pcall(reac_utils.reactor.stopReactor)
    end
    if reac_utils.gateIn then pcall(function() reac_utils.gateIn.setFlowOverride(0) end) end
    if reac_utils.gateOut then pcall(function() reac_utils.gateOut.setFlowOverride(0) end) end
    logError("Emergency reactor shutdown executed.")
end

------------------------------------------------------------
-- FUEL AND CHAOS CHECK
------------------------------------------------------------
function reac_utils.checkFuelAndChaos()
    if not reac_utils.reactor then return false end

    local ok, info = pcall(reac_utils.reactor.getReactorInfo)
    if not ok or not info then return false end

    if info.status == "cold" then
        return true
    end

    local fuelLeft = 1.0
    if info.maxFuelConversion and info.maxFuelConversion > 0 then
        fuelLeft = 1.0 - (info.fuelConversion / info.maxFuelConversion)
    end
    if fuelLeft <= 0 then
        logError("Reactor has no fuel! Insert fuel before startup.")
        reac_utils.failSafeShutdown()
        return false
    end

    if info.maxEnergySaturation and info.maxEnergySaturation > 0 then
        if info.energySaturation and info.energySaturation >= info.maxEnergySaturation then
            logError("Chaos buffer full -> Shutdown.")
            reac_utils.failSafeShutdown()
            return false
        elseif info.energySaturation and info.energySaturation >= info.maxEnergySaturation * 0.95 then
            if info.status == "running" or info.status == "online" then
                logError("Warning: Chaos storage nearing full capacity.")
            end
        end
    end

    return true
end

------------------------------------------------------------
-- ENERGY RATE SAMPLING
------------------------------------------------------------
function reac_utils.sampleEnergyRate()
    if not reac_utils.reactor then return end
    local ok, info = pcall(reac_utils.reactor.getReactorInfo)
    if not ok or not info or not info.energySaturation or not info.maxEnergySaturation then return end

    local now = os.clock()
    local emax = info.maxEnergySaturation
    local sat = info.energySaturation

    if reac_utils._lastSampleTS == nil then
        reac_utils._lastSampleTS = now
        reac_utils._lastSampleSat = sat
        return
    end

    local dt = now - reac_utils._lastSampleTS
    if dt <= 0 then return end

    local dSat = sat - reac_utils._lastSampleSat
    -- delta in RF per second
    local deltaRFperSec = (dSat * emax) / dt

    table.insert(reac_utils._rateSamples, deltaRFperSec)
    if #reac_utils._rateSamples > reac_utils._rateSampleWindow then
        table.remove(reac_utils._rateSamples, 1)
    end

    -- simple moving average
    local sum = 0
    for _, v in ipairs(reac_utils._rateSamples) do sum = sum + v end
    reac_utils._estimatedGen = sum / math.max(1, #reac_utils._rateSamples)

    -- store
    reac_utils._lastSampleSat = sat
    reac_utils._lastSampleTS = now
end

------------------------------------------------------------
-- BURN PLAN COMPUTATION
-- returned: plan = {allowedOut, burnTime, restTime, predictedNet, requiredReserveFrac}
------------------------------------------------------------
function reac_utils.computeBurnPlan(info, desiredOutflow)
    local emax = info.maxEnergySaturation or 1
    if emax <= 0 then return nil end

    local satFrac = info.energySaturation / emax
    local gen = reac_utils._estimatedGen or 0         -- RF per sec (net when idle)
    -- desiredOutflow in RF per sec, clamp to limits
    local out = math.min(desiredOutflow or (cfg.reactor.maxOutflow * 0.95), cfg.reactor.maxOutflow)

    -- net negative Leistung während Burn in RF/s (gen is positive if buffer increases)
    local net = gen - out

    local safeMinFrac = cfg.reactor.minSafeSaturationFrac
    local lag = cfg.reactor.maxTickLag
    local marginFrac = cfg.reactor.safetyMarginFrac

    -- Reserve für worst-case tick-lag
    local requiredReserveFrac = 0
    if net < 0 then
        local worstDropRF = math.abs(net) * lag
        requiredReserveFrac = worstDropRF / emax
    end
    requiredReserveFrac = requiredReserveFrac + marginFrac

    -- verfügbare Fraktion, die für Burn genutzt werden kann ohne safeMin zu unterschreiten
    local availFrac = satFrac - requiredReserveFrac - safeMinFrac
    if availFrac <= 0 then
        return nil -- kein sicherer Burn möglich
    end

    local availRF = availFrac * emax
    local netAbs = math.max(1, math.abs(net)) -- RF/s
    local burnTime = availRF / netAbs
    local restTime = burnTime * 1.2 -- konservative Erholungsdauer

    return {
        allowedOut = math.floor(out),
        burnTime = burnTime,
        restTime = restTime,
        predictedNet = net,
        requiredReserveFrac = requiredReserveFrac
    }
end

------------------------------------------------------------
-- SANFTES RAMPING
-- gate: peripheral, target: value, steps: int, stepDelay: sec
------------------------------------------------------------
function reac_utils.rampFlowTo(gate, target, steps, stepDelay)
    if not gate then return end
    steps = steps or 6
    stepDelay = stepDelay or 0.05
    local current = 0
    pcall(function()
        if gate.getFlowOverride then
            current = gate.getFlowOverride() or 0
        end
    end)
    local delta = (target - current) / steps
    for i = 1, steps do
        local v = current + delta * i
        if v < 0 then v = 0 end
        if v > cfg.reactor.chargeInflow then v = cfg.reactor.chargeInflow end
        pcall(function() gate.setFlowOverride(math.floor(v)) end)
        sleep(stepDelay)
    end
end

------------------------------------------------------------
-- WATCHDOG: sehr kurzfristige Überprüfung während Burn
------------------------------------------------------------
local function burnWatchdogCheck()
    if not reac_utils.info or not reac_utils.info.maxEnergySaturation then return false end
    local satFrac = (reac_utils.info.energySaturation or 0) / reac_utils.info.maxEnergySaturation
    if satFrac < cfg.reactor.abortBurnFrac then
        return false
    end
    local fieldPct = 0
    if reac_utils.info.maxFieldStrength and reac_utils.info.maxFieldStrength > 0 then
        fieldPct = (reac_utils.info.fieldStrength or 0) / reac_utils.info.maxFieldStrength
    end
    if fieldPct < cfg.reactor.shutDownField then
        return false
    end
    return true
end

------------------------------------------------------------
-- TEMPERATURE / FIELD MANAGEMENT (Hauptlogik)
-- Ersetzt frühere einfache Regelung mit Burn-Plan-Logik
------------------------------------------------------------
function reac_utils.adjustReactorTempAndField()
    local i = reac_utils.info
    if not i or not i.temperature then return end

    -- Immer zuerst Energie-Rate updaten
    reac_utils.sampleEnergyRate()

    local fieldPct = 0
    if i.maxFieldStrength and i.maxFieldStrength > 0 then
        fieldPct = (i.fieldStrength / i.maxFieldStrength)
    end
    local targetField = cfg.reactor.defaultField
    local saturation = 0
    if i.maxEnergySaturation and i.maxEnergySaturation > 0 then
        saturation = i.energySaturation / i.maxEnergySaturation
    end

    -- Wenn wir bereits in einem Burn sind, handle minimalen Watchdog und Exit
    if reac_utils._inBurn then
        -- verabschiede Burn, falls kritische Schwelle erreicht
        if saturation < cfg.reactor.abortBurnFrac or fieldPct < cfg.reactor.shutDownField then
            reac_utils._inBurn = false
            pcall(function() reac_utils.gateOut.setFlowOverride(0) end)
            pcall(function() reac_utils.gateIn.setFlowOverride(cfg.reactor.chargeInflow) end)
            return
        end
        -- ansonsten nichts weiter, Burn-Loop wird von Aufrufer gesteuert
        return
    end

    -- Entscheide ob ein Burn gestartet werden soll
    -- Konditionen: Feld stabil, Sättigung ausreichend, Temperatur deutlich unter Ziel
    local wantBurn = false
    if (fieldPct > 0.40) and (saturation > 0.30) and (i.temperature < cfg.reactor.defaultTemp) then
        wantBurn = true
    end

    -- Führe Burn-Plan aus, falls möglich
    if wantBurn then
        local desiredOut = cfg.reactor.maxOutflow * 0.95
        local plan = reac_utils.computeBurnPlan(i, desiredOut)
        if plan then
            -- markiere Burn
            reac_utils._inBurn = true

            -- Pre-charge: Input auf maximum, kurz warten
            if reac_utils.gateIn then
                reac_utils.rampFlowTo(reac_utils.gateIn, cfg.reactor.chargeInflow, 6, 0.03)
            end
            sleep(0.15) -- kurze Vorlaufzeit, damit Input ankommt

            -- Sanftes Ramping des Outflows
            if reac_utils.gateOut then
                reac_utils.rampFlowTo(reac_utils.gateOut, plan.allowedOut, 6, 0.03)
            end

            -- Burn-Zeit laufen lassen, minimaler Watchdog
            local t0 = os.clock()
            while (os.clock() - t0) < plan.burnTime do
                -- update status
                local ok, _ = pcall(function() reac_utils.info = reac_utils.reactor.getReactorInfo() end)
                if not ok then break end

                -- Watchdog prüft kritische Grenzwerte sehr eng
                if not burnWatchdogCheck() then
                    -- sofort aussteigen
                    pcall(function() reac_utils.gateOut.setFlowOverride(0) end)
                    break
                end

                -- kleine Pause, kurze Reaktionszeit
                sleep(0.05)
            end

            -- Burn beendet: Outflow sofort runter, Input wieder auf Laden
            pcall(function() reac_utils.gateOut.setFlowOverride(0) end)
            pcall(function() reac_utils.gateIn.setFlowOverride(cfg.reactor.chargeInflow) end)

            -- Wartezeit für Erholung
            sleep(math.max(1, math.floor(plan.restTime)))
            reac_utils._inBurn = false
            return
        else
            -- Kein sicherer Burn möglich, also nichts tun und aufladen
            pcall(function() reac_utils.gateOut.setFlowOverride(0) end)
            pcall(function() reac_utils.gateIn.setFlowOverride(cfg.reactor.chargeInflow) end)
            return
        end
    end

    -- Fallback: normale Temperaturanpassung, wenn kein Burn
    local outflow = 0
    if i.temperature > cfg.reactor.defaultTemp then
        local diff = i.temperature - cfg.reactor.defaultTemp
        outflow = diff * 20000
    else
        outflow = 0
    end

    -- Wenn Sättigung sehr hoch -> sichere Ableitung
    if saturation > 0.90 then
        local excess = (saturation - 0.90) * 10
        local safeDump = excess * cfg.reactor.maxOutflow
        if fieldPct > 0.30 then outflow = math.max(outflow, safeDump) end
    end

    local inflow = 0
    local baseDrain = i.fieldDrainRate or 100000

    if outflow > 1000000 then
        inflow = cfg.reactor.chargeInflow 
    else
        local err = targetField - fieldPct
        inflow = baseDrain + (err * 60000000)
    end

    if fieldPct < 0.30 then inflow = cfg.reactor.chargeInflow end

    if inflow < 0 then inflow = 0 end
    if inflow > cfg.reactor.chargeInflow then inflow = cfg.reactor.chargeInflow end

    if reac_utils.gateIn then pcall(function() reac_utils.gateIn.setFlowOverride(math.floor(inflow)) end) end
    if reac_utils.gateOut then pcall(function() reac_utils.gateOut.setFlowOverride(math.floor(outflow)) end) end
end

------------------------------------------------------------
-- HANDLE STOPPING
------------------------------------------------------------
function reac_utils.handleReactorStopping()
    if reac_utils.gateIn then pcall(function() reac_utils.gateIn.setFlowOverride(0) end) end
    if reac_utils.gateOut then pcall(function() reac_utils.gateOut.setFlowOverride(0) end) end
end

return reac_utils
