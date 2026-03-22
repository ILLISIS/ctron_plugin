if not script.active_mods["Constructron-Continued"] then
    log("[ctron_plugin] Disabled as Constructron-Continued mod not enabled")
    return
end

log("[ctron_plugin] enabled")

local clusterio_api = require("modules/clusterio/api")

-- clusterio plugin specific
local ctron_plugin = {
    events = {},
    on_nth_tick = {},
}

local util_func = require("modules/ctron_plugin/script/utility_functions")
local entity_proc = require("modules/ctron_plugin/script/entity_processor")
local job_proc = require("modules/ctron_plugin/script/job_processor")
local gui_handlers = require("modules/ctron_plugin/script/ui")
local clusterio_handler = require("modules/ctron_plugin/clusterio_handler")
local pathfinder = require("modules/ctron_plugin/script/pathfinder")
local cargo_job = require("modules/ctron_plugin/script/job/cargo")

-- inject clusterio_handler into entity_proc after all modules are loaded (breaks circular dependency)
entity_proc.set_clusterio_handler(clusterio_handler)

ctron_plugin_on_job_claimed = function(job_json)
    clusterio_handler.on_job_claimed(job_json)
end

-- Delivers a remote path result to this game instance (called via RCON).
ctron_plugin_on_path_response = function(json)
    pathfinder.on_remote_path_response(helpers.json_to_table(json))
end

ctron_plugin_apply_synced_settings = function(json)
    local data = helpers.json_to_table(json)
    if not data then return end

    -- Update mode flag (used by UI to block in-game settings when controller is authority)
    local controller_mode = (data.mode == "controller")
    storage.ctron_settings_controller_mode = controller_mode
    -- Close any open settings windows when switching to controller mode
    if controller_mode then
        for _, player in pairs(game.players) do
            if player.gui.screen.ctron_settings_window then
                player.gui.screen.ctron_settings_window.destroy()
                player.print("Settings window closed: settings are now managed by the controller.")
            end
        end
    end

    -- Apply global settings
    if data.global_settings then
        if data.global_settings.job_start_delay ~= nil then
            storage.job_start_delay = data.global_settings.job_start_delay
        end
        if data.global_settings.debug_toggle ~= nil then
            storage.debug_toggle = data.global_settings.debug_toggle
        end
    end

    -- Apply per-surface settings (keyed by surface name)
    if data.surface_settings then
        for surface_name, settings in pairs(data.surface_settings) do
            local surface = game.surfaces[surface_name]
            if surface then
                local si = surface.index
                if settings.horde_mode ~= nil then storage.horde_mode[si] = settings.horde_mode end
                if settings.construction_job_toggle ~= nil then storage.construction_job_toggle[si] = settings.construction_job_toggle end
                if settings.rebuild_job_toggle ~= nil then storage.rebuild_job_toggle[si] = settings.rebuild_job_toggle end
                if settings.deconstruction_job_toggle ~= nil then storage.deconstruction_job_toggle[si] = settings.deconstruction_job_toggle end
                if settings.upgrade_job_toggle ~= nil then storage.upgrade_job_toggle[si] = settings.upgrade_job_toggle end
                if settings.repair_job_toggle ~= nil then storage.repair_job_toggle[si] = settings.repair_job_toggle end
                if settings.destroy_job_toggle ~= nil then storage.destroy_job_toggle[si] = settings.destroy_job_toggle end
                if settings.zone_restriction_job_toggle ~= nil then storage.zone_restriction_job_toggle[si] = settings.zone_restriction_job_toggle end
                if settings.desired_robot_count ~= nil then storage.desired_robot_count[si] = settings.desired_robot_count end
                if settings.desired_robot_name ~= nil then storage.desired_robot_name[si] = settings.desired_robot_name end
                if settings.repair_tool_name ~= nil then storage.repair_tool_name[si] = settings.repair_tool_name end
                if settings.ammo_name ~= nil then storage.ammo_name[si] = settings.ammo_name end
                if settings.ammo_count ~= nil then storage.ammo_count[si] = settings.ammo_count end
                if settings.atomic_ammo_name ~= nil then storage.atomic_ammo_name[si] = settings.atomic_ammo_name end
                if settings.atomic_ammo_count ~= nil then storage.atomic_ammo_count[si] = settings.atomic_ammo_count end
                if settings.destroy_min_cluster_size ~= nil then storage.destroy_min_cluster_size[si] = settings.destroy_min_cluster_size end
                if settings.minion_count ~= nil then storage.minion_count[si] = settings.minion_count end
            end
        end
    end
end

-- Called via RCON on instance startup to report all current surface names to TypeScript.
-- TypeScript registers them with the controller so the web UI can show per-surface settings.
ctron_plugin_get_surface_names = function()
    local names = {}
    for _, surface in pairs(game.surfaces) do
        table.insert(names, surface.name)
    end
    rcon.print(table.concat(names, ","))
end

