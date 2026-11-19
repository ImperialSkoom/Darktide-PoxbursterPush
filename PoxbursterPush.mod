return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`PoxbursterPush` encountered an error loading the Darktide Mod Framework.")

		new_mod("PoxbursterPush", {
			mod_script       = "PoxbursterPush/scripts/mods/PoxbursterPush/PoxbursterPush",
			mod_data         = "PoxbursterPush/scripts/mods/PoxbursterPush/PoxbursterPush_data",
			mod_localization = "PoxbursterPush/scripts/mods/PoxbursterPush/PoxbursterPush_localization",
		})
	end,
	packages = {},
}
