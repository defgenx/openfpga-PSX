# Installing the PlayStation core on the Analogue Pocket

> **Work in progress.** Today's build is the Pocket shell around a placeholder core: it installs and loads,
> but it does not run the PlayStation BIOS or games yet. The status is in
> [docs/pocket/ROADMAP.md](docs/pocket/ROADMAP.md).

## 1. Copy the core to the microSD card

**The easy way:** put the microSD card in your computer and run the installer from a clone of the repo:

| System        | Run                                                                 |
|---------------|---------------------------------------------------------------------|
| Windows       | double-click **`install.bat`** (or `.\install.ps1` in PowerShell)  |
| macOS / Linux | `./install.sh`                                                      |

It finds the Pocket SD card, asks you to confirm, copies the core, the BIOS (step 2) and this guide, and
offers to eject the card. Options:
- `--dry-run` / `-DryRun` shows what would be copied and changes nothing.
- `--sd /Volumes/POCKET` / `-SD E:\` names the card yourself.
- `--bios FILE` / `-Bios FILE` names the BIOS file.

The core comes from `pocket/psx/dist` once `pocket/psx/build.sh` has built it. Without a built core, the
installer downloads the newest GitHub release.

**It never replaces a file without asking.** Files already on the card that are identical are skipped.
For each one that differs, it asks `Replace it? [y]es / [N]o / [a]ll / [s]kip all`, and pressing Enter
keeps the card's file. Run without a console, or with the dry-run option, it never replaces anything and
lists what differs.

**By hand:** take the `defgenx.PSX.zip` produced by `pocket/psx/build.sh` and copy its contents to the
**root** of the Pocket's microSD card, merging them with the folders already there:

```
SD card root
├── Assets/
│   └── psx/
│       ├── common/
│       └── defgenx.PSX/
│           ├── psxbios.bin      <- OpenBIOS, or your own BIOS (step 2)
│           └── OpenBIOS-LICENSE.txt  OpenBIOS-README.txt
├── Cores/
│   └── defgenx.PSX/
│       ├── psx.rbf_r            <- the core bitstream
│       ├── core.json  data.json  input.json  interact.json  video.json ...
└── Platforms/
    └── psx.json
```

On macOS, copy the folders with Finder or `ditto`. Don't replace the existing `Assets`, `Cores` or
`Platforms` folders; merge into them. Eject the card cleanly afterwards.

## 2. BIOS (nothing to do)

The PlayStation needs its BIOS. Sony's BIOS can't be shipped, so the core comes with **OpenBIOS**, a free,
open-source replacement written by the PCSX-Redux authors (MIT licence, https://github.com/grumpycoders/pcsx-redux).
It is in `Assets/psx/defgenx.PSX/` as `psxbios.bin`, with `OpenBIOS-LICENSE.txt` and `OpenBIOS-README.txt`.

OpenBIOS has limits: not all games boot with it, it has no memory card save handler (games cannot save), and it
does not play music CDs. For full compatibility, use a dump of your own console's BIOS. It must be a raw 512 KB
image (exactly 524,288 bytes), for example `scph1001.bin` (US), `scph5502.bin` (EU) or `scph5500.bin` (JP).

**Your own BIOS always wins.** The installer uses the file you name with `--bios`. Otherwise it looks for
`psxbios.bin` or `scph*.bin` in these places, in order:
1. beside the installer, and in its `bios/` folder;
2. on the card, in `Assets/psx/common/` and at the root;
3. in your Downloads folder and your home folder.

It copies the first one it finds to `Assets/psx/defgenx.PSX/psxbios.bin`, in place of OpenBIOS. A BIOS already on
the card is kept, and it asks before replacing one. By hand: copy your dump over
`Assets/psx/defgenx.PSX/psxbios.bin`.

## 3. Start it

On the Pocket, go to *openFPGA → PlayStation*. Until the PlayStation core is in the build, it shows a status screen:
the SDRAM calibration, whether the BIOS arrived (`BIOS IS OPENBIOS` or `OWN`) and the pad input. A photo of it is
useful feedback. The BIOS slot is required: without `psxbios.bin` the Pocket
reports a missing file instead of starting the core.

## Troubleshooting

* **The core is not in the list:** `Cores/defgenx.PSX/` or `Platforms/psx.json` is missing. Run the installer again.
* **The Pocket reports a missing file:** the BIOS is not at `Assets/psx/defgenx.PSX/psxbios.bin`, or it is not exactly 524,288 bytes.
  Run the installer again: it puts OpenBIOS there.
* **A game does not boot, or cannot save:** it may need an original BIOS rather than OpenBIOS (step 2).
* **Stuck with odd settings:** erase the saved settings with `./install.sh --reset-settings` (Windows:
  `install.bat -ResetSettings`), or delete the folder `Settings/defgenx.PSX/` on the card.
