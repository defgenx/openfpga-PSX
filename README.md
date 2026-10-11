# PlayStation for Analogue Pocket (openFPGA)

A port of the PlayStation core to the [Analogue Pocket](https://www.analogue.co/pocket) (Cyclone V 5CEBA4F23C8, openFPGA).

**Status: work in progress, does not run on a Pocket yet.** The core is still larger than the chip, and the Pocket top
level holds a stub core. The plan, the measurements and what blocks a first boot are in
[docs/pocket/ROADMAP.md](docs/pocket/ROADMAP.md).

## Install

Put the Pocket's microSD card in your computer and run **`install.bat`** (Windows, double-click) or **`./install.sh`**
(macOS, Linux). It finds the card, copies the core and a BIOS (the free OpenBIOS, or your own dump), and never replaces a file without asking.
Details, and how to do it by hand: [INSTALL.md](INSTALL.md).

The PSX memory test core (`pocket/memtest/`) checks the Pocket's SDRAM, PSRAM and SRAM at the PSX core's clocks; see
[docs/pocket/MEMTEST.md](docs/pocket/MEMTEST.md).

## Layout

| Path | Contents |
|---|---|
| `pocket/psx/` | the Pocket core: APF top level, PLLs, data slots, packaging (`build.sh`) |
| `pocket/memtest/` | the memory test core and its SD card installers |
| `pocket/common/` | the APF framework and memory controllers shared by both cores |
| `rtl/` | the PlayStation core, including the Pocket blocks (`*_pocket.vhd`, `psx_top_pocket.vhd`); the unmodified blocks are the golden models the Pocket blocks are tested against |
| `sim/` | differential harnesses (nvc, Icarus Verilog), the bandwidth model, the system simulation |
| `sizing/` | Quartus fit projects that measure each block's area |
| `docs/pocket/` | design notes, measurements and the roadmap |

## Credits and licence

This core is based on [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) by Robert Peip and its contributors. `rtl/`
is their PlayStation implementation, modified and extended here for the Pocket. Their copyright notices remain in the files.

Licensed under the GNU General Public License v2, like the original: see [LICENSE](LICENSE).

The bundled BIOS, `pocket/psx/dist/Assets/psx/defgenx.PSX/psxbios.bin`, is
[OpenBIOS](https://github.com/grumpycoders/pcsx-redux) by the PCSX-Redux authors, under the MIT licence
(`OpenBIOS-LICENSE.txt` beside it). The binary is Libreboot's 20241206 build.