-- Receives a forwarded path request on the pathworld (called via RCON).
-- We only queue the params here; the actual surface.request_path call happens
-- inside on_nth_tick so it runs in a proper Factorio event context.
ctron_plugin_pathworld_on_path_request = function(json)
    local data = helpers.json_to_table(json)
    if not data then return end
    storage.is_pathworld = true
    storage.pathworld_request_queue = storage.pathworld_request_queue or {}
    table.insert(storage.pathworld_request_queue, data)
    log("[ctron_plugin] pathworld: queued path request params for requester " .. tostring(data.requesterId))
end

--===========================================================================--
-- Main workers
--===========================================================================--

ctron_plugin.on_nth_tick[90] = function()
    if storage.is_pathworld then
        pathfinder.process_pathworld_queue()
    else
        job_proc.process_job_queue()
        gui_handlers.update_ui_windows()
        pathfinder.expire_remote_path_requests()
    end
end

-- cleanup
ctron_plugin.on_nth_tick[54000] = function()
    for _, surface in pairs(game.surfaces) do
        local surface_index = surface.index
        if (storage.constructrons_count[surface_index] <= 0) or (storage.stations_count[surface_index] <= 0) then
            storage.construction_queue[surface_index] = {}
            storage.deconstruction_queue[surface_index] = {}
            storage.upgrade_queue[surface_index] = {}
            storage.repair_queue[surface_index] = {}
        end
    end
end

--===========================================================================--
-- init
--===========================================================================--

