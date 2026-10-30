#!/usr/bin/env python3
"""Cliente de pruebas Modbus TCP para el emulador de bomba.

Lee la imagen Modbus que publica OpenPLC Runtime v4 y permite comandar el
programa. Ver MODBUS.md para el mapa de direcciones completo.

    python3 tools/modbus_check.py --demo
"""

from __future__ import annotations

import argparse
import struct
import sys
import time

from pymodbus.client import ModbusTcpClient

# ---- Mapa de direcciones (ver MODBUS.md) ----------------------------------
COIL_PUMP = 0
COIL_FAULT = 1

REG_CMD = 1024          # %MW0
REG_FAULT_CODE = 1025   # %MW1
REG_FLOW = 2048         # %MD0 (2 registros)
REG_VOLUME = 2050       # %MD1 (2 registros)

CMD_START = 0x01
CMD_STOP = 0x02
CMD_ESTOP = 0x04
CMD_WATER_LOW = 0x08    # negado: 1 = sin agua
CMD_RESET_FAULT = 0x10
CMD_RESET_VOLUME = 0x20

FAULTS = {0: "sin fallo", 101: "emergencia", 102: "marcha en seco", 103: "sin agua"}


def to_float(regs: list[int]) -> float:
    """Dos registros Modbus (word alto primero) -> float32."""
    return struct.unpack(">f", struct.pack(">HH", regs[0], regs[1]))[0]


class Pump:
    def __init__(self, host: str, port: int, unit: int) -> None:
        self.client = ModbusTcpClient(host, port=port)
        self.unit = unit
        if not self.client.connect():
            raise SystemExit(f"No se pudo conectar a {host}:{port}")

    def close(self) -> None:
        self.client.close()

    # -- lecturas ----------------------------------------------------------
    def status(self) -> dict:
        coils = self.client.read_coils(COIL_PUMP, count=2, device_id=self.unit).bits[:2]
        flow = to_float(
            self.client.read_holding_registers(REG_FLOW, count=2, device_id=self.unit).registers
        )
        volume = to_float(
            self.client.read_holding_registers(REG_VOLUME, count=2, device_id=self.unit).registers
        )
        code = self.client.read_holding_registers(
            REG_FAULT_CODE, count=1, device_id=self.unit
        ).registers[0]
        return {
            "pump": bool(coils[0]),
            "fault": bool(coils[1]),
            "flow": flow,
            "volume": volume,
            "code": code,
        }

    def command_word(self) -> int:
        return self.client.read_holding_registers(REG_CMD, count=1, device_id=self.unit).registers[0]

    # -- escrituras --------------------------------------------------------
    def write_cmd(self, value: int) -> None:
        self.client.write_register(REG_CMD, value, device_id=self.unit)

    def pulse(self, bit: int, hold: float = 0.3) -> None:
        """Activa un bit de mando, espera un flanco de scan y lo suelta."""
        self.write_cmd(bit)
        time.sleep(hold)
        self.write_cmd(0)

    def start(self) -> None:
        self.pulse(CMD_START)

    def stop(self) -> None:
        # el paro es por nivel; se deja el bit y luego se limpia
        self.write_cmd(CMD_STOP)
        time.sleep(0.3)
        self.write_cmd(0)

    def water_low(self, low: bool = True) -> None:
        current = self.command_word() & ~CMD_WATER_LOW
        self.write_cmd(current | (CMD_WATER_LOW if low else 0))

    def reset_fault(self) -> None:
        self.pulse(CMD_RESET_FAULT)

    def reset_volume(self) -> None:
        self.pulse(CMD_RESET_VOLUME)


def show(label: str, st: dict, extra: str = "") -> None:
    code = st["code"]
    desc = FAULTS.get(code, f"desconocido ({code})")
    print(
        f"{label:<14} bomba={'ON ' if st['pump'] else 'OFF'}  "
        f"caudal={st['flow']:8.2f} L/min  "
        f"volumen={st['volume']:9.2f} L  "
        f"fallo={'sí' if st['fault'] else 'no '} [{code}: {desc}]{extra}"
    )


def demo(pump: Pump) -> int:
    print("--- secuencia de aceptación ---")
    show("reposo", pump.status())

    pump.start()
    time.sleep(0.5)
    s = pump.status()
    show("marcha 0.5s", s)
    if not s["pump"]:
        print("FALLO: la bomba no arrancó")
        return 1

    time.sleep(3.0)
    show("marcha 3.5s", pump.status())

    a = pump.status()
    time.sleep(2.0)
    b = pump.status()
    rate = (b["volume"] - a["volume"]) / 2.0
    show("tras 2s", b, f"  Δvol={b['volume'] - a['volume']:.2f} L → {rate:.2f} L/s")
    if not 1.5 <= rate <= 2.5:
        print("FALLO: el caudal totalizado no ronda los 2 L/s")
        return 1

    pump.stop()
    time.sleep(1.5)
    show("paro", pump.status())

    pump.write_cmd(CMD_START)
    time.sleep(1.5)
    pump.write_cmd(CMD_WATER_LOW)          # fallo 103 con la bomba en marcha
    time.sleep(0.5)
    s = pump.status()
    show("sin agua", s)
    if s["code"] != 103 or not s["fault"]:
        print("FALLO: no se enclavó el fallo 103")
        return 1

    pump.write_cmd(CMD_RESET_FAULT)        # limpia b3 y rearma
    time.sleep(0.5)
    s = pump.status()
    show("rearme", s)
    if s["fault"] or s["code"] != 0:
        print("FALLO: no rearmó")
        return 1

    pump.write_cmd(CMD_RESET_VOLUME)
    time.sleep(0.5)
    s = pump.status()
    show("reset vol.", s)
    if abs(s["volume"]) > 0.1:
        print("FALLO: el volumen no volvió a cero")
        return 1

    pump.write_cmd(0)
    show("final", pump.status())
    print("\nOK: todas las comprobaciones pasaron")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Cliente Modbus TCP del emulador de bomba")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5020)
    ap.add_argument("--unit", type=int, default=1, help="slave / device id")
    ap.add_argument("--watch", type=float, metavar="SEG", help="muestreo continuo")
    ap.add_argument("--start", action="store_true")
    ap.add_argument("--stop", action="store_true")
    ap.add_argument("--water-low", action="store_true")
    ap.add_argument("--water-ok", action="store_true")
    ap.add_argument("--reset-fault", action="store_true")
    ap.add_argument("--reset-volume", action="store_true")
    ap.add_argument("--demo", action="store_true")
    args = ap.parse_args()

    pump = Pump(args.host, args.port, args.unit)
    try:
        if args.demo:
            return demo(pump)

        if args.stop:
            pump.stop()
        if args.start:
            pump.start()
        if args.water_low:
            pump.water_low(True)
        if args.water_ok:
            pump.water_low(False)
        if args.reset_fault:
            pump.reset_fault()
        if args.reset_volume:
            pump.reset_volume()

        if args.watch:
            while True:
                show(time.strftime("%H:%M:%S"), pump.status())
                time.sleep(args.watch)
        else:
            show("estado", pump.status())
    except KeyboardInterrupt:
        pass
    finally:
        pump.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
