A small shell for a Tait TM8100/TM8200 mobile over its CCDI serial port: run it against a port for an interactive prompt, or give it one command and it prints the answer and exits.

Each binary is **self-contained** (the .NET runtime and the native serial library are embedded) and **single-file** - no .NET install needed. Download the one for your platform and run.

**Debian / Ubuntu / Raspberry Pi OS** - install it from the packet-net apt repository instead, and `apt upgrade` keeps it current:
```
curl -fsSL https://packet-net.github.io/apt/pubkey.asc | sudo gpg --dearmor -o /usr/share/keyrings/packet-net.gpg
echo "deb [signed-by=/usr/share/keyrings/packet-net.gpg] https://packet-net.github.io/apt ./" | sudo tee /etc/apt/sources.list.d/packet-net.list
sudo apt update && sudo apt install tait-cli
```
The `.deb` assets below are the same build, for installing by hand: `sudo apt install ./tait-cli___VER___amd64.deb`.

**Linux / macOS**
```
curl -LO https://github.com/__REPO__/releases/download/v__VER__/tait-cli-__VER__-linux-x64   # or linux-arm64 / linux-arm / osx-x64 / osx-arm64
chmod +x tait-cli-__VER__-*
./tait-cli-__VER__-linux-x64 --help
```

**Windows**: download `tait-cli-__VER__-win-x64.exe` and run it.

Assets: `linux-x64`, `linux-arm64`, `linux-arm` (armv7 / 32-bit Pi), `win-x64`, `osx-x64` (Intel), `osx-arm64` (Apple Silicon), plus `.deb` packages for `amd64`, `arm64` and `armhf`. `SHA256SUMS` covers every asset - verify with `sha256sum -c SHA256SUMS` (or `shasum -a 256 -c` on macOS).

Usage:
```
tait-cli /dev/ttyUSB0                  # interactive shell
tait-cli /dev/ttyUSB0 rssi             # one command, then exit
tait-cli /dev/ttyUSB0 --baud 19200 info
```

Commands: `info`, `version`, `channel`, `freq`, `rssi`, `watch [s]`, `display`, `temp`, `help`, `quit`. The baud rate defaults to 28800 and must match what the radio's data port is programmed for; a factory-fresh codeplug is at 19200. If the radio does not answer, check the cable, then check that the data port is in Command mode at the right rate with flow control off and pointed at the socket the cable is in. [`tait-codeplug`](https://github.com/M0LTE/tait-codeplug) sets all of that without the Windows programming software.