local ensure_storages = function()
    storage.ctron_plugin = storage.ctron_plugin or {
        station_count = 0,
    }
    storage.mod_mode = storage.mod_mode or {
        ["publisher"] = true,
        ["subscriber"] = false
    }
    --
    storage.constructron_names = storage.constructron_names or { ["constructron"] = true, ["constructron-rocket-powered"] = true}
    storage.station_names = storage.station_names or { ["service_station"] = true }
    --
    storage.registered_entities = storage.registered_entities or {}
    storage.constructron_statuses = storage.constructron_statuses or {}
    --
    storage.managed_surfaces = storage.managed_surfaces or {}
    --
    storage.stack_cache = {} -- rebuild
    storage.entity_inventory_cache = {}
    --
    storage.pathfinder_requests = storage.pathfinder_requests or {}
    storage.custom_pathfinder_index = storage.custom_pathfinder_index or 0
    storage.custom_pathfinder_requests = storage.custom_pathfinder_requests or {}
    storage.pathfinder_remote_requests = storage.pathfinder_remote_requests or {} -- tracks outgoing path requests sent to pathworld; expired in expire_remote_path_requests()
    storage.is_pathworld = storage.is_pathworld or false -- set true on first RCON call to ctron_plugin_pathworld_on_path_request; gates process_pathworld_queue()
    storage.pathworld_pending = storage.pathworld_pending or {} -- maps request_id -> requester info while pathworld awaits on_script_path_request_finished
    storage.pathworld_request_queue = storage.pathworld_request_queue or {} -- RCON-queued path requests; drained each tick by process_pathworld_queue()
    storage.mainland_chunks = storage.mainland_chunks or {}
    storage.max_pathfinder_iterations = storage.max_pathfinder_iterations or 200
    --
    storage.job_index = storage.job_index or 0
    storage.jobs = storage.jobs or {}
    --
    storage.station_requests = storage.station_requests or {}
    --
    storage.global_threat_modifier = storage.global_threat_modifier or 1.6
    --
    storage.construction_index = storage.construction_index or 0
    storage.deconstruction_index = storage.deconstruction_index or 0
    storage.upgrade_index = storage.upgrade_index or 0
    storage.repair_index = storage.repair_index or 0
    storage.destroy_index = storage.destroy_index or 0
    storage.cargo_index = storage.cargo_index or 0
    --
    storage.construction_queue = storage.construction_queue or {}
    storage.deconstruction_queue = storage.deconstruction_queue or {}
    storage.upgrade_queue = storage.upgrade_queue or {}
    storage.repair_queue = storage.repair_queue or {}
    storage.destroy_queue = storage.destroy_queue or {}
    storage.cargo_queue = storage.cargo_queue or {}
    --
    storage.constructrons = storage.constructrons or {} -- all constructron entities.
    storage.service_stations = storage.service_stations or {} -- all service stations entities.
    storage.ctron_combinators = storage.ctron_combinators or {} -- all combinator entities.
    storage.constructron_requests = storage.constructron_requests or {} -- caches logistic requests as they are nil after slot is cleared. This was needed for combinators.
    --
    storage.constructrons_count = storage.constructrons_count or {}
    storage.available_ctron_count = storage.available_ctron_count or {}
    storage.stations_count = storage.stations_count or {}
    -- settings sync mode flag (set by ctron_plugin_apply_synced_settings via RCON)
    if storage.ctron_settings_controller_mode == nil then
        storage.ctron_settings_controller_mode = false
    end
    -- settings
    storage.horde_mode = storage.horde_mode or {}
    storage.construction_job_toggle = storage.construction_job_toggle or {}
    storage.rebuild_job_toggle = storage.rebuild_job_toggle or {}
    storage.deconstruction_job_toggle = storage.deconstruction_job_toggle or {}
    storage.upgrade_job_toggle = storage.upgrade_job_toggle or {}
    storage.repair_job_toggle = storage.repair_job_toggle or {}
    storage.destroy_job_toggle = storage.destroy_job_toggle or {}
    storage.zone_restriction_job_toggle = storage.zone_restriction_job_toggle or {}
    storage.destroy_min_cluster_size = storage.destroy_min_cluster_size or {}
    storage.minion_count = storage.minion_count or {}
    -- job_types
    storage.job_types = {
        "deconstruction",
        "construction",
        "upgrade",
        "repair",
        "destroy",
        "cargo"
    }
    -- ui
    storage.user_interface = storage.user_interface or {}
    for _, player in pairs(game.players) do
        storage.user_interface[player.index] = storage.user_interface[player.index] or {
            surface = player.surface,
            main_ui = {
                elements = {}
            },
            settings_ui = {
                elements = {}
            },
            job_ui = {
                elements = {}
            },
            cargo_ui = {
                elements = {}
            },
            logistics_ui = {
                elements = {}
            },
        }
    end
    -- ammunition setup
    storage.ammo_name = storage.ammo_name or {}
    local init_ammo_name
    if prototypes.item["rocket"] then
        init_ammo_name = { name = "rocket", quality = "normal" }
    else
        -- get ammo prototypes
        local ammo_prototypes = prototypes.get_item_filtered{{filter = "type", type = "ammo"}} -- TODO: check if can be filtered further in future API versions.
        -- iterate through ammo prototypes to find rocket ammo
        for _, ammo in pairs(ammo_prototypes) do
            if ammo.ammo_category.name == "rocket" then -- check if this is rocket type ammo
                init_ammo_name = { name = ammo.name, quality = "normal" } -- set the variable to be used in the surface loop
                break
            end
        end
    end
    storage.ammo_count = storage.ammo_count or {}
    -- atomic ammo setup
    storage.atomic_ammo_name = storage.atomic_ammo_name or {}
    local init_atomic_name
    if prototypes.item["atomic-bomb"] then
        init_atomic_name = { name = "atomic-bomb", quality = "normal" }
    else
        -- get atomic ammo prototypes
        local atomic_ammo_prototypes = prototypes.get_item_filtered{{filter = "type", type = "ammo"}} -- TODO: check if can be filtered further in future API versions.
        -- iterate through atomic ammo prototypes to find atomic ammo
        for _, ammo in pairs(atomic_ammo_prototypes) do
            if ammo.ammo_category.name == "rocket" then -- check if this is atomic type ammo
                init_atomic_name = { name = ammo.name, quality = "normal" } -- set the variable to be used in the surface loop
                break
            end
        end
    end
    storage.atomic_ammo_count = storage.atomic_ammo_count or {}
    -- robot setup
    storage.desired_robot_count = storage.desired_robot_count or {}
    storage.desired_robot_name = storage.desired_robot_name or {}
    local init_robot_name
    if prototypes.item["construction-robot"] then
        init_robot_name = { name = "construction-robot", quality = "normal" }
    else
        local valid_robots = prototypes.get_entity_filtered{{filter = "type", type = "construction-robot"}}
        local valid_robot_name = util_func.firstoflct(valid_robots)
        init_robot_name = { name = valid_robot_name, quality = "normal" }
    end
    -- repair tool
    storage.repair_tool_name = storage.repair_tool_name or {}
    local init_repair_tool_name
    if prototypes.item["repair-pack"] then
        init_repair_tool_name = { name = "repair-pack", quality = "normal" }
    else
        local valid_repair_tools = prototypes.get_item_filtered{{filter = "name", name = "repair-pack"}} -- TODO: check if can be filtered further in future API versions.
        local valid_repair_tool_name = util_func.firstoflct(valid_repair_tools)
        init_repair_tool_name = { name = valid_repair_tool_name, quality = "normal" }
    end
    -- non surface specific settings
    storage.job_start_delay = storage.job_start_delay or 300 -- five seconds
    if storage.debug_toggle == nil then
        storage.debug_toggle = false
    end
    -- set per surface setting values
    for _, surface in pairs(game.surfaces) do
        -- per surface settings
        local surface_index = surface.index
        if storage.horde_mode[surface_index] == nil then
            storage.horde_mode[surface_index] = false
        end
        if storage.construction_job_toggle[surface_index] == nil then
            storage.construction_job_toggle[surface_index] = true
        end
        if storage.rebuild_job_toggle[surface_index] == nil then
            storage.rebuild_job_toggle[surface_index] = true
        end
        if storage.deconstruction_job_toggle[surface_index] == nil then
            storage.deconstruction_job_toggle[surface_index] = true
        end
        if storage.upgrade_job_toggle[surface_index] == nil then
            storage.upgrade_job_toggle[surface_index] = true
        end
        if storage.repair_job_toggle[surface_index] == nil then
            storage.repair_job_toggle[surface_index] = true
        end
        if storage.destroy_job_toggle[surface_index] == nil then
            storage.destroy_job_toggle[surface_index] = false
        end
        if storage.zone_restriction_job_toggle[surface_index] == nil then
            storage.zone_restriction_job_toggle[surface_index] = false
        end
        storage.ammo_name[surface_index] = storage.ammo_name[surface_index] or init_ammo_name
        storage.ammo_count[surface_index] = storage.ammo_count[surface_index] or 0
        storage.atomic_ammo_name[surface_index] = storage.atomic_ammo_name[surface_index] or init_atomic_name
        storage.atomic_ammo_count[surface_index] = storage.atomic_ammo_count[surface_index] or 0
        storage.minion_count[surface_index] = storage.minion_count[surface_index] or 1
        storage.destroy_min_cluster_size[surface_index] = storage.destroy_min_cluster_size[surface_index] or 8
        storage.desired_robot_count[surface_index] = storage.desired_robot_count[surface_index] or 50
        storage.desired_robot_name[surface_index] = storage.desired_robot_name[surface_index] or init_robot_name
        storage.repair_tool_name[surface_index] = storage.repair_tool_name[surface_index] or init_repair_tool_name
        -- per surface variables
        storage.constructrons_count[surface_index] = storage.constructrons_count[surface_index] or 0
        storage.available_ctron_count[surface_index] = storage.available_ctron_count[surface_index] or storage.constructrons_count[surface_index]
        storage.stations_count[surface_index] = storage.stations_count[surface_index] or 0
        storage.construction_queue[surface_index] = storage.construction_queue[surface_index] or {}
        storage.deconstruction_queue[surface_index] = storage.deconstruction_queue[surface_index] or {}
        storage.upgrade_queue[surface_index] = storage.upgrade_queue[surface_index] or {}
        storage.repair_queue[surface_index] = storage.repair_queue[surface_index] or {}
        storage.destroy_queue[surface_index] = storage.destroy_queue[surface_index] or {}
        storage.cargo_queue[surface_index] = storage.cargo_queue[surface_index] or {}
    end
    -- build allowed items cache (this is used to filter out entities that do not have recipes)
    storage.allowed_items = {}
    for item_name, _ in pairs(prototypes.item) do
        local recipes = prototypes.get_recipe_filtered({
                {filter = "has-product-item", elem_filters = {{filter = "name", name = item_name}}},
            })
        for _ , recipe in pairs(recipes) do
            if not game.forces["player"].recipes[recipe.name].hidden then -- if the recipe is hidden disallow it
                storage.allowed_items[item_name] = true
            end
        end
        if storage.allowed_items[item_name] == nil then -- some items do not have recipes so set the item to disallowed
            storage.allowed_items[item_name] = false
        end
    end
    local autoplace_entities = prototypes.get_entity_filtered{{filter="autoplace"}}
    for entity_name, entity in pairs(autoplace_entities) do
        if entity.mineable_properties and entity.mineable_properties.products then
            storage.allowed_items[entity_name] = true
        end
    end
    -- allowed_items overrides as item/entities do not match what is mined (this is particularly for cargo jobs)
    storage.allowed_items["raw-fish"] = true
    storage.allowed_items["wood"] = true
    storage.allowed_items["depleted-uranium-fuel-cell"] = true -- https://discord.com/channels/943829001284235295/1407149730370420797
    -- build required_items cache (used in add_entities_to_chunks)
    storage.items_to_place_cache = {}
    for name, v in pairs(prototypes.entity) do
        if v.items_to_place_this ~= nil and v.items_to_place_this[1] and v.items_to_place_this[1].name then -- bots will only ever use the first item from this list
            storage.items_to_place_cache[name] = {item = v.items_to_place_this[1].name, count = v.items_to_place_this[1].count}
        end
    end
    for name, v in pairs(prototypes.tile) do
        if v.items_to_place_this ~= nil and v.items_to_place_this[1] and v.items_to_place_this[1].name then -- bots will only ever use the first item from this list
            storage.items_to_place_cache[name] = {item = v.items_to_place_this[1].name, count = v.items_to_place_this[1].count}
        end
    end
    -- build trash_items_cache
    storage.trash_items_cache = {}
    for entity_name, prototype in pairs(prototypes.entity) do
        if prototype.mineable_properties and prototype.mineable_properties.products then
            for _, product in pairs(prototype.mineable_properties.products) do
                if product.type == "item" then
                    storage.trash_items_cache[entity_name] = storage.trash_items_cache[entity_name] or {}
                    storage.trash_items_cache[entity_name][product.name] = product.amount_max or product.amount
                end
            end
        else
            storage.trash_items_cache[entity_name] = {}
        end
    end
    -- build water tile cache
    storage.water_tile_cache = {}
    local water_tile_prototypes = prototypes.get_tile_filtered{{filter="collision-mask",mask={layers ={["water_tile"]=true}},mask_mode="contains-any"}}
    for tile_name, _ in pairs(water_tile_prototypes) do
        storage.water_tile_cache[tile_name] = true
    end
