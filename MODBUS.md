# Modbus TCP — mapa de direcciones y puesta en marcha

El proyecto se publica como esclavo Modbus TCP mediante **OpenPLC Runtime v4**.
El target `OpenPLC Simulator` **no** puede: el editor descarta la configuración
de servidor Modbus al compilar para él (RTU en proceso, sin red).

- Host/puerto del servidor: `0.0.0.0:5020` (`devices/servers/modbus-tcp.json`)
- Unit / slave id: `1`
- Segmentación: clásica (compatible v3), `word_order = high_word_first`

## Mapa

### Coils — FC 01 (leer) / FC 05 (escribir)

| Dirección | Variable IEC | Tipo | Descripción |
|---|---|---|---|
| 0 | `%QX0.0` · `Modbus_Pump` | BOOL | Bomba en marcha |
| 1 | `%QX0.1` · `Modbus_Fault` | BOOL | Fallo enclavado activo |

### Holding registers — FC 03 (leer) / FC 06 (escribir)

| Rango | Variable IEC | Tipo | Descripción |
|---|---|---|---|
| 0–1023 | `%QW0`–`%QW1023` | INT | Palabras de salida (sin uso) |
| **1024** | `%MW0` · `Modbus_Cmd` | INT | **Palabra de mando (escritura)** |
| **1025** | `%MW1` · `Modbus_Fault_Code` | INT | **Código de fallo** |
| 1026–2047 | `%MW2`–`%MW1023` | INT | Libres |
| **2048–2049** | `%MD0` · `Modbus_Flow` | REAL | **Caudal [L/min]** (float32) |
| **2050–2051** | `%MD1` · `Modbus_Volume` | REAL | **Volumen total [L]** (float32) |
| 2052–4095 | `%MD2`–`%MD1023` | DINT | Libres |

### Discrete inputs / input registers
FC 02 y FC 04 existen pero están vacíos: `%IX`/`%IW` no tienen productor en un
esclavo Modbus (el maestro no puede escribir entradas discretas).

## Bits de `%MW0` (registro 1024)

| Bit | Máscara | Señal | Nota |
|---|---|---|---|
| b0 | `0x01` | `Start_Button` | Flanco de subida (enclava marcha) |
| b1 | `0x02` | `Stop_Button` | Nivel: a 1 detiene |
| b2 | `0x04` | `Emergency_Stop` | Nivel: a 1 enclava fallo 101 |
| b3 | `0x08` | **Sin agua** (negado) | 1 = falta de agua → fallo 103. 0 = nivel correcto |
| b4 | `0x10` | `Reset_Fault` | Rearma si no hay emergencia, hay agua y la bomba está parada |
| b5 | `0x20` | `Reset_Volume` | Pone el totalizador a cero |

El registro se escribe completo (FC 06), así que cada escritura sustituye el
estado anterior: para "soltar" un pulsador hay que reescribir con el bit a 0.

Ejemplo: arrancar = escribir `0b00000001` (1). Parar = escribir `2`.

## Cliente de pruebas

```sh
python3 tools/modbus_check.py                    # foto del estado
python3 tools/modbus_check.py --start            # da la orden de marcha
python3 tools/modbus_check.py --stop
python3 tools/modbus_check.py --water-low        # simula falta de agua
python3 tools/modbus_check.py --reset-fault
python3 tools/modbus_check.py --reset-volume
python3 tools/modbus_check.py --demo             # secuencia completa de aceptación
```

Decodificación de los REAL:

```python
import struct
regs = client.read_holding_registers(2048, count=2).registers
flow = struct.unpack('>f', struct.pack('>HH', regs[0], regs[1]))[0]
```

## Puesta en marcha

### 1. Runtime

```sh
podman run -d --name openplc-runtime --network host \
  --cap-add=SYS_NICE --cap-add=SYS_RESOURCE \
  -v openplc-runtime-data:/var/run/runtime \
  ghcr.io/autonomy-logic/openplc-runtime:latest
```

La primera vez hay que crear el usuario del runtime (solo se permite sin
autenticación mientras no exista ninguno):

```sh
curl -k -X POST https://127.0.0.1:8443/api/create-user \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"TU_PASSWORD","role":"admin"}'
```

### 2. Compilar y subir

```sh
openplc-editor.AppImage \
  --ozone-platform=headless --disable-gpu \
  --cli upload . --target 'OpenPLC Runtime v4' \
  --host 127.0.0.1 --credentials admin:TU_PASSWORD --yes --json
```

`--yes` es necesario si el PLC está corriendo: el target compila en el propio
runtime y hay que pararlo antes. El upload deja el PLC arrancado.

### 3. Puerto 502

El servidor usa **5020** porque 502 es privilegiado y podman sin root no puede
enlazarlo. Para usar el puerto estándar:

```sh
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=502
```

y cambiar `"port": 5020` → `502` en `devices/servers/modbus-tcp.json`, recompilar
y volver a subir. Para que el cambio sea permanente:
`echo 'net.ipv4.ip_unprivileged_port_start=502' | sudo tee /etc/sysctl.d/99-openplc.conf`.

## Diagnóstico

```sh
podman logs openplc-runtime 2>&1 | grep MODBUS_SLAVE | tail -20
```

Líneas que confirman el mapeo:

```
[MODBUS_SLAVE] Segmented coils: %QX=8192 bits, %MX=0 bits, total=8192
[MODBUS_SLAVE] Segmented holding registers: %QW=0-1023, %MW=1024-2047, %MD=2048-4095, %ML=4096-4095, word_order=high_word_first
[MODBUS_SLAVE] Plugin initialized successfully - Host: 0.0.0.0, Port: 5020
```

Si aparece `permission denied` al enlazar, es el problema de puerto privilegiado.
Si el PLC no carga: `No libplc_*.so file found in ./build` significa que el
upload no llegó a compilar el programa.
