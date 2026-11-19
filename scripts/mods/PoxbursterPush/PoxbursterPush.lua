local mod = get_mod("PoxbursterPush")

-- ============================================================================
-- PoxbursterPush
--
-- Flow:
--   1. Detect a Poxburster (chaos_poxwalker_bomber) within the detection radius.
--   2. Switch to melee early so the weapon is ready in time.
--   3. Once it reaches push distance, block and use a light attack to push it away.
--   4. Release control while leaving the player on melee; never switch back automatically.
--
-- Runtime failures are reported through the Darktide Mod Framework log.
-- ============================================================================


-- ============================================================================
-- Local references
-- ============================================================================
local Unit         = Unit
local Vector3      = Vector3
local ScriptUnit   = ScriptUnit
local Managers     = Managers
local PhysicsWorld = PhysicsWorld
local Application  = Application
local World        = World
local pairs        = pairs
local pcall        = pcall
local type         = type
local tostring     = tostring
local math_huge    = math.huge
local math_sqrt    = math.sqrt
local math_atan2   = math.atan2
local math_pi      = math.pi

-- ============================================================================
-- Constants
-- ============================================================================

-- Internal Poxburster breed name
local BURSTER_BREED = "chaos_poxwalker_bomber"

-- Melee slot
local MELEE_SLOT = "slot_primary"

-- Only take over when the player is holding a weapon.
local TAKEOVER_SLOTS = {
	slot_primary   = true,
	slot_secondary = true,
}

-- Player states that prevent input control
local DISABLED_STATES = {
	dead            = true,
	knocked_down    = true,
	hogtied         = true,
	pounced         = true,
	netted          = true,
	mutant_charged  = true,
	catapulted      = true,
	ledge_hanging   = true,
	stunned         = true,
	grabbed         = true,
	minigame        = true,
	interacting     = true,
}

-- Timing in seconds
local SCAN_INTERVAL    = 0.10  -- Scan interval while Poxbursters are present.
local IDLE_SCAN_INTERVAL = 0.50 -- Fallback scan interval. Spawn hooks can trigger an immediate scan.
local BLOCK_TIME       = 0.10  -- Time allowed for the weapon to enter block.
local PUSH_TIME        = 0.15  -- Push input window.
local DODGE_START      = 0.05  -- Delay the dodge until after the push begins.
local SWAP_TIMEOUT     = 1.50  -- Weapon swap timeout.
local WAIT_TIMEOUT     = 10.0  -- Maximum wait for a target to enter push range.
local ENGAGE_TIMEOUT   = 20.0  -- Maximum duration of an engagement.
local WIELD_GRACE      = 0.35  -- Wait for weapon-swap input and any replayed requests to stop.
local PUSH_RECORD_KEEP = 15.0  -- Retention time for per-target push records.

local DODGE_MOVE_CAP   = 0.12  -- Limit forced backward movement after the dodge starts.
local PUSH_FLOOR       = 0.80  -- Minimum delay before repeating the last target.

-- Engagement states
local ST = {
	IDLE     = 0,  -- Scan for targets.
	SWAP     = 1,  -- Switch to melee.
	WAIT     = 2,  -- Wait for push range with melee equipped.
	BLOCK    = 3,  -- Start blocking.
	PUSH     = 4,  -- Push the target.
	DODGE    = 5,  -- Dodge backward.
	HOLD     = 6,  -- Briefly hold block.
	RELEASE  = 7,  -- Stop controlling input; remain on melee.
	COOLDOWN = 8,  -- Delay the next engagement.
}

-- ============================================================================
-- Runtime state
-- ============================================================================
local S = {
	state          = ST.IDLE,
	timer          = 0,
	scan_timer     = 0,
	engage_timer   = 0,
	target         = nil,
	target_dist_sq = math_huge,
	push_total     = 0,     -- Pushes during the current engagement.
}

-- Elapsed time independent of the game clock.
local _now = 0

-- Last push time for each target.
local _pushed_at = {}
local encounter_pushes = {}