end

local init = function()
    ensure_storages()
    game.map_settings.path_finder.use_path_cache = false
    -- use_path_cache Klonan's explanation:
    -- So, when path cache is enabled, negative path cache is also enabled.
    -- The problem is, when a single unit inside a nest can't get to the silo,
    -- He tells all other biters nearby that they also can't get to the silo.
    -- Which causes whole groups of them just to chillout and idle...
    -- This applies to all paths as the pathfinder is generic
end


ctron_plugin.events[clusterio_api.events.on_server_startup] = function()
    if game.player and game.player.force.technologies["spidertron"]
        and game.player.force.technologies["spidertron"].researched
    then
        game.print("Welcome to [item=constructron]! Please see the games tips and tricks for more information about Constructrons use! [tip=spidertron-automation]")
    end
    init()
end

--===========================================================================--
-- other
--===========================================================================--

local ev = defines.events

-- script.on_event(ev.on_player_used_spidertron_remote, function(event)
-- end)

local research_handlers = {
    ["stronger-explosives-3"] = function()
        storage.global_threat_modifier = math.max(0.4, storage.global_threat_modifier - 0.1)
    end,
    ["stronger-explosives-4"] = function()
        storage.global_threat_modifier = math.max(0.4, storage.global_threat_modifier - 0.1)
    end,
    ["stronger-explosives-5"] = function()
        storage.global_threat_modifier = math.max(0.4, storage.global_threat_modifier - 0.1)
    end,
    ["stronger-explosives-6"] = function()
        storage.global_threat_modifier = math.max(0.4, storage.global_threat_modifier - 0.1)
    end,
    ["weapon-shooting-speed-3"] = function()
        storage.global_threat_modifier = math.max(0.4, storage.global_threat_modifier - 0.2)
    end,
    ["weapon-shooting-speed-4"] = function()
        storage.global_threat_modifier = math.max(0.4, storage.global_threat_modifier - 0.2)
    end,
    ["weapon-shooting-speed-5"] = function()
        storage.global_threat_modifier = math.max(0.4, storage.global_threat_modifier - 0.2)
    end,
    ["weapon-shooting-speed-6"] = function()
        storage.global_threat_modifier = math.max(0.4, storage.global_threat_modifier - 0.2)
    end,
    ["spidertron"] = function()
        game.print("Welcome to [item=constructron]! Please see the games tips and tricks for more information about Constructrons use!")
    end,
}

