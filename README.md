# badapple.nvim

Play Bad Apple as a braille animation inside Neovim.

The plugin opens a transparent floating window over the current editor window, renders pre-generated braille subtitle frames, and optionally plays the audio track with `mpv`.

## Demo

[neovim also needs Bad Apple!!](https://www.bilibili.com/video/BV1v2FUzLEMi/)

GitHub README does not render Bilibili `<iframe>` embeds, so the demo is linked directly instead of embedded as an iframe.

## Features

- Neovim floating-window overlay
- Braille frame playback from an SRT-like frame file
- Optional audio playback through `mpv`
- Code masking: the animation leaves the visible text area clear enough to keep the editor readable
- Simple commands: `:BadAppleStart` and `:BadAppleStop`

## Requirements

- Neovim 0.9+
- `mpv` for audio playback
- A font with braille character support

Install `mpv`:

```bash
# Arch Linux
sudo pacman -S mpv

# Debian / Ubuntu
sudo apt install mpv

# macOS
brew install mpv
```

## Installation

Note: this plugin ships the braille frame data and audio through Git LFS. The first install has to download about 260 MB of LFS assets, so it may take a few minutes depending on your network.

### lazy.nvim

```lua
{
  "VKKKV/badapple.nvim",
  config = function()
    require("badapple").setup()
  end,
}
```

### packer.nvim

```lua
use({
  "VKKKV/badapple.nvim",
  config = function()
    require("badapple").setup()
  end,
})
```

### Native packages

```bash
git clone https://github.com/VKKKV/badapple.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/badapple.nvim
```

Then restart Neovim or run:

```vim
:helptags ALL
```

## Usage

Start playback:

```vim
:BadAppleStart
```

Stop playback:

```vim
:BadAppleStop
```

Lua API:

```lua
require("badapple").start()
require("badapple").stop()
```

## Configuration

Default config:

```lua
require("badapple").setup({
  frame_width = 179,
  frame_height = 73,
  sampling_scale = 1,
  padding = 2,
  frames_path = "lua/badapple/badapple.srt",
  audio_path = "lua/badapple/badapple.m4a",
  audio_enabled = true,
  audio_offset = 3000,
  fps = 30,
})
```

The old uppercase option names still work for backward compatibility, but new configs should use snake_case.

Useful options:

- `sampling_scale`: enlarge frames for high-resolution terminals.
- `padding`: extra columns kept clear around visible code.
- `audio_enabled`: set to `false` to play the animation without audio.
- `audio_offset`: delay animation start so it syncs with audio.
- `fps`: playback frame rate.

Disable audio:

```lua
require("badapple").setup({
  audio_enabled = false,
})
```

## Converting video to braille frames

This repository stores the generated frame file at:

```text
lua/badapple/badapple.srt
```

One practical workflow is:

1. Extract frames from the source video.
2. Convert each frame to a monochrome braille text frame.
3. Pack the frames into an SRT-like file where each subtitle block contains one rendered frame.

Example frame extraction:

```bash
mkdir -p media/frames
ffmpeg -i media/badapple.mp4 \
  -vf "fps=30,scale=358:292:flags=lanczos,format=gray" \
  media/frames/%06d.png
```

A small Python converter can then map pixels to Unicode braille cells. Braille cells encode a 2x4 pixel block into one character, so a `358x292` image becomes a `179x73` text frame:

```python
from pathlib import Path
from PIL import Image

DOTS = [0x01, 0x02, 0x04, 0x40, 0x08, 0x10, 0x20, 0x80]
fps = 30

def ts(ms: int) -> str:
    total_seconds, milli = divmod(ms, 1000)
    minutes, seconds = divmod(total_seconds, 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d},{milli:03d}"

def image_to_braille(path: Path, threshold: int = 128) -> list[str]:
    img = Image.open(path).convert("L")
    w, h = img.size
    rows = []
    for y in range(0, h, 4):
        line = []
        for x in range(0, w, 2):
            bits = 0
            for dy in range(4):
                for dx in range(2):
                    px = x + dx
                    py = y + dy
                    if px < w and py < h and img.getpixel((px, py)) < threshold:
                        bits |= DOTS[dy + dx * 4]
            line.append(chr(0x2800 + bits))
        rows.append("".join(line))
    return rows

frames = sorted(Path("media/frames").glob("*.png"))
out = Path("lua/badapple/badapple.srt")
with out.open("w", encoding="utf-8") as f:
    for i, frame in enumerate(frames, 1):
        start_ms = int((i - 1) * 1000 / fps)
        end_ms = int(i * 1000 / fps)
        f.write(f"{i}\n")
        f.write(f"{ts(start_ms)} --> {ts(end_ms)}\n")
        f.write("\n".join(image_to_braille(frame)))
        f.write("\n\n")
```

Install Pillow if needed:

```bash
python -m venv .venv
. .venv/bin/activate
pip install pillow
```

For large videos, keep generated intermediate frames under `media/`; this directory is ignored by Git.

## Converting audio

The plugin expects the audio file at:

```text
lua/badapple/badapple.m4a
```

Extract and compress audio from a video:

```bash
ffmpeg -i media/badapple.mp4 -vn -c:a aac -b:a 128k lua/badapple/badapple.m4a
```

If the audio starts earlier than the animation, adjust:

```lua
require("badapple").setup({
  audio_offset = 3000,
})
```

If you do not want audio playback at all:

```lua
require("badapple").setup({
  audio_enabled = false,
})
```

## Development

Clone locally:

```bash
git clone https://github.com/VKKKV/badapple.nvim
cd badapple.nvim
```

Run a smoke test with a clean Neovim config:

```bash
nvim --clean -u NONE \
  --cmd 'set rtp+=.' \
  +'lua require("badapple").setup()' \
  +'BadAppleStart'
```

Format Lua code with StyLua:

```bash
stylua lua plugin
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
