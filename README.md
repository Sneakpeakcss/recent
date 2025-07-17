# recent.lua
#### Recently played menu
Logs played files to a history log file with an interactive 'recently played' menu that reads from the log. Allows for automatic or manual logging if you want a file bookmark menu instead.


![](../assets/recent.png)
### Menu controls:
* Default display hotkey is **`` TAB ``**
* Keyboard:
    * `UP`/`DOWN` to move selection
    * `PGUP` / `PGDWN` to move by 10
    * `HOME` / `END` to jump to start/end
    * `ENTER` to load highlighted entry
    * `DEL` to delete highlighted entry
    * `SHIFT+ENTER` to add to playlist
    * `CTRL+SHIFT+F` to activate search
    * `0`-`9` for quick selection
    * `ESC` to exit
    * `BACKSPACE` to exit or exit search results
    * Holding the display key (long-press) toggles between default and uosc menu
* Mouse (if turned on):
    * `WHEEL_UP`/`WHEEL_DOWN` to move selection
    * `MBTN_MID` to load highlighted entry
    * `MBTN_RIGHT` to exit or exit search results
    * `SHIFT+MBTN_MID` to add to playlist
    * Click and drag to scroll playlist

#### Modify settings through `script-opts/recent.conf`
* Log path is `history.log` inside whatever config directory mpv reads
* Disabling `auto_save` makes it only save with a keybind
    * No save key is bound by default, see `script-opts`
* See comments in the script for more info

#### Custom prefix/highlight support
* Define match rules using the `custom_colors` option in the following format:  
  `pattern|prefix|prefixColor|highlightColor`
* Disable prefix or highlight color with `""`
* Patterns match against the file’s full path or URL.
* Example:
  - `{audio}|♫|1DB954|""`
  - `^https?://youtu.be/| ↪Youtube ▶|FF0000|""`
  - `http.?://www.twitch.tv/(.*)videos?| ↪VoD ▶|00ADEE|57C7FF`
* `{audio}` expands to all audio extensions from `audio-exts` property

#### Search
* `CTRL+SHIFT+F`
* Supports:
    * Inclusion terms: `word`
    * Exclusion terms: `-word`
    * Exact phrases: `"word1 word2"`
* Example:  
  `word1 -word2 "word3 word4" -"word5" -"word6 word7" "word8"`  
  Excludes: `word2`, `word5`, `word6 word7`  
  Includes: `word1`, `word3 word4`, `word8`

#### Play most recent one.

```ini
KEY                 script-binding recent/play-last
```

### uosc integration

**[tomasklaen/uosc](https://github.com/tomasklaen/uosc) is required.**

[Menu](https://github.com/tomasklaen/uosc#adding-items-to-menu) - add following to `input.conf`.

```ini
KEY                 script-binding recent/display-recent          #! Recently played
```

[Controls](https://github.com/tomasklaen/uosc#set-prop-value) - add following to `uosc.conf#controls`.

```ini
command:history:script-message-to recent display-recent?Recently played
```

### mpv-menu-plugin integration

**[mpv-menu-plugin](https://github.com/tsl0922/mpv-menu-plugin) is required.**

[Menu](https://github.com/tsl0922/mpv-menu-plugin?tab=readme-ov-file#messages) - add following to `input.conf`.

```ini
KEY                 script-binding recent/display-recent        #! Recently played  #@recent
```