ctron_plugin.events[ev.on_research_finished] = function(event)
    local research_name = event.research.name
    local handler = research_handlers[research_name]
    if handler then
        handler()
    end
end

ctron_plugin.events[ev.on_lua_shortcut] = function (event)
    local name = event.prototype_name
    if name == "ctron-get-selection-tool" then
        local player = game.get_player(event.player_index)
        if not player then return end
        local cursor_stack = player.cursor_stack
        if not cursor_stack then return end
        if not cursor_stack.valid_for_read or cursor_stack.name ~= "ctron-selection-tool" then
            if not player.clear_cursor() then return end
            cursor_stack.set_stack({ name = "ctron-selection-tool", count = 1 })
        elseif cursor_stack.name == "ctron-selection-tool" and not player.gui.screen.ctron_main_frame then
            player.clear_cursor()
            gui_handlers.open_main_window(player)
        end
    elseif name == "ctron-open-ui" then
        local player = game.get_player(event.player_index)
        if not player then return end
        gui_handlers.open_main_window(player)
    end
end

---@param event EventData.on_custom_input
ctron_plugin.events["ctron-get-selection-tool"] = function (event)
    local name = event.input_name
    if name ~= "ctron-get-selection-tool" then return end
    local player = game.get_player(event.player_index)
    if not player then return end
    local cursor_stack = player.cursor_stack
    if not cursor_stack then return end
    if not cursor_stack.valid_for_read or cursor_stack.name ~= "ctron-selection-tool" then
        if not player.clear_cursor() then return end
        cursor_stack.set_stack({ name = "ctron-selection-tool", count = 1 })
    elseif cursor_stack.name == "ctron-selection-tool" and not player.gui.screen.ctron_main_frame then
        player.clear_cursor()
        gui_handlers.open_main_window(player)
    end
end

