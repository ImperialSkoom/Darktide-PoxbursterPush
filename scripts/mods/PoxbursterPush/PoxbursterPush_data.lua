local mod = get_mod("PoxbursterPush")

return {
	name = mod:localize("mod_name"),
	description = mod:localize("mod_description"),
	is_togglable = false,
	options = {
		widgets = {
			{
				setting_id = "assist_enabled",
				type = "checkbox",
				default_value = true,
			},
			{
				setting_id = "approach",
				type = "group",
				sub_widgets = {
					{
						setting_id = "melee_only",
						type = "checkbox",
						default_value = false,
						tooltip = "melee_only_tooltip",
					},
					{
						setting_id    = "pre_swap",
						type          = "checkbox",
						default_value = true,
						tooltip       = "pre_swap_tooltip",
					},
					{
						setting_id      = "detect_range",
						type            = "numeric",
						default_value   = 8,
						range           = { 3, 20 },
						decimals_number = 1,
						tooltip         = "detect_range_tooltip",
					},
					{
						setting_id      = "push_range",
						type            = "numeric",
						default_value   = 5,
						range           = { 1, 15 },
						decimals_number = 1,
						tooltip         = "push_range_tooltip",
					},
					{
						setting_id    = "require_los",
						type          = "checkbox",
						default_value = true,
						tooltip       = "require_los_tooltip",
					},
				},
			},
			{
				setting_id = "player_controls",
				type = "group",
				sub_widgets = {
					{
						setting_id    = "face_target",
						type          = "checkbox",
						default_value = true,
						tooltip       = "face_target_tooltip",
					},
					{
						setting_id    = "dodge_back",
						type          = "checkbox",
						default_value = true,
						tooltip       = "dodge_back_tooltip",
					},
					{
						setting_id      = "dodge_duration",
						type            = "numeric",
						default_value   = 0.3,
						range           = { 0.1, 1 },
						decimals_number = 2,
						tooltip         = "dodge_duration_tooltip",
					},
				},
			},
			{
				setting_id = "follow_up",
				type = "group",
				sub_widgets = {
					{
						setting_id = "cluster_response",
						type = "checkbox",
						default_value = true,
						tooltip = "cluster_response_tooltip",
					},
					{
						setting_id      = "max_pushes",
						type            = "numeric",
						default_value   = 2,
						range           = { 1, 6 },
						decimals_number = 0,
						tooltip         = "max_pushes_tooltip",
					},
					{
						setting_id      = "repush_delay",
						type            = "numeric",
						default_value   = 2,
						range           = { 0, 8 },
						decimals_number = 1,
						tooltip         = "repush_delay_tooltip",
					},
					{
						setting_id      = "post_push_hold",
						type            = "numeric",
						default_value   = 0.15,
						range           = { 0, 1 },
						decimals_number = 2,
						tooltip         = "post_push_hold_tooltip",
					},
					{
						setting_id      = "cooldown",
						type            = "numeric",
						default_value   = 0.4,
						range           = { 0, 3 },
						decimals_number = 2,
						tooltip         = "cooldown_tooltip",
					},
				},
			},
		},
	},
}
