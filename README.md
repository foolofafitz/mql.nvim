# mql.nvim

A lightweight, seamless solution for compiling MQL5 (`.mq5` / `.mqh`) files in Neovim on Linux using Wine, while mapping compilation errors directly back to your local repo's Quickfix list.

## Why is this plugin necessary? (The Wine Struggle)

Running MetaEditor under Wine to build MQL5 scripts introduces several massive headaches that normally break stock build systems or standard Neovim compilers:

1. **The Space Curse:** MetaEditor's CLI switch parser has a legendary bug when run inside Wine—if there are *any* spaces in your file paths, folder names, or inside your `#include` statement paths, compilation silently drops parameters or fails completely.
2. **Log File Encoding:** MetaEditor writes its compilation logs in `UTF-16LE` (with standard Windows `\r\n` carriage returns). Reading this natively in Linux results in garbage characters.
3. **Path Resolution Matrix:** The errors returned by MetaEditor point to Windows paths inside Wine (e.g., `Z:\tmp\mql_build.XXXXXX\Strategy.mqh`). Neovim has no native context to understand what file that actually corresponds to on your Linux system.

### How `mql.nvim` fixes it:
* **Primes a Sandbox:** It copies your active project files into a space-stripped temporary directory `/tmp/mql_build.XXXXXX` and utilizes a RegEx engine (`sed`) to temporarily yank spaces out of local quote-enclosed `#include` statements.
* **Pure Lua Pathing:** It bypasses slow `winepath` system forks by utilizing pure Lua path translation mechanics to construct native `Z:\` parameters.
* **Error De-serialization:** It automatically processes the compilation log through `iconv`, normalizes line endings, parses errors, maps the sandboxed file paths *back* to their original human-readable Linux project equivalents, and populates your Quickfix window.

---

## Requirements

To use this plugin, your Linux system must have the following dependencies installed:
* **Wine** (To execute `metaeditor64.exe`)
* **iconv** (Standard Linux utility used to transcode the UTF-16LE compiler logs to UTF-8)
* **sed** (Used to strip spaces dynamically inside sandbox includes)

---

## Installation & Configuration

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
return {
    "yourusername/mql.nvim",
    ft = { "mq5", "mqh" }, -- Lazy load only on MQL filetypes
    opts = {
        -- REQUIRED: Absolute path to your Wine MetaEditor executable
        metaeditor_path = "~/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe",

        -- REQUIRED: Absolute path to your default MQL5 standard components/include library folder
        mql5_include_path = "~/.wine/drive_c/Program Files/MetaTrader 5/MQL5",

        -- OPTIONAL: Default mapping to trigger compilation (set to `false` to disable)
        bind_key = "<F7>",
    }
}
```

---

## Usage

-    Open any .mq5 file.
-    Press <kbd>F7</kbd> (or your custom bound key) to compile.
-    If compilation succeeds, an .ex5 binary will be placed side-by-side with your code.
-    If compilation fails, the Quickfix window will automatically pop open.
-    Pressing l or <CR> inside the Quickfix window will jump directly to the line containing the error.
