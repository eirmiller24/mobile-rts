-- Maze TD (design_m5.md §3.10 target map): auto-scaling waves of creeps march
-- the serpentine lane from `spawn` to `exit`; the player's towers thin them out.
-- A creep that reaches the exit costs a life; lose them all and you lose. Clear
-- all the waves and you win. The whole scenario is data — this is the language.

globals
	wave: int = 0
	lives: int = 20
	spawning: bool = false
end

-- A wave every 12s. Wave W sends (4 + W*2) creeps, each scaled to 60 + W*45 hp,
-- spaced ~0.15s apart. Auto-scaling: later waves are bigger and tankier.
on every(12s)
	if wave >= 12 then
		return
	end
	wave = wave + 1
	spawning = true
	display_message(PLAYER_1, "Wave incoming")
	local count: int = 4 + wave * 2
	local hp: int = 60 + wave * 45
	local i: int = 0
	while i < count do
		local c: unit = create_unit(td.creep, PLAYER_2, region_random_point(spawn))
		set_unit_hp(c, hp)
		order_move(c, region_center(exit))
		i = i + 1
		wait(3)
	end
	spawning = false
end

-- A creep killed by a tower pays an alloy bounty (build more towers).
on unit_dies
	if owner(dying_unit()) == PLAYER_2 then
		add_resource(PLAYER_1, ALLOY, 8)
	end
end

-- A creep that reaches the exit leaks: remove it silently and dock a life.
on unit_enters_region(exit)
	local u: unit = entering_unit()
	if owner(u) == PLAYER_2 then
		remove_unit(u)
		lives = lives - 1
		ping_minimap(PLAYER_1, region_center(exit))
		display_message(PLAYER_1, "A creep leaked!")
		if lives <= 0 then
			declare_defeat(PLAYER_1)
		end
	end
end

-- Victory check: once every wave is spawned and the field is clear, you win.
on every(2s)
	if wave >= 12 and not spawning then
		local remaining: group = units_of_player(PLAYER_2, ANY)
		if group_size(remaining) == 0 then
			declare_victory(PLAYER_1)
		end
	end
end
