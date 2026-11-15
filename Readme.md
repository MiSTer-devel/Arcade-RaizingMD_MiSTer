<p align="left">
  <img src="raizing.gif" width="800" alt="Raizing">
</p>

# W E L C O M E &nbsp;T O &nbsp;V I O L E N T &nbsp;C I T Y

| Title                                                                                                                 |
|-----------------------------------------------------------------------------------------------------------------------|
| [**Sorcer Striker**](https://en.wikipedia.org/wiki/Sorcer_Striker) |
| [**Kingdom Grandprix**](https://en.wikipedia.org/wiki/Kingdom_Grand_Prix) |
| [**Battle Garegga**](https://en.wikipedia.org/wiki/Battle_Garegga) |
| [**Armed Police Batrider**](https://en.wikipedia.org/wiki/Armed_Police_Batrider) |
| [**Battle Bakraid**](https://en.wikipedia.org/wiki/Battle_Bakraid) |

_**This core adds `[MD]` to the MRA names, allowing them to be installed alongside the closed source versions.**_

## Development

This is a Codex-assisted rewrite of the [Arcade-Razing](https://github.com/TheJesusFish/Arcade-Raizing_MiSTer) core, with the goal being that all the legacy code was replaced by original code. It was important that any hardware measured legacy code was replaced by code that had hardware measurements of its own. 

These new hardware measurements come courtesy of MiSTer community members, who were kind enough to run test roms on their personal boards, and record the output for me. The test roms were extremely helpful in tuning behaviors that MAME approximates. This core a combination of MAME, community hardware modules, and test rom measurements run on actual hardware.

With that said, Codex and Claude were used throughout this rewrite. If that bothers you, and you'd rather not engage with it, add this to your `downloader.ini` file under the `[mister]` category:

```ini
filter = !arcade-raizingmd
```
_If you have one of the Raizing arcade boards and would like to help make this more accurate, please reach out._

## Modules and Sources

| Module | Source |
| --- | --- |
| MiSTer framework | [MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) |
| FX68K | [ijor/fx68k](https://github.com/ijor/fx68k) |
| T80 | [mist-devel/T80](https://github.com/mist-devel/T80) |
| IKAOPM | [ika-musume/IKAOPM](https://github.com/ika-musume/IKAOPM) |
| JT6295 | [jotego/jt6295](https://github.com/jotego/jt6295) |
| SDRAM | [ika-musume/ikautil_SDRAM](https://github.com/ika-musume/ikautil_SDRAM) |
| Save states | [Taito F2](https://github.com/MiSTer-devel/Arcade-TaitoF2_MiSTer) (adapted from the [Arcade-Raizing](https://github.com/TheJesusFish/Arcade-Raizing_MiSTer) repo.)|

_Original [Arcade-Raizing](https://github.com/TheJesusFish/Arcade-Raizing_MiSTer) implementation was based on Pramod Somashekar's archived [Raizing-FPGA](https://github.com/psomashekar/Raizing_FPGA) repo._

## GReeTz AnD ThAnX
- Daniel Wallner, MikeJ, Sorg, and all other contributors for the T80 module
- JT for his JT6295 module
- Raki for his IKAOPM and SDRAM modules
- Jorge Cwik for the 68k module
- Wickerwaka (Martin Donlon, if you're nasty) for save state support in arcade games
- Zakk for picking the right music
- Sorg (again) for running this whole crazy thing
- The MiSTer community members who tested every broken build I threw up on Discord
- The Lovers
- The Haters

Say "Hi" to your mother for me.
