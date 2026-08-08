[PopTracker](https://github.com/black-sliver/PopTracker/) pack for `2Ship-AP`, the Archipelago integration built into [2ship2harkinian](https://github.com/garrettjoecox/2ship2harkinian) (apworld `mm_2ship`, game name `2 Ship 2 Harkinian (MM)`).

Forked from [Majoras-Mask-AP-PopTracker-Pack](https://github.com/seto10987/Majoras-Mask-AP-PopTracker-Pack) by Seto10987 and G4M3R L1F3. That pack targets a different apworld ("Majora's Mask Recompiled") and won't work with `2Ship-AP` — different games as far as Archipelago is concerned, with incompatible item/location IDs.

PopTracker v0.27.0 or higher is recommended.

## Status

- **Items**: fully remapped across Items/Equipment/Masks/Souls/Misc. Though I haven't tested Souls, but it is hooked up...I think.
- **Checks tab and map pins**: real accessibility logic, ported from the apworld's own region/logic solver — colors reflect what's actually reachable with your current items and options, including day/night clock shuffle, not just a flat checklist. Grass/pot/crate checks aren't tracked individually; there are a lot of them, but I think at some point I can break them out. There is a bunch of misc items I stuffed into different categories that were left over from dumping the 2Ship checks. They are either there to prevent some things from breaking, or I just didn't know what I wanted to do with it yet. A lot of it is ugly to look at, so that's why its hidden.
- **Map**: Nerrel's hand-painted HD overworld map, with Clock Town split into its own tab since it doesn't fit legibly at overworld zoom.
- **TODO**: There is a lot more to do with this, the icons are slightly off from where they are supposed to be after I updated it with Nerrel's map, they are pretty close, but they could use some more tinkering now to line it up better with the map. Ocean Spider house needs to be finished which shouldn't be too hard honestly. There is a lot of duplicates between the temple icons and the overworld checks. They are the same check, but in two places. Eventually I'll remove them from the overworld to make more space. I'm sure there is more, but that's all I can think of right now. As the 2Ship AP evolves, this will also have to adapt. This tracker should still work as that feature improves as long as the ID's don't drastically change, this should be able to update alongside it smoothly. Of course if something doesn't work or is drastically wonky, please let me know on discord or submit an issue here.

## Credits

- Overworld map art: **Nerrel**.
- **ProxySaw**: developer of the Archipelago feature for 2 Ship 2 Harkinian.
- **Phillyjawn**: real accessibility logic (region-graph solver ported from the `mm_2ship` apworld) and `mm_2ship` autotracking integration for this pack.
- **G4M3R L1F3**: author of the recompiled tracker this pack was forked from.
- **Seto10987**: original pack this was forked from.

## Autotracking

The only autotracking method is connecting to a slot on an Archipelago server:
1. Click the `AP` button in the top left of the window; a new window will open.
2. Enter the server host (`archipelago.gg` or `localhost`), followed by `:`, then the port.
3. Enter the slot name used in your yaml.
4. If applicable, enter the password.

If successful, the `AP` button turns green and items will track automatically as they're received.

## Disclaimer

For the folks who like to know, Claude assisted in the automapping IDs and logic from 2Ship to this tracker with the existing pins from the recomp. There was a lot to port over.