-- Last push time across all targets.
local _last_push_at = -math_huge

-- Reuse the input override table each frame.
local _out = {}

-- Store scalar movement values. Engine vectors are temporary and must be created in the input hook.
local _move_override = { active = false, x = 0, y = 0 }

-- Whether the mod is controlling inputs.
local _active = false

-- Whether the player requested a swap during takeover.
local _player_wield_pressed = false

-- A positive countdown defers takeover while swap requests are still arriving.
local _wield_seen  = false
local _wield_quiet = 0

-- Sprint input can stay true with movement mods. Limit forced block time to avoid disrupting slides.


-- ============================================================================
-- Game state helpers
-- ============================================================================

local function get_physics_world()
	local world = Application.main_world()
	if not world then
		return nil
	end

	local ok, pw = pcall(World.physics_world, world)
	return ok and pw or nil
end

-- Get the local player once the level or lobby is ready.
---
-- An early player lookup can call a native network function before initialization and crash the game.
local function get_local_player()
	local player_manager = Managers.player
	if not player_manager then
		return nil
	end

	-- The extension manager is unavailable during loading and in the main menu.
	local managers_state = Managers.state
	if not managers_state or not managers_state.extension then
		return nil
	end

	if player_manager.local_player_safe then
		return player_manager:local_player_safe(1)
	end

	return player_manager:local_player(1)
end

-- Check whether geometry blocks the line between two points.
local function has_line_of_sight(physics_world, from, to)
	if not physics_world or not from or not to then
		return false
	end

	local delta = to - from
	local distance = Vector3.length(delta)
	if distance <= 0.001 then
		return true
	end

	local hit = PhysicsWorld.raycast(
		physics_world,
		from,
		Vector3.normalize(delta),
		distance,
		"closest",
		"collision_filter",
		"filter_ray_aim_assist_line_of_sight"
	)

	return not hit
end

-- Use the head node when available.
local function aim_position(unit)
	if Unit.has_node(unit, "j_head") then
		return Unit.world_position(unit, Unit.node(unit, "j_head"))
	end

	return Unit.world_position(unit, 1)
end

local function get_unit_data(unit)
	return ScriptUnit.has_extension(unit, "unit_data_system")
		and ScriptUnit.extension(unit, "unit_data_system")
		or nil
end

-- Get the currently equipped slot.
local function get_wielded_slot(player_unit)
	local unit_data = get_unit_data(player_unit)
	local inventory = unit_data and unit_data:read_component("inventory")
	return inventory and inventory.wielded_slot
end

-- Check whether the player can act.
local function is_player_disabled(player_unit)
	local unit_data = get_unit_data(player_unit)
	if not unit_data then
		return true
	end

	local character_state = unit_data:read_component("character_state")
	if character_state and character_state.state_name and DISABLED_STATES[character_state.state_name] then
		return true
	end

	local disabled_state = unit_data:read_component("disabled_character_state")
	if disabled_state and disabled_state.disabling_type and DISABLED_STATES[disabled_state.disabling_type] then
		return true
	end

	return false
end

-- Cache breed lookups with weak keys so destroyed units can be collected.
local _is_burster = setmetatable({}, { __mode = "k" })

local function is_burster(unit)
	local cached = _is_burster[unit]
	if cached ~= nil then
		return cached
	end

	local unit_data = get_unit_data(unit)
	local breed = unit_data and unit_data:breed()

	-- Retry the breed lookup for units whose extensions are still initializing.
	if not breed then
		return false
	end

	local result = (breed.name == BURSTER_BREED)
	_is_burster[unit] = result
	return result
end

-- ============================================================================
-- Track live Poxbursters to adjust the scan interval.
--
-- Spawn and death hooks update the count. Slow fallback scans still run at zero.
-- The host receives the unit directly. Clients look it up by game object ID.
--
-- Reconcile the count periodically to handle units removed without a death event.
-- ============================================================================
local _burster_count  = 0
local _counted        = setmetatable({}, { __mode = "k" })
local _pending_spawns = {}
local _spawn_dirty    = false
local _reconcile_timer = 0

