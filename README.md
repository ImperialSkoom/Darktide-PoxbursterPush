# Poxburster Push

Poxburster Push is a melee push assist for *Warhammer 40,000: Darktide*. When it spots an active Poxburster, it can equip melee, turn toward the target, block, shove, and dodge backward. You stay on melee afterward. A manual weapon swap interrupts the assist.

## Installation

1. Set up Darktide Mod Loader and Darktide Mod Framework (DMF) for your game installation.
2. Copy the `PoxbursterPush` folder into Darktide's `mods` directory. The entry file should be at `mods/PoxbursterPush/PoxbursterPush.mod`.
3. Add `PoxbursterPush` on its own line after `dmf` in `mods/mod_load_order.txt`.
4. Start Darktide and open **Mod Options**. Open **PoxbursterPush** and use the **Enable mod** checkbox at the top.

## Settings

| Section | Default behavior |
| --- | --- |
| **When to engage** | Detect visible Poxbursters within 8 m, equip melee on detection, and start the push sequence within 5 m. Enable **Only assist with melee equipped** if you prefer to draw melee yourself. |
| **Aim and movement** | Turn horizontally toward the target and dodge backward during the shove. You can disable either assist independently. |
| **Follow-up pushes** | Allow two attempts per Poxburster per encounter, with a 2 s delay before retrying the same one. Disable **Handle each Poxburster separately** to share the attempt limit across the group. |
