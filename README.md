# Pumping emulator with OpenPLC and Modbus TCP

Simulated pumping station written in **Structured Text** (IEC 61131-3) on
OpenPLC Editor v4, exposed to an external client over **Modbus TCP**. It works
as a test bench for HMI/SCADA systems or for integration scripts written with
pymodbus, with no hardware required.

The process is not a *stub*: the PLC runs the real control logic (interlocks,
faults, flow ramp and volume totalizer) and a Modbus client can command it and
read its state in real time.

> 🇪🇸 [Versión en español](README.es.md)

## What the program does

- **Start/stop with latching**: rising-edge start, level-sensitive stop.
- **Safety priorities**: emergency stop and lack of water stop the pump and
  latch a fault, even when a start command is present.
- **Persistent fault codes**: `101` emergency, `102` dry run,
  `103` no water. They can only be reset when the condition is safe and the
  pump is stopped.
- **Flow simulation**: ramp of 2 L/min per scan up to the setpoint
  (120 L/min) with deterministic ±4 % sine noise, and inertial decay on stop.
- **Dry run**: if the flow does not reach 5 L/min after 3 s of running,
  fault 102 is triggered at 5 s.
- **Volume totalizer**: integrates the flow on every scan (20 ms).

## Architecture

```
        Modbus TCP (:5020)                    OpenPLC Runtime v4
  ┌────────────────────────┐          ┌──────────────────────────────┐
  │ HMI / SCADA / pymodbus │ ───────► │  %MW0  command word          │
  │                        │          │  %MD0  flow        (REAL)    │
  │                        │ ◄─────── │  %MD1  volume      (REAL)    │
  └────────────────────────┘          │  %QX0.0/0.1  status          │
                                      └──────────────┬───────────────┘
                                                     │ task0, T#20ms
                                                     ▼
                                      ┌──────────────────────────────┐
                                      │ main.st  (Structured Text)   │
                                      └──────────────────────────────┘
```

The POU is compiled with STruC++ and runs in the v4 runtime inside a
container. The Modbus process image is declared with located variables
(`AT %MW0`, `AT %MD0`, `AT %QX0.0`), so the client sees the program state
directly.

## Quick start

Requirements: [OpenPLC Editor v4](https://github.com/Autonomy-Logic/openplc-editor),
podman or docker, Python 3.10+ and the dependencies in `requirements.txt`.

```sh
# 1. Runtime
podman pull ghcr.io/autonomy-logic/openplc-runtime:latest
podman run -d --name openplc-runtime --network host \
  --cap-add=SYS_NICE --cap-add=SYS_RESOURCE \
  -v openplc-runtime-data:/var/run/runtime \
  ghcr.io/autonomy-logic/openplc-runtime:latest

# 2. Runtime user (first time only)
curl -k -X POST https://127.0.0.1:8443/api/create-user \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"YOUR_PASSWORD","role":"admin"}'

# 3. Compile, upload and start the PLC
openplc-editor.AppImage --ozone-platform=headless --disable-gpu \
  --cli upload . --target 'OpenPLC Runtime v4' \
  --host 127.0.0.1 --credentials admin:YOUR_PASSWORD --yes --json

# 4. Test
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
python3 tools/modbus_check.py --demo
```

Expected `--demo` output:

```
reposo         bomba=OFF  caudal=    0.00 L/min  volumen=     0.00 L  fallo=no
marcha 0.5s    bomba=ON   caudal=   80.00 L/min  volumen=     0.55 L  fallo=no
marcha 3.5s    bomba=ON   caudal=  121.94 L/min  volumen=     6.42 L  fallo=no
tras 2s        bomba=ON   caudal=  124.31 L/min  Δvol=4.00 L → 2.00 L/s
sin agua       bomba=OFF  fallo=sí [103: sin agua]
rearme         fallo=no   [0]
reset vol.     volumen=  0.00 L
OK: todas las comprobaciones pasaron
```

## Compile without the runtime

The project can also be verified without a container or PLC; the CLI compiles
for the selected target and returns `ok: true`:

```sh
openplc-editor.AppImage --ozone-platform=headless --disable-gpu \
  --cli compile . --json
```

Artifacts are generated in `build/` (gitignored). For the AVR simulator you
must pass `--target 'OpenPLC Simulator'`.

## Modbus map

Slave id `1`. Classic segmentation, compatible with OpenPLC v3.

| Area | FC | Address | Variable | Type |
|---|---|---|---|---|
| Coils | 01 / 05 | 0 | pump running | BOOL |
| Coils | 01 / 05 | 1 | fault active | BOOL |
| Holding | 03 / 06 | 1024 | command word | INT |
| Holding | 03 | 1025 | fault code | INT |
| Holding | 03 | 2048–2049 | flow | REAL |
| Holding | 03 | 2050–2051 | total volume | REAL |

Command word bits: `b0` start, `b1` stop, `b2` emergency,
`b3` no water (inverted), `b4` fault reset, `b5` volume reset.

Full table, decoding notes and troubleshooting in **[MODBUS.md](MODBUS.md)**.

## Structure

```
pous/programs/main.st          process logic (Structured Text)
devices/servers/modbus-tcp.json Modbus TCP server and buffer segmentation
tools/modbus_check.py          pymodbus client + acceptance sequence
requirements.txt               test client dependencies
MODBUS.md                      address map and commissioning notes
AGENTS.md                      maintenance notes and toolchain pitfalls
project.json                   cyclic task (T#20ms) and program instances
```

## Design decisions

- **`REAL`, not `LREAL`**: on the simulator's AVR target, `double` is 4 bytes
  but the debug map declares it as 8, which shifts every later variable and
  shows garbage in the watch.
- **Commands via `%MW`, not `%IX`**: a Modbus master cannot write discrete
  inputs, and the editor rejects `%IX` variables without a producer.
- **Port 5020 instead of 502**: 502 is privileged and rootless podman cannot
  bind it. `MODBUS.md` explains how to move it to the standard port.
- **The `OpenPLC Simulator` target is not suitable for this**: it drops the
  Modbus server configuration and only speaks RTU over an in-process virtual
  serial port. That is why `deviceBoard` points to `OpenPLC Runtime v4`; the
  `OpenPLC Simulator` target remains available for the editor's watch and both
  compile from the same sources.

## License

MIT — see [LICENSE](LICENSE).
