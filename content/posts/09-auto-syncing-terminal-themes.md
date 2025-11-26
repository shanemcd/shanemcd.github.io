---
title: Auto-switching Konsole themes with tinty and KDE light/dark mode
---

I've spent years cycling through color schemes in my terminal and text editor - installing them, using them for a few days, then switching to something else. The [Tomorrow theme](https://github.com/chriskempson/tomorrow-theme) was the first one that stuck. Its author later built [Base16](https://github.com/chriskempson/base16), a system for generating consistent color schemes across different applications. While Base16 hasn't been actively maintained in recent years, the concept stuck around.

I recently discovered [tinty](https://github.com/tinted-theming/tinty), a maintained Base16 theme manager that applies color schemes to your terminal using escape sequences. It can switch themes on the fly without restarting the terminal.

Before I could use tinty with Konsole, I needed to add support for it. The [tinted-terminal](https://github.com/tinted-theming/tinted-terminal) project generates terminal color schemes for various emulators, but Konsole was missing. I [sent a PR](https://github.com/tinted-theming/tinted-terminal/pull/28) which was quickly merged (thanks!).

With Konsole support in place, the next problem was making it automatic. KDE Plasma 6.5 [recently added](https://blogs.kde.org/2025/08/02/this-week-in-plasma-day/night-theme-switching/) automatic light/dark mode switching based on time of day, but terminal color schemes don't follow along. You can manually switch them, but that defeats the purpose.

## Building the plugin

I wanted a zsh plugin that would:
1. Detect when the desktop switches between light/dark mode
2. Apply the appropriate tinty theme automatically
3. Update all open terminal tabs, not just one

### Detecting theme changes

Modern desktops expose theme settings through the [XDG Desktop Portal](https://flatpak.github.io/xdg-desktop-portal/) over D-Bus. The `org.freedesktop.appearance` interface has a `color-scheme` setting that returns:
- `0` - No preference (treat as light)
- `1` - Dark
- `2` - Light

You can query it with `dbus-send`:

```bash
dbus-send --session --print-reply --dest=org.freedesktop.portal.Desktop \
  /org/freedesktop/portal/desktop \
  org.freedesktop.portal.Settings.Read \
  string:'org.freedesktop.appearance' \
  string:'color-scheme'
```

And monitor changes with `dbus-monitor`:

```bash
dbus-monitor --session \
  "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged',arg0='org.freedesktop.appearance',arg1='color-scheme'"
```

### The broadcasting problem

The first version worked for new tabs but failed when switching themes. Running `tinty apply` from a background job only updated whichever tab the job happened to be associated with. The other tabs stayed on the old theme.

I tried several approaches:
- Writing to parent process file descriptors (`/proc/$PPID/fd/1`) - permission denied
- Using a queue file and `precmd` hooks - timing issues with initial theme on new tabs
- Broadcasting to all `/dev/pts/*` devices - triggered desktop notifications from KDE daemons

### The solution: shell registration

Each shell that loads the plugin registers itself by writing its PID to `/tmp/tinty-shells/<pts-number>`:

```zsh
local my_tty=$(_tinty_get_tty)
local my_pts_num=""
[[ "$my_tty" =~ /dev/pts/([0-9]+)$ ]] && my_pts_num="${match[1]}"

if [[ -n "$my_pts_num" ]]; then
  mkdir -p /tmp/tinty-shells
  echo $$ > "/tmp/tinty-shells/$my_pts_num"
fi
```

When a theme change is detected, the plugin:
1. Acquires a lock (so only one tab does the work)
2. Runs `tinty apply` once and captures the output
3. Writes the escape sequences to each registered terminal device

```zsh
_tinty_apply_for_scheme() {
  local color_scheme=$1

  {
    flock -n 9 || exit 0  # Skip if another tab is applying

    local theme=$(_tinty_theme_for_scheme "$color_scheme")
    local tinty_output=$($TINTY_BIN apply "$theme" 2>/dev/null)

    [[ -d /tmp/tinty-shells ]] || exit 0
    for pts_file in /tmp/tinty-shells/*; do
      [[ -e "$pts_file" ]] || continue

      local pts="/dev/pts/$(basename "$pts_file")"
      local pid=$(cat "$pts_file" 2>/dev/null)

      # Verify shell is running and terminal is writable
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && [[ -w "$pts" ]]; then
        printf '%s' "$tinty_output" > "$pts" 2>/dev/null
      else
        rm -f "$pts_file"  # Clean up stale registration
      fi
    done
  } 9>/tmp/tinty-portal.lock
}
```

This way:
- `tinty apply` runs once, not once per tab
- Only registered shells (running this plugin) get updated
- Stale registrations are cleaned up automatically
- Lock prevents race conditions between multiple watchers

### ZLE-safe initialization

Running the D-Bus watcher immediately on plugin load caused issues with cursor positioning and widgets. The solution was to defer initialization until ZLE is ready:

```zsh
autoload -Uz add-zle-hook-widget

tinty_portal_zle_init() {
  [[ -n "$TINTY_PORTAL_WATCHER_RUNNING" ]] && return 0
  export TINTY_PORTAL_WATCHER_RUNNING=1

  add-zle-hook-widget -d zle-line-init tinty_portal_zle_init
  # ... start watcher
}

add-zle-hook-widget zle-line-init tinty_portal_zle_init
```

This ensures the watcher starts only after the prompt is ready and widgets are stable.

## Installation

Clone the plugin to your oh-my-zsh custom plugins directory:

```bash
git clone https://github.com/shanemcd/zsh-auto-tinty \
  ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/auto-tinty
```

Configure your light and dark themes in `~/.zshrc`:

```zsh
export ZSH_TINTY_LIGHT="base16-ia-light"
export ZSH_TINTY_DARK="base16-ia-dark"
plugins+=(auto-tinty)
```

Reload your shell:

```bash
exec zsh
```

## How it works

When you open a new terminal tab:
1. Plugin loads and registers the shell in `/tmp/tinty-shells/`
2. Queries current theme via D-Bus
3. Applies the appropriate tinty theme directly to that terminal
4. Starts a `dbus-monitor` background job (once per shell)
5. On shell exit, cleans up registration and kills the watcher

When the desktop theme changes:
1. One of the D-Bus watchers detects the signal
2. Waits 200ms for signals to settle (debouncing)
3. Acquires lock in `/tmp/tinty-portal.lock`
4. Runs `tinty apply` once
5. Broadcasts escape sequences to all registered terminals
6. Releases lock

All open terminal tabs switch themes simultaneously.

## Results

Now when my desktop switches to light mode in the morning, all my terminal tabs follow along. When it switches back to dark mode in the evening, same thing.

No manual theme switching, no forgetting to update that one terminal tab you opened three days ago.

The plugin is at [github.com/shanemcd/zsh-auto-tinty](https://github.com/shanemcd/zsh-auto-tinty). It should work with any terminal that supports tinty's escape sequences and any desktop that implements the XDG Desktop Portal. If you run into problems or have improvements, please open an issue or send a PR.
