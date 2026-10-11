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

It finds the Pocket SD card, asks you to confirm, copies the core, your BIOS (step 2) and this guide, and
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
│           └── psxbios.bin      <- your BIOS (step 2)
├── Cores/
│   └── defgenx.PSX/
│       ├── psx.rbf_r            <- the core bitstream
│       ├── core.json  data.json  input.json  interact.json  video.json ...
└── Platforms/
    └── psx.json
```

On macOS, copy the folders with Finder or `ditto`. Don't replace the existing `Assets`, `Cores` or
`Platforms` folders; merge into them. Eject the card cleanly afterwards.

## 2. BIOS (required)

The core needs a PlayStation BIOS. It is Sony's code, so it can't be shipped with the core: use a dump of your
own console's BIOS. The file must be a raw 512 KB image (exactly 524,288 bytes), for example `scph1001.bin`
(US), `scph5502.bin` (EU) or `scph5500.bin` (JP). On the card it must be named
`Assets/psx/defgenx.PSX/psxbios.bin`.

The installer copies it for you. It uses the file you name with `--bios`, and otherwise looks for `psxbios.bin`
or `scph*.bin` in these places, in order:
1. beside the installer, and in its `bios/` folder;
2. on the card, in `Assets/psx/common/` and at the root;
3. in your Downloads folder and your home folder.

If it finds none, it asks for the path; you can drag the file into the window. A BIOS already on the card is
kept.

## 3. Start it

On the Pocket, go to *openFPGA → PlayStation*. The BIOS slot is required, so without `psxbios.bin` the Pocket
reports a missing file instead of starting the core.

## Troubleshooting

* **The core is not in the list:** `Cores/defgenx.PSX/` or `Platforms/psx.json` is missing. Run the installer again.
* **The Pocket reports a missing file:** the BIOS is not at `Assets/psx/defgenx.PSX/psxbios.bin`, or it is not exactly 524,288 bytes.
* **Stuck with odd settings:** erase the saved settings with `./install.sh --reset-settings` (Windows:
  `install.bat -ResetSettings`), or delete the folder `Settings/defgenx.PSX/` on the card.