ctron_plugin.events[ev.on_surface_created] = function(event)
    local surface_index = event.surface_index
    storage.construction_queue[surface_index] = {}
    storage.deconstruction_queue[surface_index] = {}
    storage.upgrade_queue[surface_index] = {}
    storage.repair_queue[surface_index] = {}
    storage.destroy_queue[surface_index] = {}
    storage.cargo_queue[surface_index] = {}
    storage.constructrons_count[surface_index] = 0
    storage.available_ctron_count[surface_index] = 0
    storage.stations_count[surface_index] = 0

    -- per surface settings
    storage.horde_mode[surface_index] = false
    storage.construction_job_toggle[surface_index] = true
    storage.rebuild_job_toggle[surface_index] = true
    storage.deconstruction_job_toggle[surface_index] = true
    storage.upgrade_job_toggle[surface_index] = true
    storage.repair_job_toggle[surface_index] = true
    storage.destroy_job_toggle[surface_index] = false
    storage.zone_restriction_job_toggle[surface_index] = false
    storage.ammo_name[surface_index] = storage.ammo_name[1]
    storage.ammo_count[surface_index] = 0
    storage.atomic_ammo_name[surface_index] = storage.atomic_ammo_name[1]
    storage.atomic_ammo_count[surface_index] = 0
    storage.destroy_min_cluster_size[surface_index] = 8
    storage.minion_count[surface_index] = 1
    storage.desired_robot_count[surface_index] = 50
    storage.desired_robot_name[surface_index] = storage.desired_robot_name[1]
    storage.repair_tool_name[surface_index] = storage.repair_tool_name[1]

    -- Notify controller so it creates a default entry for this surface.
    local surface = game.surfaces[surface_index]
    if surface then
        clusterio_api.send_json("ctron_plugin:surface_created", { name = surface.name })
    end
end

ctron_plugin.events[ev.on_surface_deleted] = function(event)
    local surface_index = event.surface_index
    storage.construction_queue[surface_index] = nil
    storage.deconstruction_queue[surface_index] = nil
    storage.upgrade_queue[surface_index] = nil
    storage.repair_queue[surface_index] = nil
    storage.destroy_queue[surface_index] = nil
    storage.cargo_queue[surface_index] = nil
    storage.constructrons_count[surface_index] = nil
    storage.available_ctron_count[surface_index] = nil
    storage.stations_count[surface_index] = nil

    -- per surface settings
    storage.horde_mode[surface_index] = nil
    storage.construction_job_toggle[surface_index] = nil
    storage.rebuild_job_toggle[surface_index] = nil
    storage.deconstruction_job_toggle[surface_index] = nil
    storage.upgrade_job_toggle[surface_index] = nil
    storage.repair_job_toggle[surface_index] = nil
    storage.destroy_job_toggle[surface_index] = nil
    storage.zone_restriction_job_toggle[surface_index] = nil
    storage.ammo_name[surface_index] = nil
    storage.ammo_count[surface_index] = nil
    storage.atomic_ammo_name[surface_index] = nil
    storage.atomic_ammo_count[surface_index] = nil
    storage.destroy_min_cluster_size[surface_index] = nil
    storage.minion_count[surface_index] = nil
    storage.desired_robot_count[surface_index] = nil
    storage.desired_robot_name[surface_index] = nil
    storage.repair_tool_name[surface_index] = nil
    storage.ctron_combinators[surface_index] = nil
end

ctron_plugin.on_nth_tick[10] = function()
    for _, pathfinder in pairs(storage.custom_pathfinder_requests) do
        pathfinder:findpath()
    end
end

-- Clusterio Events

ctron_plugin.on_nth_tick[300] = function(event) clusterio_handler.on_nth_tick_300(event) end

-- Entity events

ctron_plugin.events[ev.on_built_entity] = entity_proc.on_built_entity

ctron_plugin.events[ev.script_raised_built] = function(event)
    entity_proc.on_built_entity(event)
end

ctron_plugin.events[ev.on_robot_built_entity] = entity_proc.on_built_entity

ctron_plugin.events[ev.on_post_entity_died] = entity_proc.on_post_entity_died

ctron_plugin.events[ev.on_marked_for_deconstruction] = entity_proc.on_marked_for_deconstruction

ctron_plugin.events[ev.on_marked_for_upgrade] = entity_proc.on_marked_for_upgrade

ctron_plugin.events[ev.on_entity_damaged] = entity_proc.on_entity_damaged

ctron_plugin.events[ev.on_entity_cloned] = entity_proc.on_entity_cloned

ctron_plugin.events[ev.script_raised_teleported] = entity_proc.script_raised_teleported

ctron_plugin.events[ev.on_object_destroyed] = entity_proc.on_object_destroyed

ctron_plugin.events[ev.script_raised_destroy] = entity_proc.script_raised_destroy

ctron_plugin.events[ev.on_sector_scanned] = entity_proc.on_sector_scanned

ctron_plugin.events[ev.on_player_selected_area] = entity_proc.on_player_selected_area

ctron_plugin.events[ev.on_player_reverse_selected_area] = entity_proc.on_player_reverse_selected_area

ctron_plugin.events[ev.on_player_alt_selected_area] = entity_proc.on_player_alt_selected_area

ctron_plugin.events[ev.on_player_alt_reverse_selected_area] = entity_proc.on_player_alt_reverse_selected_area

-- Pathfinder events

