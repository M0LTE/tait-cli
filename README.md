# tait-cli

A small shell for a Tait TM8100/TM8200 mobile radio over its CCDI serial port, built on the [M0LTE.Radio.Tait](https://www.nuget.org/packages/M0LTE.Radio.Tait) package.

## Run

```sh
dotnet run -- /dev/ttyUSB0             # interactive shell
dotnet run -- /dev/ttyUSB0 rssi        # one command, then exit
dotnet run -- /dev/ttyUSB0 --baud 19200 info
```

The baud rate defaults to 28800 and must match what the radio's data port is programmed for. If the radio does not answer, check the cable, then in the Tait programming software set:

- Data -> General -> Powerup State: Command Mode
- Data -> Serial Communications -> Baud Rate: 28800 (or pass `--baud` to match whatever the radio is set to; a factory-fresh codeplug is at 19200)
- Data -> Serial Communications -> Flow Control: None
- Data -> Serial Communications -> Data Port: Mic, Aux or Internal Options, whichever socket the cable is plugged into

After an attempt at the wrong baud rate, the radio's command buffer holds junk with no terminator and it rejects the next good command with a checksum error. The tool retries once and says so when that happens.

## Commands

| Command     | What it does |
|-------------|--------------|
| `info`      | model, serial number, firmware and band |
| `version`   | firmware version |
| `channel`   | current channel number |
| `freq`      | current channel and band split |
| `rssi`      | signal level now, in dBm and S-points |
| `watch [s]` | keep reading the signal level every `s` seconds (default 0.5) until Ctrl-C |
| `display`   | text currently on the control head (a radio without a display head says so) |
| `temp`      | power amplifier temperature |
| `help`      | list the commands |
| `quit`      | leave the shell |

## Frequency

CCDI does not expose the tuned frequency, only the channel number and the radio's band split. `freq` reports those two things; `display` shows whatever the control head is showing, which is the channel name or frequency depending on how the radio is programmed.

## Exit codes

0 ok, 1 usage error, 2 could not open the port, 3 the radio did not answer or rejected the command, 130 stopped with Ctrl-C.
