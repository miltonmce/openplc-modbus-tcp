PROGRAM main
  VAR
    (* ---- Entradas (HMI / simulación) ---- *)
    Start_Button      : BOOL;              (* Pulsador de marcha (flanco) *)
    Stop_Button       : BOOL;              (* Pulsador de paro (nivel) *)
    Emergency_Stop    : BOOL;              (* TRUE = seta de emergencia activada *)
    Water_Level_OK    : BOOL := TRUE;      (* TRUE = hay agua en la aspiración *)
    Reset_Fault       : BOOL;              (* Rearma fallos si la condición es segura *)
    Reset_Volume      : BOOL;              (* Pone el totalizador a cero *)

    (* ---- Salidas / estado ---- *)
    Pump_Cmd          : BOOL;              (* Orden de marcha a la bomba *)
    Flow_Rate_Lpm     : REAL := 0.0;       (* Caudal simulado [L/min] *)
    Volume_Liters     : REAL := 0.0;       (* Volumen extraído total [L] *)
    Fault_Active      : BOOL;              (* Hay un fallo enclavado *)
    Fault_Code        : INT;               (* 101 emergencia, 102 marcha en seco, 103 sin agua *)

    (* ---- Parámetros de la simulación ---- *)
    Flow_Setpoint_Lpm : REAL := 120.0;     (* Caudal nominal de la bomba [L/min] *)
    Flow_Ramp_Lpm     : REAL := 2.0;       (* Rampa de caudal por ciclo [L/min] *)
    Cycle_Time_s      : REAL := 0.02;      (* Debe coincidir con task0 (T#20ms) *)

    (* ---- Internos ---- *)
    Start_Prev        : BOOL;
    Run_Timer         : TON;               (* Retardo antes de vigilar el caudal *)
    Dry_Run_Timer     : TON;               (* Marcha en seco *)
    Flow_Target_Lpm   : REAL;
    Noise_Factor      : REAL;
    Noise_Phase       : DINT;

    (* ---- Imagen Modbus TCP (variables localizadas) ----
       Holding: %MW0 mando, %MW1 fallo, %MD0 caudal, %MD1 volumen.
       Coils:   %QX0.0 bomba, %QX0.1 fallo.
       Ver MODBUS.md para el mapa de direcciones. ---- *)
    Modbus_Cmd        AT %MW0 : INT;
    Modbus_Fault_Code AT %MW1 : INT;
    Modbus_Flow       AT %MD0 : REAL;
    Modbus_Volume     AT %MD1 : REAL;
    Modbus_Pump       AT %QX0.0 : BOOL;
    Modbus_Fault      AT %QX0.1 : BOOL;
  END_VAR

(* ==========================================================
     1. CONTROL DE LA BOMBA
     Paro y emergencia tienen prioridad (nivel). Marcha por
     flanco de subida con enclavamiento (pulsadores momentáneos).
     ========================================================== *)
  (* ---- Entradas del cliente Modbus (%MW0, FC06 en reg 1024) ----
     b0 marcha     b1 paro        b2 emergencia
     b3 sin agua   b4 rearme     b5 reset volumen
     El bit b3 está negado: 0 = nivel de agua correcto (estado sano
     por defecto si el cliente nunca escribe). ---- *)
  Start_Button   := (Modbus_Cmd AND 16#01) <> 0;
  Stop_Button    := (Modbus_Cmd AND 16#02) <> 0;
  Emergency_Stop := (Modbus_Cmd AND 16#04) <> 0;
  Water_Level_OK := (Modbus_Cmd AND 16#08) = 0;
  Reset_Fault    := (Modbus_Cmd AND 16#10) <> 0;
  Reset_Volume   := (Modbus_Cmd AND 16#20) <> 0;

  IF Emergency_Stop OR NOT Water_Level_OK OR Stop_Button THEN
    Pump_Cmd := FALSE;
  ELSIF Start_Button AND NOT Start_Prev AND NOT Fault_Active THEN
    Pump_Cmd := TRUE;
  END_IF;

  Start_Prev := Start_Button;

  (* ==========================================================
     2. FALLOS Y REARME
     ========================================================== *)
  IF Emergency_Stop THEN
    Fault_Active := TRUE;
    Fault_Code   := 101;
  ELSIF NOT Water_Level_OK THEN
    Fault_Active := TRUE;
    Fault_Code   := 103;
  END_IF;

  Run_Timer(IN := Pump_Cmd, PT := T#3s);
  Dry_Run_Timer(IN := Pump_Cmd AND Run_Timer.Q AND (Flow_Rate_Lpm < 5.0),
                PT := T#5s);

  IF Dry_Run_Timer.Q THEN
    Fault_Active := TRUE;
    Fault_Code   := 102;
    Pump_Cmd     := FALSE;
  END_IF;

  IF Reset_Fault AND NOT Emergency_Stop AND Water_Level_OK AND NOT Pump_Cmd THEN
    Fault_Active := FALSE;
    Fault_Code   := 0;
  END_IF;

  (* ==========================================================
     3. SIMULACIÓN DEL CAUDAL
     Ruido determinista (seno) para que la lectura no sea plana.
     Con la bomba parada el caudal decae hasta cero.
     ========================================================== *)
  Noise_Phase := Noise_Phase + 1;
  IF Noise_Phase > 1000000 THEN
    Noise_Phase := 0;
  END_IF;
  Noise_Factor := SIN(DINT_TO_REAL(Noise_Phase) * 0.37) * 0.04;  (* ±4 % *)

  IF Pump_Cmd THEN
    Flow_Target_Lpm := Flow_Setpoint_Lpm * (1.0 + Noise_Factor);

    IF Flow_Rate_Lpm < Flow_Target_Lpm THEN
      Flow_Rate_Lpm := Flow_Rate_Lpm + Flow_Ramp_Lpm;
      IF Flow_Rate_Lpm > Flow_Target_Lpm THEN
        Flow_Rate_Lpm := Flow_Target_Lpm;
      END_IF;
    ELSE
      Flow_Rate_Lpm := Flow_Rate_Lpm - Flow_Ramp_Lpm;
      IF Flow_Rate_Lpm < Flow_Target_Lpm THEN
        Flow_Rate_Lpm := Flow_Target_Lpm;
      END_IF;
    END_IF;
  ELSE
    (* Inercia: el agua sigue saliendo brevemente tras el paro *)
    Flow_Rate_Lpm := Flow_Rate_Lpm * 0.85;
    IF Flow_Rate_Lpm < 0.1 THEN
      Flow_Rate_Lpm := 0.0;
    END_IF;
  END_IF;

  IF Flow_Rate_Lpm < 0.0 THEN
    Flow_Rate_Lpm := 0.0;
  END_IF;

  (* ==========================================================
     4. TOTALIZADOR DE VOLUMEN
     V [L] += Q [L/min] * (Δt [s] / 60 [s/min])
     Δt = 0.02 s (periodo de task0); 1 ciclo ≈ 0.000333 min
     ========================================================== *)
  IF Reset_Volume THEN
    Volume_Liters := 0.0;
  ELSE
    Volume_Liters := Volume_Liters + (Flow_Rate_Lpm * (Cycle_Time_s / 60.0));
  END_IF;

  (* ==========================================================
     5. PUBLICACIÓN EN LA IMAGEN MODBUS
     Se escribe al final del scan para que el cliente lea el
     estado coherente de este ciclo.
     ========================================================== *)
  Modbus_Pump       := Pump_Cmd;
  Modbus_Fault      := Fault_Active;
  Modbus_Fault_Code := Fault_Code;
  Modbus_Flow       := Flow_Rate_Lpm;
  Modbus_Volume     := Volume_Liters;

END_PROGRAM