ctron_plugin.events[defines.events.on_script_path_request_finished] = pathfinder.on_path_request_finished

-- Cargo

ctron_plugin.on_nth_tick[600] = cargo_job.on_nth_tick_600

-- GUI

for k, _ in pairs(gui_handlers.gui_event_types) do
    ctron_plugin.events[k] = gui_handlers.gui_event
end

ctron_plugin.events[defines.events.on_player_created] = gui_handlers.on_player_created

ctron_plugin.events[defines.events.on_gui_opened] = gui_handlers.on_gui_opened

ctron_plugin.events[defines.events.on_gui_closed] = gui_handlers.on_gui_closed

--===========================================================================--
--- game interfaces
--===========================================================================--

--------------------------------------------------------------------------------
--- before using the below functions please notify the maintainer of this mod
---------------------------------------------------------------------------------
--- used by:
--- Planet Maraxis
--- Spidertron Patrols
--- Construction Planner
--- Clusterio plugin

-- remote interface to inform this mod of a new constructron type (this mod will handle the entity for you)
---@param name string
local function remote_add_ctron_name(name)
    storage.constructron_names[name] = true
end

-- remote interface to inform this mod of a new station type (this mod will handle the entity for you)
---@param name string
local function remote_add_station_name(name)
    storage.station_names[name] = true
end

-- remote interface to get constructron names
local function remote_get_ctron_names()
    return storage.constructron_names
end

-- remote interface to get station names
local function remote_get_station_names()
    return storage.station_names
end

-- notify this mod of alignments new entity to be built (if this not naturally handled by the on_event scripting)
---@param entity LuaEntity
local function remote_entity_built(entity)
    ---@type EventData.script_raised_built
    local event = {
        tick = game.tick,
        name = defines.events.script_raised_built,
        entity = entity,
    }
    entity_proc.on_built_entity(event)
end

-- notify this mod of new entities to be built (if this not naturally handled by the on_event scripting)
---@param entities LuaEntity[]
local function remote_entities_built(entities)
    for _, entity in pairs(entities) do
        remote_entity_built(entity)
    end
end

--- remote interface to get a Constructrons current job
--- @param unit_number uint
local function get_job(unit_number)
    log("[ctron_interface] get_job called with unit_number: " .. tostring(unit_number))
    for _, job in pairs(storage.jobs) do
        if job.worker and job.worker.unit_number == unit_number then
            return job
        end
    end
end

--   21.114 Script @__Constructron-Continued__/control.lua:534: [ctron_interface] get_job called with unit_number: 127
--   21.114 Script @__level__/modules/ctron_plugin/control.lua:62: {
--   chunks = {
--     [312337500] = {
--       from_tool = false,
--       key = 312337500,
--       last_update_tick = 81555,
--       maximum = {
--         x = -510.5,
--         y = 17.5
--       },
--       midpoint = {
--         x = -511.5,
--         y = 16.5
--       },
--       minimum = {
--         x = -512.5,
--         y = 15.5
--       },
--       required_items = {
--         ["assembling-machine-3"] = {
--           normal = 1
--         }
--       },
--       surface_index = 1,
--       trash_items = {}
--     }
--   },
--   empty_slot_count = 80,
--   job_index = 2,
--   job_status = {
--     "ctron_status.job_type_construction"
--   },
--   job_type = "construction",
--   landfill_job = false,
--   last_distance = 11.763669118638644,
--   last_position = {},
--   last_robot_orientations = {},
--   mobility_tick = 82890,
--   required_items = {
--     ["assembling-machine-3"] = {
--       normal = 1
--     },
--     ["construction-robot"] = {
--       normal = 50
--     }
--   },
--   roboports_enabled = true,
--   robot_inactivity_counter = 0,
--   state = "in_progress",
--   station = "[LuaEntity: service_station at [gps=-492.0,-3.0]]",
--   surface_index = 1,
--   task_positions = {},
--   trash_items = {},
--   worker = "[LuaEntity: constructron at [gps=-513.2,17.5]]",
--   worker_ammo_slots = "[LuaInventory: entity #3=spider_ammo]",
--   worker_inventory = "[LuaInventory: entity #2=spider_trunk]",
--   worker_logistic_cell = "[LuaLogisticCell]",
--   worker_logistic_network = "[LuaLogisticNetwork]",
--   worker_trash_inventory = "[LuaInventory: entity #4=spider_trash]"
-- }


