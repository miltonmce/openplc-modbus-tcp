# AGENTS.md

## What this is

An OpenPLC Editor project (`"type": "plc-project"`), not an application codebase. The repo contains the IEC 61131-3 sources, docs and a pymodbus test client; there is no test/lint suite beyond the compile step. Logic lives in POUs; build/verify through the OpenPLC CLI described below.

## Layout

- `project.json` — project metadata plus runtime wiring: tasks, program instances, global variables.
- `pous/programs/main.st` — the only POU: pump control, simulated flow, fault handling, volume totalizer. `pous/functions/` and `pous/function-blocks/` are empty and hold future POUs.
- `devices/configuration.json` — target board (`OpenPLC Runtime v4`), persistent storage, target device ids.
- `devices/servers/modbus-tcp.json` — Modbus TCP server (port 5020, classic v3 buffer layout). Read by the `OpenPLC Runtime v4` target only.
- `devices/pin-mapping.json` — hardware pin map (currently empty `{}`).
- `MODBUS.md` — address map plus runtime/compile/upload instructions. `tools/modbus_check.py` — pymodbus client and acceptance sequence (`--demo`).

## Runtime wiring

- `task0` runs cyclically every `T#20ms` at priority 1; `instance0` maps program `main` to `task0`.
- A POU executes only if it is listed in `data.configuration.resource.instances` and bound to a task. Adding a file under `pous/` alone does nothing.
- Program name must stay consistent across three places: the `PROGRAM` line in the `.st` file, the filename, and `instances[].program`.
- `main.st` hard-codes `Cycle_Time_s := 0.02` for the volume integral. If `task0.interval` changes, update that constant or the totalized volume will be wrong.

## Simulation model (`main.st`)

- `Start_Button` latches on a rising edge; `Stop_Button` is level-sensitive. Stop, `Emergency_Stop`, and `NOT Water_Level_OK` have priority over start.
- `Flow_Rate_Lpm` ramps from 0 to `Flow_Setpoint_Lpm` (120 L/min) at `Flow_Ramp_Lpm` per scan, with deterministic ±4 % sine noise; it decays when the pump stops.
- `Volume_Liters += Flow_Rate_Lpm * (Cycle_Time_s / 60)`; hold `Reset_Volume` to zero it.
- Latched faults (`Fault_Active`/`Fault_Code`): 101 e-stop, 102 dry run, 103 no water. Clear with `Reset_Fault` only when safe and stopped.
- Use `REAL`, not `LREAL`, for floats that must be watched. On the AVR simulator `double` is 4 bytes, but the generated debug map declares `LREAL` as 8; every later variable shifts and the watch shows garbage (e.g. absurd `Flow_Rate_Lpm`, `Volume_Liters` stuck at 0, `Fault_Code` 16384). `REAL` maps to 4 bytes and decodes correctly.
- These are plain `VAR` (not `VAR_INPUT`/`VAR_OUTPUT`) because the program is driven from the HMI/debug watch.

## Modbus TCP

- The `OpenPLC Simulator` target **cannot** serve Modbus: it warns "your target does not support this feature" and drops the server config (RTU over an in-process virtual serial port, no host-visible device, no network). Modbus TCP needs the `OpenPLC Runtime v4` target.
- `main.st` keeps the logic on internal `VAR`s and adds a located image layer (`Modbus_Cmd AT %MW0`, `Modbus_Fault_Code AT %MW1`, `Modbus_Flow AT %MD0`, `Modbus_Volume AT %MD1`, `Modbus_Pump AT %QX0.0`, `Modbus_Fault AT %QX0.1`). Commands are decoded at the top of the scan and status is published at the bottom.
- Commands must arrive through coils or holding registers. `%IX`/`%IW` cannot be written by a Modbus master, and the editor rejects located `%IX` variables with "no producer".
- The command word is whole-register (FC 06), so clearing a bit means rewriting the register. `%MW0` bit 3 is inverted (1 = water low) so an all-zero word is the safe/healthy default.
- `deviceBoard` is `OpenPLC Runtime v4` because Modbus TCP is the point of the project. The editor's debug watch still works if you switch the target to `OpenPLC Simulator`; pass `--target` explicitly when compiling for the other one. Both targets compile from the same sources.
- Runtime: `ghcr.io/autonomy-logic/openplc-runtime:latest` under rootless podman with `--network host`. Port 502 is privileged, so the project uses 5020; see `MODBUS.md` to move to 502.
- Uploading while the PLC runs is refused; use `--yes` (the target builds on the device). The upload leaves the PLC started and enables the `modbus_slave` plugin.

## File formats

- `.st` POUs are plain IEC 61131-3 text: `PROGRAM name` / `VAR` / `END_VAR` / logic / `END_PROGRAM` (no trailing blank line convention required).
- `.ld` files are **not** XML. They are an IEC text wrapper plus a JSON body (`{"name": ..., "rungs": [...]}`) whose rungs are a React Flow graph (`nodes`/`edges`, `left-rail-*`/`right-rail-*`). Do not hand-author rungs; create/edit them in OpenPLC Editor, or write ST instead.
- `project.json` keeps `data.pous` and `dataTypes` empty even in freshly created projects — that is normal, not a missing registration. The `pous/` file tree is the source of truth.

## Verifying changes

Compile headlessly with the editor's CLI (the `openplc-cli` on `PATH` may be a
stale wrapper pointing at a missing AppImage):

```sh
openplc-editor.AppImage --ozone-platform=headless --disable-gpu --cli compile . --json
```

- Exit `0` = success, `4` = compile failure; JSON output also reports `ok`/`warnings`.
- The CLI refreshes the repo-local `build/` directory on every compile; it is gitignored and can be deleted safely. Intermediate sources also live in `~/.config/open-plc-editor/cloud-builds/*/build/`; inspect `src/pou_MAIN.cpp` and `src/debug-map.json` there.
- `debug-map.json` must have sizes matching the target: AVR `BOOL=1`, `REAL=4`, `INT=2`, `DINT=4`, `TIME=8`. A `LREAL` entry with size 8 is wrong on this target.
- To probe format changes without touching this project, `--cli create <name> --path /tmp/opencode --language st|ld` generates a scratch project.
- No simulator or runtime harness is available; the compile step is the only automated check.