local function note_spawn(unit)
	if unit and mod:get("assist_enabled") ~= false then
		_pending_spawns[#_pending_spawns + 1] = unit
		_spawn_dirty = true
	end
end

pcall(function()
	mod:hook_safe(CLASS.UnitSpawnerManager, "_add_network_unit", function(_self, unit)
		note_spawn(unit)
	end)
end)

pcall(function()
	mod:hook_safe(CLASS.UnitSpawnerManager, "spawn_husk_unit", function(_self, game_object_id)
		local spawner = Managers.state and Managers.state.unit_spawner
		local units   = spawner and spawner._network_units
		note_spawn(units and units[game_object_id])
	end)
end)

pcall(function()
	mod:hook_safe(CLASS.MinionDeathManager, "set_dead", function(_self, unit)
		if unit and _counted[unit] then
			_counted[unit] = nil
			_burster_count = _burster_count - 1
			if _burster_count < 0 then
				_burster_count = 0
			end
		end
	end)
end)

-- Process queued spawns during update, when their extensions may be ready.
local function process_spawns()
	local n = #_pending_spawns
	if n == 0 then
		return
	end

	for i = 1, n do
		local unit = _pending_spawns[i]
		_pending_spawns[i] = nil

		if unit and Unit.alive(unit) and not _counted[unit] and is_burster(unit) then
			_counted[unit] = true
			_burster_count = _burster_count + 1
		end
	end
end

-- Remove tracked units that are no longer alive.
local function reconcile_burster_count()
	local n = 0
	for unit in pairs(_counted) do
		if Unit.alive(unit) then
			n = n + 1
		else
			_counted[unit] = nil
		end
	end
	_burster_count = n
end

-- Reuse the broadphase query result table.
local QUERY_RESULTS = {}

-- Hosts expose the AI action. Remote clients expose pose and replicated velocity.
local function active_burster(unit, player_pos)
	local blackboard = BLACKBOARDS and BLACKBOARDS[unit]
	if blackboard and ((blackboard.stagger and blackboard.stagger.num_triggered_staggers > 0)
		or (blackboard.death and blackboard.death.staggered_during_lunge)) then
		return false
	end
	local behavior = ScriptUnit.has_extension(unit, "behavior_system")
	if behavior and behavior.running_action then
		return behavior:running_action() == "approach"
	end

	local movement = ScriptUnit.has_extension(unit, "locomotion_system")
	if not movement or not movement.current_velocity or not Unit.has_node(unit, "j_head") then
		return false
	end
	local root = Unit.world_position(unit, 1)
	local head = Unit.world_position(unit, Unit.node(unit, "j_head"))
	local velocity = movement:current_velocity()
	if not velocity or head.z - root.z < 0.65 then
		return false
	end
	local dx, dy = player_pos.x - root.x, player_pos.y - root.y
	local closing = velocity.x * dx + velocity.y * dy
	return closing > 0.35 * math_sqrt(dx * dx + dy * dy)
end

local function find_nearest_burster(player_unit, player_pos, camera_pos, physics_world, range, require_los)
	local extension_manager = Managers.state and Managers.state.extension
	if not extension_manager then
		return nil, math_huge
	end

	local broadphase_system = extension_manager:system("broadphase_system")
	local broadphase        = broadphase_system and broadphase_system.broadphase
	local side_system       = extension_manager:system("side_system")
	local side              = side_system and side_system.side_by_unit[player_unit]

	if not broadphase or not side or not side.relation_side_names then
		return nil, math_huge
	end

	local enemy_side_names = side:relation_side_names("enemy")
	if not enemy_side_names then
		return nil, math_huge
	end

	local count = Broadphase.query(broadphase, player_pos, range, QUERY_RESULTS, enemy_side_names)

	local limit = mod:get("cluster_response") and (mod:get("max_pushes") or 2)
	local range_sq = range * range
	local best_unit, best_dist_sq = nil, math_huge
	for i = 1, count do
		local unit = QUERY_RESULTS[i]

		if unit and unit ~= player_unit and Unit.alive(unit) and is_burster(unit) and active_burster(unit, player_pos) then
			local delta   = Unit.world_position(unit, 1) - player_pos
			local dist_sq = Vector3.dot(delta, delta)

			local last = _pushed_at[unit]
			local exhausted = limit and (encounter_pushes[unit] or 0) >= limit
			if not exhausted and (not last or _now - last >= (mod:get("repush_delay") or 2))
				and dist_sq <= range_sq and dist_sq < best_dist_sq then
				if not require_los or has_line_of_sight(physics_world, camera_pos, aim_position(unit)) then
					best_unit    = unit
					best_dist_sq = dist_sq
				end
			end
		end
	end

	return best_unit, best_dist_sq
end

-- Turn horizontally toward the target while preserving pitch.
local function face_target(player, player_unit, camera_pos, target_unit)
	if not player or not player.set_orientation or not player.get_orientation then
		return
	end

	local delta = aim_position(target_unit) - camera_pos
	if Vector3.length(delta) < 0.001 then
		return
	end

	local dir = Vector3.normalize(delta)
	local target_yaw = math_atan2(dir.y, dir.x) - math_pi * 0.5

	local orientation = player:get_orientation()
	if not orientation then
		return
	end

	-- Subtract recoil yaw so the final view points at the target.
	local unit_data = get_unit_data(player_unit)
	local recoil = unit_data and unit_data:read_component("recoil")
	local yaw_offset = recoil and recoil.yaw_offset or 0

	player:set_orientation(target_yaw - yaw_offset, orientation.pitch or 0, 0)
end

-- Force backward movement for this frame.
local function set_backward_move()
	_move_override.active = true
	_move_override.x = 0
	_move_override.y = -1

	-- Override only move_forward on component-based input paths to avoid doubling movement.
	_out["move_forward"] = -1.0
end

-- Apply both per-target and global push cooldowns.
local function can_push(unit, repush_delay)
	if _pushed_at[unit] == _last_push_at and (_now - _last_push_at) < PUSH_FLOOR then
		return false
	end
	local last = _pushed_at[unit]
	return not last or (_now - last) >= repush_delay
end

local function mark_pushed(unit)
	_last_push_at = _now
	if unit then
		_pushed_at[unit] = _now
	end
end

-- Remove expired push records and records for dead units.
local function prune_pushed_records()
	for unit, t in pairs(_pushed_at) do
		if not Unit.alive(unit) or (_now - t) > PUSH_RECORD_KEEP then
			_pushed_at[unit] = nil
		end
	end
end

-- Reset the engagement state.
local function reset_state()
	for unit in pairs(encounter_pushes) do encounter_pushes[unit] = nil end
	S.state          = ST.IDLE
	S.timer          = 0
	S.engage_timer   = 0
	S.committed_target = nil
	S.target         = nil
	S.target_dist_sq = math_huge
	S.push_total     = 0
end

local function goto_state(new_state)
	S.state = new_state
	S.timer = 0
end

-- ============================================================================
-- Input overrides
-- ============================================================================
local function input_hook(func, self, action_name)
	if type(action_name) ~= "string" then
		return func(self, action_name)
	end

	-- Watch weapon swaps even while idle. A swap cancels takeover and refreshes the grace period.
	if action_name == "quick_wield" or action_name:sub(1, 5) == "wield" then
		local raw = func(self, action_name)
		if raw then
			_wield_seen = true
			if _active then
				_player_wield_pressed = true
				_active = false
			end
		end

		local injected = _active and _out[action_name] or nil
		if injected ~= nil then
			return injected
		end

		return raw
	end

	if not _active then
		return func(self, action_name)
	end

	-- Override combined movement during the dodge. Negative Y moves backward.
	if action_name == "move" and _move_override.active then
		return Vector3(_move_override.x, _move_override.y, 0)
	end

	local injected = _out[action_name]
	if injected ~= nil then
		return injected
	end

	return func(self, action_name)
end

mod:hook(CLASS.InputService, "_get", input_hook)

-- Hook simulated input when the game exposes it.
pcall(function()
	mod:hook(CLASS.InputService, "_get_simulate", input_hook)
end)


-- ============================================================================
-- Update loop
-- ============================================================================
local function update_impl(dt)
	_now = _now + dt

	-- Clear the previous frame's input overrides.
	for key in pairs(_out) do
		_out[key] = nil
	end
	_move_override.active = false

	-- Restart the grace period when swap input arrives.
	if _wield_seen then
		_wield_seen  = false
		_wield_quiet = WIELD_GRACE
	elseif _wield_quiet > 0 then
		_wield_quiet = _wield_quiet - dt
	end

	if not mod:is_enabled() or mod:get("assist_enabled") == false then
		_active = false
		if S.state ~= ST.IDLE then
			reset_state()
		end
		return
	end

	local player      = get_local_player()
	local player_unit = player and player.player_unit

	if not player_unit or not Unit.alive(player_unit) or is_player_disabled(player_unit) then
		_active = false
		if S.state ~= ST.IDLE then
			reset_state()
		end
		return
	end


	-- Release control when the player requests a weapon swap.
	if _player_wield_pressed then
		_player_wield_pressed = false

		if S.state ~= ST.IDLE and S.state ~= ST.COOLDOWN then
			reset_state()
			goto_state(ST.COOLDOWN)
			_active = false
			return
		end
	end

	local camera_manager = Managers.state and Managers.state.camera
	local camera_pos     = camera_manager and camera_manager:camera_position(player.viewport_name)

	if not camera_pos then
		_active = false
		if S.state ~= ST.IDLE then
			reset_state()
		end
		return
	end

	-- ------------------------------------------------------------------
	-- Read mod settings.
	-- ------------------------------------------------------------------
	local detect_range  = mod:get("detect_range") or 8
	local push_range    = mod:get("push_range") or 5
	local pre_swap      = mod:get("pre_swap")
	local require_los   = mod:get("require_los")
	local do_face       = mod:get("face_target")
	local hold_time     = mod:get("post_push_hold") or 0.15
	local cooldown_time = mod:get("cooldown") or 0.4
	local do_dodge      = mod:get("dodge_back")
	local dodge_time    = mod:get("dodge_duration") or 0.3
	local repush_delay  = mod:get("repush_delay") or 2.0
	local max_pushes    = mod:get("max_pushes") or 2

	if push_range > detect_range then
		push_range = detect_range
	end
	local push_range_sq = push_range * push_range

	-- ------------------------------------------------------------------
	-- Target selection
	-- ------------------------------------------------------------------
	local player_pos    = Unit.world_position(player_unit, 1)
	local physics_world = require_los and get_physics_world()

	S.scan_timer = S.scan_timer - dt

	-- Process pending spawns and periodically reconcile the live count.
	process_spawns()
	_reconcile_timer = _reconcile_timer - dt
	if _reconcile_timer <= 0 then
		_reconcile_timer = 2.0
		reconcile_burster_count()
	end

	-- Scan faster with live Poxbursters and immediately after a new spawn.
	local scan_interval = (_burster_count > 0) and SCAN_INTERVAL or IDLE_SCAN_INTERVAL

	-- Rescan immediately if the current target dies or disappears.
	local force_rescan = (S.target ~= nil and not Unit.alive(S.target)) or _spawn_dirty

	if S.scan_timer <= 0 or force_rescan then
		_spawn_dirty = false
		S.scan_timer = scan_interval
		prune_pushed_records()

		S.target, S.target_dist_sq = find_nearest_burster(
			player_unit, player_pos, camera_pos, physics_world, detect_range, require_los
		)

	elseif S.target then
		-- Update the current target's distance between scans.
		local delta = Unit.world_position(S.target, 1) - player_pos
		S.target_dist_sq = Vector3.dot(delta, delta)
	end

	-- ------------------------------------------------------------------
	-- Enforce the total engagement timeout.
	-- ------------------------------------------------------------------
	if S.state ~= ST.IDLE and S.state ~= ST.COOLDOWN then
		S.engage_timer = S.engage_timer + dt
		if S.engage_timer > ENGAGE_TIMEOUT then
			goto_state(ST.RELEASE)
		end
	end

	-- ------------------------------------------------------------------
	-- Advance the engagement state.
	-- ------------------------------------------------------------------
	local wielded = get_wielded_slot(player_unit)
	local state   = S.state
	-- Release pending attack and movement inputs if the equipped item changes.
	if wielded ~= MELEE_SLOT and (mod:get("melee_only") or not TAKEOVER_SLOTS[wielded]
		or state == ST.BLOCK or state == ST.PUSH or state == ST.DODGE or state == ST.HOLD) then
		_active = false
		if state == ST.IDLE then
			return
		elseif state ~= ST.COOLDOWN and state ~= ST.RELEASE then
			reset_state()
			goto_state(ST.COOLDOWN)
			return
		end
	end
	local committed = S.committed_target
	local separate = mod:get("cluster_response")
	local attempts = separate and (encounter_pushes[S.target] or 0) or S.push_total
	if (state == ST.DODGE or state == ST.HOLD) and attempts < max_pushes
		and wielded == MELEE_SLOT and S.target and S.target ~= committed
		and S.target_dist_sq <= push_range_sq and can_push(S.target, repush_delay) then
		S.committed_target = S.target
		committed = S.target
		goto_state(ST.BLOCK)
		state = ST.BLOCK
	end

	-- Revalidate the same target immediately before the push.
	if state == ST.BLOCK or (state == ST.PUSH and S.timer == 0) then
		local valid = wielded == MELEE_SLOT and committed and Unit.alive(committed) and active_burster(committed, player_pos)
		if valid then
			local delta = Unit.world_position(committed, 1) - player_pos
			valid = Vector3.dot(delta, delta) <= push_range_sq
				and (not require_los or has_line_of_sight(physics_world, camera_pos, aim_position(committed)))
		end
		if not valid then
			S.scan_timer = 0
			S.committed_target = nil
			goto_state(ST.WAIT)
			_active = false
			return
		end
	end

	if state == ST.IDLE then
		if S.target and TAKEOVER_SLOTS[wielded] and _wield_quiet > 0 then
			-- Wait for weapon-swap requests to stop before taking over.
		elseif S.target and TAKEOVER_SLOTS[wielded] then
			local in_push_range = S.target_dist_sq <= push_range_sq

			-- Equip melee as soon as a target enters detection range when pre-swap is enabled.
			if pre_swap or in_push_range then
				S.engage_timer   = 0
				S.push_total     = 0
				-- Already holding melee: wait directly. Never enter the weapon-swap
				-- state unless a ranged-to-melee switch is actually required.
				goto_state(wielded == MELEE_SLOT and ST.WAIT or ST.SWAP)
			end
		end

	elseif state == ST.SWAP then
		S.timer = S.timer + dt

		if not S.target then
			goto_state(ST.RELEASE)
		elseif wielded ~= MELEE_SLOT then
			_out["wield_1"] = true

			if S.timer > SWAP_TIMEOUT then
				goto_state(ST.RELEASE)
			end
		else
			goto_state(ST.WAIT)
		end

	elseif state == ST.WAIT then
		S.timer = S.timer + dt

		if not S.target or not TAKEOVER_SLOTS[wielded] or S.timer > WAIT_TIMEOUT then
			goto_state(ST.RELEASE)
		elseif wielded ~= MELEE_SLOT then
			-- Return to melee if an ability changed the equipped weapon.
			goto_state(ST.SWAP)
		elseif S.target_dist_sq <= push_range_sq and can_push(S.target, repush_delay) then
			S.committed_target = S.target
			goto_state(ST.BLOCK)
		end

	elseif state == ST.BLOCK then
		S.timer = S.timer + dt
		_out["action_two_hold"] = true

		if do_face and committed and Unit.alive(committed) then
			face_target(player, player_unit, camera_pos, committed)
		end

		if S.timer >= BLOCK_TIME then
			goto_state(ST.PUSH)
		end

	elseif state == ST.PUSH then
		S.timer = S.timer + dt

		-- A light attack while blocking performs a push.
		_out["action_two_hold"]    = true
		_out["action_one_hold"]    = true
		_out["action_one_pressed"] = true

		if do_face and committed and Unit.alive(committed) then
			face_target(player, player_unit, camera_pos, committed)
		end

		-- Delay backward movement so the push can connect.
		if do_dodge and S.timer >= DODGE_START then
			set_backward_move()
			_out["dodge"] = 1.0
		end

		if S.timer >= PUSH_TIME then
			S.push_total = S.push_total + 1
			encounter_pushes[committed] = (encounter_pushes[committed] or 0) + 1
			mark_pushed(committed)
			S.scan_timer = 0

			if do_dodge then
				goto_state(ST.DODGE)
			else
				goto_state(ST.HOLD)
			end
		end

	elseif state == ST.DODGE then
		S.timer = S.timer + dt

		-- The push phase already sent the dodge input. Holding it could spend extra dodges.
		--
		-- Cap forced backward movement after the dodge impulse.
		if S.timer < DODGE_MOVE_CAP then
			set_backward_move()
		end
		-- Release block during the dodge so the player can sprint and slide.

		if S.timer >= dodge_time then
			goto_state(ST.HOLD)
		end

	elseif state == ST.HOLD then
		S.timer = S.timer + dt
		-- Hold block briefly after the push.
		_out["action_two_hold"] = true

		if S.timer >= hold_time then
			if not separate and S.push_total >= max_pushes then
				-- Release control after reaching the push limit.
				goto_state(ST.RELEASE)
			elseif S.target then
				-- Wait for another push opportunity with melee equipped.
				goto_state(ST.WAIT)
			else
				goto_state(ST.RELEASE)
			end
		end

	elseif state == ST.RELEASE then
		-- Never switch back to the previously held weapon. The player stays on melee.
		goto_state(ST.COOLDOWN)

	elseif state == ST.COOLDOWN then
		S.timer = S.timer + dt

		if S.timer >= cooldown_time then
			reset_state()
		end
	end

	_active = S.state ~= ST.IDLE and S.state ~= ST.COOLDOWN
end

-- Log update errors and release input control.
local _update_error_reported = false

function mod.update(dt)
	local ok, err = pcall(update_impl, dt)

	if not ok then
		_active = false
		reset_state()
		if not _update_error_reported then
			_update_error_reported = true
			mod:error("Update failed; input control was released: %s", tostring(err))
		end
	end
end

-- ============================================================================
-- Mod lifecycle
-- ============================================================================
mod.on_disabled = function()
	_active = false
	reset_state()
end


mod.on_setting_changed = function(setting_id)
	if setting_id == "assist_enabled" then
		_active = false
		_player_wield_pressed = false
		_move_override.active = false
		S.scan_timer = 0
		reset_state()
	end
end

mod.on_game_state_changed = function(status)
	if status == "enter" then
		_active = false
		_player_wield_pressed = false
		S.scan_timer = 0
		_update_error_reported = false
		_move_override.active = false
		_wield_seen   = false
		_wield_quiet  = 0
		_last_push_at = -math_huge

		-- Reset spawn tracking on a game state transition.
		_burster_count = 0
		_spawn_dirty   = false
		_reconcile_timer = 0
		for unit in pairs(_counted) do
			_counted[unit] = nil
		end
		for i = #_pending_spawns, 1, -1 do
			_pending_spawns[i] = nil
		end

		reset_state()

		-- Clear push records on a game state transition.
		for unit in pairs(_pushed_at) do
			_pushed_at[unit] = nil
		end

	end
end

