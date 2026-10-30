# Emulador de bombeo con OpenPLC y Modbus TCP

Estación de bombeo simulada en **Structured Text** (IEC 61131-3) sobre
OpenPLC Editor v4, expuesta a un cliente externo por **Modbus TCP**. Sirve como
banco de pruebas para HMI/SCADA o para scripts de integración escritos con
pymodbus, sin necesidad de hardware.

El proceso no es un *stub*: el PLC ejecuta la lógica de control real (enclavamientos,
fallos, rampa de caudal y totalizador de volumen) y un cliente Modbus puede
comandarlo y leer su estado en tiempo real.

## Qué hace el programa

- **Marcha/paro con enclavamiento**: arranque por flanco de subida, paro por nivel.
- **Prioridades de seguridad**: emergencia y falta de agua paran la bomba y
  enclavan un fallo, aunque haya orden de marcha.
- **Códigos de fallo** persistentes: `101` emergencia, `102` marcha en seco,
  `103` sin agua. Se rearman solo si la condición es segura y la bomba está parada.
- **Simulación del caudal**: rampa de 2 L/min por ciclo hasta el punto de consigna
  (120 L/min) con ruido senoidal determinista de ±4 %, y decaimiento inercial al parar.
- **Marcha en seco**: si el caudal no llega a 5 L/min tras 3 s de marcha, se
  dispara el fallo 102 a los 5 s.
- **Totalizador de volumen**: integra el caudal en cada scan (20 ms).

## Arquitectura

```
        Modbus TCP (:5020)                    OpenPLC Runtime v4
  ┌────────────────────────┐          ┌──────────────────────────────┐
  │ HMI / SCADA / pymodbus │ ───────► │  %MW0  palabra de mando      │
  │                        │          │  %MD0  caudal      (REAL)    │
  │                        │ ◄─────── │  %MD1  volumen     (REAL)    │
  └────────────────────────┘          │  %QX0.0/0.1  estado          │
                                      └──────────────┬───────────────┘
                                                     │ task0, T#20ms
                                                     ▼
                                      ┌──────────────────────────────┐
                                      │ main.st  (Structured Text)   │
                                      └──────────────────────────────┘
```

El POU se compila con STruC++ y se ejecuta en el runtime v4 dentro de un
contenedor. La imagen de proceso Modbus se declara con variables localizadas
(`AT %MW0`, `AT %MD0`, `AT %QX0.0`), de modo que el cliente ve directamente el
estado del programa.

## Arranque rápido

Requisitos: [OpenPLC Editor v4](https://github.com/Autonomy-Logic/openplc-editor),
podman o docker, Python 3.10+ y las dependencias de `requirements.txt`.

```sh
# 1. Runtime
podman pull ghcr.io/autonomy-logic/openplc-runtime:latest
podman run -d --name openplc-runtime --network host \
  --cap-add=SYS_NICE --cap-add=SYS_RESOURCE \
  -v openplc-runtime-data:/var/run/runtime \
  ghcr.io/autonomy-logic/openplc-runtime:latest

# 2. Usuario del runtime (solo la primera vez)
curl -k -X POST https://127.0.0.1:8443/api/create-user \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"TU_PASSWORD","role":"admin"}'

# 3. Compilar, subir y arrancar el PLC
openplc-editor.AppImage --ozone-platform=headless --disable-gpu \
  --cli upload . --target 'OpenPLC Runtime v4' \
  --host 127.0.0.1 --credentials admin:TU_PASSWORD --yes --json

# 4. Probar
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
python3 tools/modbus_check.py --demo
```

Salida esperada de `--demo`:

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

## Compilar sin runtime

El proyecto también se puede verificar sin contenedor ni PLC; el CLI compila
para el target seleccionado y devuelve `ok: true`:

```sh
openplc-editor.AppImage --ozone-platform=headless --disable-gpu \
  --cli compile . --json
```

Los artefactos se generan en `build/` (ignorado por git). Para el simulador AVR
hay que pasar `--target 'OpenPLC Simulator'`.

## Mapa Modbus

Slave id `1`. Segmentación clásica, compatible con OpenPLC v3.

| Área | FC | Dirección | Variable | Tipo |
|---|---|---|---|---|
| Coils | 01 / 05 | 0 | bomba en marcha | BOOL |
| Coils | 01 / 05 | 1 | fallo activo | BOOL |
| Holding | 03 / 06 | 1024 | palabra de mando | INT |
| Holding | 03 | 1025 | código de fallo | INT |
| Holding | 03 | 2048–2049 | caudal | REAL |
| Holding | 03 | 2050–2051 | volumen total | REAL |

Bits de la palabra de mando: `b0` marcha, `b1` paro, `b2` emergencia,
`b3` sin agua (negado), `b4` rearme, `b5` reset de volumen.

Tabla completa, notas de decodificación y diagnóstico en **[MODBUS.md](MODBUS.md)**.

## Estructura

```
pous/programs/main.st          lógica del proceso (Structured Text)
devices/servers/modbus-tcp.json servidor Modbus TCP y segmentación de buffers
tools/modbus_check.py          cliente pymodbus + secuencia de aceptación
requirements.txt               dependencias del cliente de pruebas
MODBUS.md                      mapa de direcciones y puesta en marcha
AGENTS.md                      notas de mantenimiento y trampas del toolchain
project.json                   tarea cíclica (T#20ms) e instancias del programa
```

## Decisiones de diseño

- **`REAL`, no `LREAL`**: en el target AVR del simulador, `double` ocupa 4 bytes
  pero el mapa de debug lo declara como 8, lo que desplaza todas las variables
  posteriores y muestra basura en el watch.
- **Comandos por `%MW`, no por `%IX`**: un maestro Modbus no puede escribir
  entradas discretas, y el editor rechaza variables `%IX` sin un productor.
- **Puerto 5020 en lugar de 502**: 502 es privilegiado y podman sin root no
  puede enlazarlo. `MODBUS.md` explica cómo moverlo al puerto estándar.
- **El target `OpenPLC Simulator` no sirve para esto**: descarta la configuración
  de servidor Modbus y solo habla RTU sobre un puerto serie virtual en proceso.
  Por eso `deviceBoard` apunta a `OpenPLC Runtime v4`; el target `OpenPLC
  Simulator` sigue disponible para el watch del editor y ambos compilan desde
  las mismas fuentes.

## Licencia

MIT — ver [LICENSE](LICENSE).
