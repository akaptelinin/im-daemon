# im-daemon

A lightweight macOS daemon for keyboard layout detection with push notifications via Unix socket.

## Features

- **Fast** — ~1ms latency vs ~22ms for fork/exec alternatives like `im-select`
- **Push model** — subscribe once, get notified on every layout change
- **Simple protocol** — text-based commands over Unix socket

## Commands

```bash
# Get current layout
echo "get" | nc -U ~/.local/run/im-daemon.sock
# → com.apple.keylayout.Russian

# Set layout
echo "set com.apple.keylayout.US" | nc -U ~/.local/run/im-daemon.sock
# → ok

# Subscribe to changes (keeps connection open)
echo "subscribe" | nc -U ~/.local/run/im-daemon.sock
# → com.apple.keylayout.US
# → com.apple.keylayout.Russian  (when you switch)
# → ...
```

## Build

```bash
swiftc -O -o im-daemon main.swift -framework Carbon
```

## Install as LaunchAgent

```bash
mkdir -p ~/.local/run

cat > ~/Library/LaunchAgents/com.local.im-daemon.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.im-daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/im-daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.local.im-daemon.plist
```

## Use with Neovim

See [keyboard-layout.lua](https://github.com/akaptelinin/nvim-config/blob/master/lua/plugins/keyboard-layout.lua) for a lualine integration example using subscribe.

## License

MIT