--- remote interface to create a defined job
---@param job table
---@param worker LuaEntity
local function set_job(job, worker)
    log("[ctron_interface] set_job called with job: " .. serpent.block(job))
    if not job or not (worker and worker.valid) then
        log("[ctron_interface] set_job called with invalid entity")
        return
    end

    -- Allocate a new job index and spawn a fresh instance using the job class.
    storage.job_index = storage.job_index + 1
    local new_job_index = storage.job_index

    local job_type = job.job_type
    local job_class = job_proc.job_types and job_proc.job_types[job_type]
    if not job_class or not job_class.new then
        log("[ctron_interface] set_job unknown job_type: " .. tostring(job_type))
        return
    end

    -- Create the new job instance (this sets correct metatables and runs constructor defaults)
    local new_job = job_class.new(new_job_index, worker.surface.index, job_type, worker)

    -- Copy incoming scalar/table state onto the fresh instance.
    -- Do not overwrite runtime-only references that we rebind below.
    for k, v in pairs(job) do
        if k ~= "job_index"
            and k ~= "worker"
            and k ~= "worker_unit_number"
            and k ~= "worker_logistic_cell"
            and k ~= "worker_logistic_network"
            and k ~= "worker_inventory"
            and k ~= "worker_ammo_slots"
            and k ~= "worker_trash_inventory"
        then
            new_job[k] = v
        end
    end

    -- Re-bind runtime-only references (always from the actual worker)
    new_job.job_index = new_job_index
    new_job.worker = worker
    new_job.worker_unit_number = worker.unit_number
    new_job.worker_logistic_cell = worker.logistic_cell
    new_job.worker_logistic_network = worker.logistic_cell.logistic_network
    new_job.worker_inventory = worker.get_inventory(defines.inventory.spider_trunk)
    new_job.worker_ammo_slots = worker.get_inventory(defines.inventory.spider_ammo)
    new_job.worker_trash_inventory = worker.get_inventory(defines.inventory.spider_trash)

    -- set station entity if possible
    local station = game.surfaces[job.surface_index].find_entities_filtered{position = job.station_position, name = "service_station", radius = 1}[1]
    if station and station.valid then
        new_job.station = station
    end

    -- Record
    storage.jobs[new_job_index] = new_job
end

local function remove_job(job_index)
    log("[ctron_interface] remove_job called with job_index: " .. tostring(job_index))
    storage.jobs[job_index] = nil
end

--- remote interface to set a Constructrons status
---@param unit_number uint
---@param status string
local function set_ctron_status(unit_number, status)
    log("[ctron_interface] set_ctron_status called with unit_number: " .. tostring(unit_number) .. " and status: " .. tostring(status))
    storage.constructron_statuses[unit_number] = status
end

--- remote interface to set a Constructrons color according to job_type
---@param entity LuaEntity
---@param job_type JobTypes
local function set_ctron_color(entity, job_type)
    log("[ctron_interface] set_ctron_color called with entity unit_number: " .. tostring(entity.unit_number) .. " and job_type: " .. tostring(job_type))
    util_func.paint_constructron(entity, job_type)
end

-- remote.add_interface("ctron", {
--     ["scan-entity"] = remote_entity_built,
--     ["scan-entities"] = remote_entities_built,
--     ["add-ctron-names"] = remote_add_ctron_name,
--     ["get-ctron-names"] = remote_get_ctron_names,
--     ["add-station-names"] = remote_add_station_name,
--     ["get-station-names"] = remote_get_station_names,
--     -- clusterio plugin interfaces
--     ["get-job"] = get_job,
--     ["set-job"] = set_job,
--     ["set-ctron-status"] = set_ctron_status,
--     ["set-ctron-color"] = set_ctron_color,
--     ["remove-job"] = remove_job,
-- })

-- Universal edges serialization hooks: embed/restore job data when constructrons cross edges
local ue_hooks = require("modules/universal_edges/universal_serializer/hooks")

-- Embed job data in serialized constructron entity
ue_hooks.register("LuaEntity", "post_serialize", function(entity_data, context)
    local entity = context.entity
    if not (entity and entity.valid) then return end
    if not storage.constructron_names[entity.name] then return end

    for _, job in pairs(storage.jobs) do
        if job.worker and (job.worker.unit_number == entity.unit_number) then
            local station_data = {
                    position = table.deepcopy(job.station.position),
                    valid = true,
                    logistic_network = {}
                }
            entity_data.ctron_job = {
                job_type = job.job_type,
                state = job.state,
                sub_state = job.sub_state,
                surface_index = job.surface_index,
                chunks = job.chunks,
                required_items = job.required_items,
                trash_items = job.trash_items,
                station = station_data,
                task_positions = job.task_positions,
                landfill_job = job.landfill_job,
                roboports_enabled = job.roboports_enabled,
                job_status = job.job_status,
                deffered_tick = job.deffered_tick,
            }
            -- Safe to remove here — entity.destroy() is called immediately after serialization
            storage.jobs[job.job_index] = nil
            break
        end
    end
    return entity_data
end)

-- Restore job when constructron arrives on the other side
ue_hooks.register("LuaEntity", "post_deserialize", function(entity_data, context)
    local entity = context.entity
    if not (entity and entity.valid) then return end
    if not entity_data.ctron_job then return end

    -- Use the destination entity's surface index, not the source's
    local job = entity_data.ctron_job
    job.surface_index = entity.surface.index

    clusterio_handler.transmute_job(job, entity)
end)

return ctron_plugin
