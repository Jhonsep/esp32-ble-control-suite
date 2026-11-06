// --------------------------------------             
//                Controlador de Pantallas Mobiles
//                By Oscar Chang
//                October 2026 
//---------------------------------------   

#include <AccelStepper.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ==================== BLUETOOTH LOW ENERGY (BLE NUS) ====================
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

BLEServer *pServer = NULL;
BLECharacteristic *pTxCharacteristic = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

String device_name = "joystick";
volatile int comandoBlePendiente = 0;
String bleRxBuffer = "";
int data_gold = 0;

// ==================== CONFIGURACIÓN DE PINES (ADC1) ====================
const int PIN_RED   = 35;
const int PIN_GREEN = 34;
const int PIN_BLUE  = 36;

const int adcResolution = 12;
#define LED_PIN 2

// ==================== PINES Y CONFIGURACIÓN MOTOR ====================
const int dirPin    = 12;
const int stepPin   = 13;
const int enablePin = 27;
const int PIN_HALL  = 33;

const int pasosTotalesPorRevolucion = 4000;   
float speedRPM = 2000.0;  
long currentSpeedSPS;

// ============================================================
// ACELERACION SUAVE SOLO AL ARRANQUE
// ============================================================
const unsigned long TIEMPO_ACELERACION_MS = 1000; 

// ============================================================
// VIGILANTE DE SEGURIDAD - AJUSTAR IN SITU
// ============================================================
const unsigned long SAFETY_TIMEOUT_MS = 30000;    // To October 31, 2026
const long SAFETY_MAX_STEPS = 150000;             // Same

unsigned long tInicioAceleracion = 0;
long velocidadObjetivoSPS = 0;
bool acelerandoMotor = false;

// Control de parpadeo LED no bloqueante
unsigned long tApagarLed = 0;

AccelStepper stepper(AccelStepper::DRIVER, stepPin, dirPin);

// ==================== MEMORIA FLASH (NVS) ====================
Preferences preferences;

// ==================== POSICIONES ====================
long PASOS_P2 = -40000;    // 30000
long PASOS_P3 = -80000;    

const int POS_DESCONOCIDA = 0;
const int POS_ESTE        = 1;
const int POS_P2          = 2;
const int POS_P3          = 3;
const int POS_OESTE       = 4;

int posicionActual = POS_DESCONOCIDA;
int posicionObjetivo = POS_DESCONOCIDA;

// ==================== ESTADOS DEL MOVIMIENTO ====================
enum EstadoMovimiento {
  MOVIMIENTO_PARADO,
  HOMING_ESTE,
  MOVIENDO_A_P2,
  MOVIENDO_A_P3,
  MOVIENDO_A_ESTE,
  MOVIENDO_A_OESTE,
  SALUDO_A_P2
};

EstadoMovimiento estadoMovimiento = MOVIMIENTO_PARADO;

bool motorEnMovimiento = false;
int direccionMovimiento = 0; // +1 = ESTE, -1 = OESTE
bool hallArmadoParaParar = false; 
long pasosObjetivo = 0;

// ---------------- VIGILANTE DE SEGURIDAD ----------------
unsigned long tInicioMovimientoSeguridad = 0;
long pasosInicioMovimientoSeguridad = 0;
bool seguridadActiva = false;

// ==================== UMBRALES HALL Y MUESTREO ====================  
const int UMBRAL_HALL_ON  = 1500;    
const int UMBRAL_HALL_OFF = 1450;    
const unsigned long HALL_PERIODO_MS = 50;

bool hallUltimoEstado = false;
unsigned long t_hall_ultimo = 0;

// --- ANTI-RUIDO / DEBOUNCE PARA SENSOR HALL ---
int contadorConfirmacionHall = 0;
const int MUESTRAS_CONFIRMACION_HALL = 3;

// ==================== NUEVO DETECTOR ÓPTICO RGB ====================
const unsigned long SAMPLE_US = 200;

// ---- Detección de Bloques Blancos y Espacios Negros ----
const int UMBRAL         = 1500;  
const int UMBRAL_REARME  = 500;   
const unsigned long MIN_BLOQUE_US = 20000;  // 20 ms
const unsigned long MAX_BLOQUE_US = 65000;  // 65 ms
const unsigned long FIN_BLOQUE_US = 7000;   // 7 ms

// ---- Umbral de decisión de bits (Espacio corto vs largo) ----
const unsigned long UMBRAL_BIT_US = 115000UL; // 115 ms     OJO !  afinar para mejorar recepcion de -000-

// ---- Sincronismo de mensaje y trama ----
const int           N_BLOQUES_MSJ    = 4;        
const unsigned long SILENCIO_MIN_US  = 400000UL;  // 400 ms entre mensajes

// ---- Estado del Receptor Óptico ----
enum EstadoOptico { REPOSO, EN_BLOQUE };
EstadoOptico estadoOptico = REPOSO;

unsigned long tInicioBloque      = 0;
unsigned long tUltimoArriba      = 0;
unsigned long tUltimoBloque      = 0;      
unsigned long tFinBloqueAnt      = 0;      
bool          hayUltimo          = false;
bool          primerBloqueDelMsj = true;
int           bloquesEnMsj       = 0;
unsigned long proximaMuestraOptica = 0;

// ---- Almacenamiento de Bits y Control de Bloques de Mensajes ----
int bitsMensaje[3];  
int contadorMensajesBloque = 0; 

int auto_flag = 1;

// Prototipos de funciones globales
void ejecutarComando(int comando);
void detenerMotor();
void enviarConsolaBLE(const String &texto);

// ============================================================
// CALLBACKS Y COMUNICACIÓN BLE (NORDIC UART SERVICE)
// ============================================================
class MyServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println("BLE: Cliente conectado");
  }

  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("BLE: Cliente desconectado, reiniciando advertising...");
    pServer->startAdvertising(); // Permite reconexión rápida inmediata
  }
};

class MyCallbacks: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    String rxValue = pCharacteristic->getValue().c_str();
    for (unsigned int i = 0; i < rxValue.length(); i++) {
      char c = rxValue[i];
      if (c == '\n' || c == '\r') {
        if (bleRxBuffer.length() > 0) {
          comandoBlePendiente = bleRxBuffer.toInt();
          bleRxBuffer = "";
        }
      } else {
        bleRxBuffer += c;
      }
    }
    // Soporte por si algún cliente envía el número sin '\n' al final
    if (bleRxBuffer.length() > 0 && rxValue.indexOf('\n') == -1) {
      comandoBlePendiente = bleRxBuffer.toInt();
      bleRxBuffer = "";
    }
  }
};

void iniciarBLE() {
  BLEDevice::init(device_name.c_str());
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  // Característica TX (ESP32 -> App por Notify)
  pTxCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID_TX,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pTxCharacteristic->addDescriptor(new BLE2902());

  // Característica RX (App -> ESP32 por Write)
  BLECharacteristic *pRxCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID_RX,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  pRxCharacteristic->setCallbacks(new MyCallbacks());

  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06); // Recomendado para conexión rápida en iOS
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("BLE UART iniciado. Dispositivo: " + device_name);
}

void enviarConsolaBLE(const String &texto) {
  Serial.println(texto);
  if (deviceConnected && pTxCharacteristic != NULL) {
    String payload = texto + "\n";
    pTxCharacteristic->setValue(payload.c_str());
    pTxCharacteristic->notify();
  }
}

// ============================================================
// RECEPCIÓN DE DATOS BLUETOOTH BLE (NO BLOQUEANTE)
// ============================================================
int btReceptor() {
  if (comandoBlePendiente != 0) {
    int cmd = comandoBlePendiente;
    comandoBlePendiente = 0;
    return cmd;
  }
  return 0;
}

// ============================================================
// ANALIZADOR DE COMANDOS BLUETOOTH (GOLD ANALYZER)
// ============================================================
void gold_analyzer() {
  data_gold = btReceptor();
  if (data_gold != 0) {
    digitalWrite(LED_PIN, HIGH);
    tApagarLed = millis() + 50; // Parpadeo no bloqueante (sin delay)

    // --- OPTION 1..4 (10..13) -> POSICIONES P1..P4 ---
    if (data_gold == 10) {      // Option 1: Mover a P1 (ESTE)
      enviarConsolaBLE("BLE [10]: Moviendo a P1 (ESTE)");
      ejecutarComando(1);
    } 
    else if (data_gold == 11) { // Option 2: Mover a P2
      enviarConsolaBLE("BLE [11]: Moviendo a P2");
      ejecutarComando(2);
    } 
    else if (data_gold == 12) { // Option 3: Mover a P3
      enviarConsolaBLE("BLE [12]: Moviendo a P3");
      ejecutarComando(3);
    } 
    else if (data_gold == 13) { // Option 4: Mover a OESTE (P4)
      enviarConsolaBLE("BLE [13]: Moviendo a P4 (OESTE)");
      ejecutarComando(4);
    } 
    // --- FLECHAS (1..4) -> LIBRES / JOG MANUAL ---
    else if (data_gold >= 1 && data_gold <= 4) {
      enviarConsolaBLE("BLE [" + String(data_gold) + "]: Flecha / Jog manual recibido");
    }
    // --- CONTROLES AUXILIARES Y EMERGENCIA ---
    else if (data_gold == 5) {  // Plus: Toggle Auto/Manual RGB
      auto_flag = auto_flag ^ 1;
      enviarConsolaBLE("BLE [5]: auto_flag = " + String(auto_flag));
    } 
    else if (data_gold == 7) {  // STOP de emergencia
      enviarConsolaBLE("BLE [7]: PARADA DE EMERGENCIA (STOP)");
      detenerMotor();
    } 
    else {
      enviarConsolaBLE("BLE [" + String(data_gold) + "]: Comando auxiliar recibido");
    }
  }
  data_gold = 0;
}

// ============================================================
// LECTURA DE TECLADO (CONSOLA USB)
// ============================================================
void read_key() {  
  char comand;
  while (Serial.available() > 0) {
    comand = Serial.read();
    if (comand == 'a') {
      auto_flag = auto_flag ^ 1;
      Serial.println("auto_flag " + String(auto_flag));
      delay(10);
    }      
    else if (comand == '1') { ejecutarComando(1); delay(10); }  
    else if (comand == '2') { ejecutarComando(2); delay(10); } 
    else if (comand == '3') { ejecutarComando(3); delay(10); }  
    else if (comand == '4') { ejecutarComando(4); delay(10); } 
    else if (comand == 'r' || comand == 'R') {
      Serial.println("Reiniciando ESP32...");
      delay(1000);
      ESP.restart();
    }
  }
}

// ============================================================
// FLASH
// ============================================================
void guardarEstadoFlash(int posicion, bool movimientoEnCurso, int destino) {
  preferences.putInt("pos", posicion);
  preferences.putBool("moving", movimientoEnCurso);
  preferences.putInt("target", destino);
}

// ============================================================
// HABILITAR / DESHABILITAR DRIVER
// ============================================================
void habilitarMotor() { digitalWrite(enablePin, LOW); }
void deshabilitarMotor() { digitalWrite(enablePin, HIGH); }

// ============================================================
// DETENER MOTOR
// ============================================================
void detenerMotor() {
  motorEnMovimiento = false;
  direccionMovimiento = 0;
  estadoMovimiento = MOVIMIENTO_PARADO;
  acelerandoMotor = false;
  velocidadObjetivoSPS = 0;
  stepper.setSpeed(0);
  deshabilitarMotor();
}

// ============================================================
// INICIAR RAMPA DE ACELERACION
// ============================================================
void iniciarAceleracion(long velocidadFinalSPS) {
  velocidadObjetivoSPS = velocidadFinalSPS;
  tInicioAceleracion = millis();
  acelerandoMotor = true;
  long velocidadInicial = (long)(velocidadFinalSPS * 0.15f);
  if (velocidadInicial == 0) {
    velocidadInicial = (velocidadFinalSPS > 0) ? 1 : -1;
  }
  stepper.setSpeed(velocidadInicial);
}

// ============================================================
// ACTUALIZAR RAMPA
// ============================================================
void actualizarAceleracion() {
  if (!motorEnMovimiento || !acelerandoMotor) return;

  unsigned long transcurrido = millis() - tInicioAceleracion;
  if (transcurrido >= TIEMPO_ACELERACION_MS) {
    stepper.setSpeed(velocidadObjetivoSPS);
    acelerandoMotor = false;
    return;
  }

  float progreso = (float)transcurrido / (float)TIEMPO_ACELERACION_MS;
  float factor = 0.15f + 0.85f * progreso;
  long velocidadActual = (long)(velocidadObjetivoSPS * factor);

  if (velocidadActual == 0) {
    velocidadActual = (velocidadObjetivoSPS > 0) ? 1 : -1;
  }
  stepper.setSpeed(velocidadActual);
}

// ============================================================
// FINALIZAR LLEGADA A UNA POSICIÓN
// ============================================================
void llegarAPosicion(int nuevaPosicion) {
  seguridadActiva = false;
  posicionActual = nuevaPosicion;
  posicionObjetivo = nuevaPosicion;

  if (nuevaPosicion == POS_ESTE) {
    stepper.setCurrentPosition(0);
  }

  detenerMotor();
  int hallRawConfirmacion = analogRead(PIN_HALL);
  guardarEstadoFlash(posicionActual, false, posicionObjetivo);

  enviarConsolaBLE("POSICION CONFIRMADA: " + String(posicionActual) + " | HALL RAW: " + String(hallRawConfirmacion));
}

// ============================================================
// VIGILANTE DE SEGURIDAD
// ============================================================
void iniciarVigilanteSeguridad() {
  tInicioMovimientoSeguridad = millis();
  pasosInicioMovimientoSeguridad = stepper.currentPosition();
  seguridadActiva = true;
}

bool vigilarSeguridadMovimiento() {
  if (!motorEnMovimiento || !seguridadActiva) return false;

  unsigned long tiempoTranscurrido = millis() - tInicioMovimientoSeguridad;
  long pasosRecorridos = labs(stepper.currentPosition() - pasosInicioMovimientoSeguridad);

  bool fallaTimeout = (tiempoTranscurrido > SAFETY_TIMEOUT_MS);
  bool fallaPasos   = (pasosRecorridos > SAFETY_MAX_STEPS);

  if (fallaTimeout || fallaPasos) {
    Serial.println("\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
    if (fallaTimeout && fallaPasos) Serial.println("SAFETY DETENIDO: TIMEOUT y EXCESO DE PASOS");
    else if (fallaTimeout) Serial.println("SAFETY DETENIDO: TIMEOUT");
    else Serial.println("SAFETY DETENIDO: EXCESO DE PASOS");
    
    detenerMotor();
    seguridadActiva = false;
    posicionActual = POS_DESCONOCIDA;
    posicionObjetivo = POS_DESCONOCIDA;
    guardarEstadoFlash(POS_DESCONOCIDA, false, POS_DESCONOCIDA);
    return true;
  }
  return false;
}

// ============================================================
// INICIAR MOVIMIENTO
// ============================================================
void iniciarMovimiento(int destino) {
  if (estadoMovimiento == HOMING_ESTE) {
    Serial.println("COMANDO IGNORADO: homing hacia ESTE en curso");
    return;
  }

  if (posicionActual == destino) {
    Serial.print("YA ESTAMOS EN POSICION ");
    Serial.println(destino);
    return;
  }

  posicionObjetivo = destino;
  guardarEstadoFlash(posicionActual, true, posicionObjetivo);
  hallArmadoParaParar = !hallUltimoEstado;

  if (destino == POS_ESTE) {
    Serial.println("MOVIMIENTO: hacia ESTE hasta Hall");
    direccionMovimiento = +1;
    estadoMovimiento = MOVIENDO_A_ESTE;
    motorEnMovimiento = true;
    habilitarMotor();
    iniciarAceleracion(abs(currentSpeedSPS));
    iniciarVigilanteSeguridad();
    return;
  }

  if (destino == POS_P2 || destino == POS_P3) {
    pasosObjetivo = (destino == POS_P2) ? PASOS_P2 : PASOS_P3;
    long posicionPasoActual = stepper.currentPosition();

    if (posicionPasoActual == pasosObjetivo) {
      llegarAPosicion(destino);
      return;
    }
    direccionMovimiento = (pasosObjetivo < posicionPasoActual) ? -1 : +1;
    estadoMovimiento = (destino == POS_P2) ? MOVIENDO_A_P2 : MOVIENDO_A_P3;
    motorEnMovimiento = true;

    Serial.print("MOVIMIENTO: a posicion ");
    Serial.println(destino);
    habilitarMotor();
    iniciarAceleracion(direccionMovimiento * abs(currentSpeedSPS));
    iniciarVigilanteSeguridad();
    return;
  }

  if (destino == POS_OESTE) {
    Serial.println("MOVIMIENTO: hacia OESTE hasta Hall");
    direccionMovimiento = -1;
    estadoMovimiento = MOVIENDO_A_OESTE;
    motorEnMovimiento = true;
    habilitarMotor();
    iniciarAceleracion(-abs(currentSpeedSPS));
    iniciarVigilanteSeguridad();
    return;
  }
}

// ============================================================
// EJECUCIÓN DE COMANDOS
// ============================================================
void ejecutarComando(int comando) {
  Serial.print("COMANDO RECIBIDO: ");
  Serial.println(comando);

  if (comando >= POS_ESTE && comando <= POS_OESTE) {
    iniciarMovimiento(comando);
  } else {
    Serial.println("COMANDO FUERA DE RANGO: ignorado");
  }
}

// ============================================================
// AYUDAS PARA MOVIMIENTO POR PASOS (P2 / P3)
// ============================================================
bool pasoObjetivoAlcanzado() {
  long pos = stepper.currentPosition();
  if (direccionMovimiento < 0) return pos <= pasosObjetivo;  
  if (direccionMovimiento > 0) return pos >= pasosObjetivo;  
  return false;
}

void finalizarMovimientoPorPasos() {
  if (estadoMovimiento == SALUDO_A_P2) {
    stepper.setCurrentPosition(pasosObjetivo);
    llegarAPosicion(POS_P2);

    Serial.println("SALUDO: P2 alcanzada, regresando a P1");
    posicionObjetivo = POS_ESTE;
    direccionMovimiento = +1;
    estadoMovimiento = MOVIENDO_A_ESTE;
    motorEnMovimiento = true;
    hallArmadoParaParar = !hallUltimoEstado;
    guardarEstadoFlash(POS_P2, true, POS_ESTE);

    habilitarMotor();
    iniciarAceleracion(abs(currentSpeedSPS));
    iniciarVigilanteSeguridad();
    return;
  }

  int destino = (estadoMovimiento == MOVIENDO_A_P2) ? POS_P2 : POS_P3;
  stepper.setCurrentPosition(pasosObjetivo);   
  llegarAPosicion(destino);
}

// ============================================================
// CONTROL DE MOVIMIENTO (CORREGIDO)
// ============================================================
void controlarMovimiento() {
  if (!motorEnMovimiento) return;
  if (vigilarSeguridadMovimiento()) return;

  actualizarAceleracion();

  if (estadoMovimiento == MOVIENDO_A_P2 ||
      estadoMovimiento == MOVIENDO_A_P3 ||
      estadoMovimiento == SALUDO_A_P2) {
    
    // Ejecutar paso e inmeditamente comprobar si se llegó al objetivo
    stepper.runSpeed();
    if (pasoObjetivoAlcanzado()) {
      finalizarMovimientoPorPasos();
    }
    return;
  }
  
  stepper.runSpeed();
}

// ============================================================
// ARRANQUE SEGURO
// ============================================================
void iniciarRetornoSeguroAP1() {
  posicionActual = POS_DESCONOCIDA;
  posicionObjetivo = POS_ESTE;
  estadoMovimiento = HOMING_ESTE;
  motorEnMovimiento = true;
  direccionMovimiento = +1;
  hallArmadoParaParar = !hallUltimoEstado;
  stepper.setCurrentPosition(0);
  guardarEstadoFlash(POS_DESCONOCIDA, true, POS_ESTE);

  habilitarMotor();
  iniciarAceleracion(abs(currentSpeedSPS));
  iniciarVigilanteSeguridad();

  Serial.println("\n========================================");
  Serial.println("ARRANQUE SEGURO: buscando ESTE (P1)");
  Serial.println("========================================");
}

void iniciarSaludoDesdeP1() {
  posicionActual = POS_ESTE;
  posicionObjetivo = POS_P2;
  stepper.setCurrentPosition(0);
  pasosObjetivo = PASOS_P2;
  direccionMovimiento = -1;
  estadoMovimiento = SALUDO_A_P2;
  motorEnMovimiento = true;
  hallArmadoParaParar = false;
  guardarEstadoFlash(POS_ESTE, true, POS_P2);

  habilitarMotor();
  iniciarAceleracion(-abs(currentSpeedSPS));
  iniciarVigilanteSeguridad();

  Serial.println("\n========================================");
  Serial.println("ARRANQUE NORMAL: SALUDO P1 -> P2 -> P1");
  Serial.println("========================================");
}

// ============================================================
// CONTROL HALL FILTRADO ANTI-RUIDO
// ============================================================
void muestrearHall() {  
  unsigned long ahora = millis();
  read_key();
  if (ahora - t_hall_ultimo < HALL_PERIODO_MS) return;
  t_hall_ultimo = ahora;

  int hallRaw = analogRead(PIN_HALL);
  bool hallMuestraActual;

  if (hallUltimoEstado) {
    hallMuestraActual = (hallRaw < UMBRAL_HALL_OFF);
  } else {
    hallMuestraActual = (hallRaw < UMBRAL_HALL_ON);
  }

  if (hallMuestraActual != hallUltimoEstado) {
    contadorConfirmacionHall++;
    if (contadorConfirmacionHall >= MUESTRAS_CONFIRMACION_HALL) {
      hallUltimoEstado = hallMuestraActual;
      contadorConfirmacionHall = 0;

      if (hallUltimoEstado) {
        Serial.println("HALL: tope detectado");
        if (motorEnMovimiento && hallArmadoParaParar) {
          if (direccionMovimiento > 0 && (estadoMovimiento == HOMING_ESTE || estadoMovimiento == MOVIENDO_A_ESTE)) {
            Serial.println("HALL: ESTE confirmado, motor detenido");
            llegarAPosicion(POS_ESTE);
          } else if (direccionMovimiento < 0 && estadoMovimiento == MOVIENDO_A_OESTE) {
            Serial.println("HALL: OESTE confirmado, motor detenido");
            llegarAPosicion(POS_OESTE);
          }
        }
      } else {
        hallArmadoParaParar = true;
        Serial.println("HALL: tope liberado");
        if (motorEnMovimiento && !acelerandoMotor) {
          if (direccionMovimiento > 0) stepper.setSpeed(abs(currentSpeedSPS));
          else if (direccionMovimiento < 0) stepper.setSpeed(-abs(currentSpeedSPS));
        }
      }
    }
  } else {
    contadorConfirmacionHall = 0;
  }
}

// ============================================================
// DECODIFICADOR ÓPTICO RGB INTEGRADO
// ============================================================
void procesarMensajeDecodificado() {
  String codigo = String(bitsMensaje[0]) + String(bitsMensaje[1]) + String(bitsMensaje[2]);
  
  int unos = bitsMensaje[0] + bitsMensaje[1] + bitsMensaje[2];
  bool paridadCorrecta = (unos % 2 == 0);

  Serial.print("Bits: [");
  Serial.print(codigo);
  Serial.print("] -> ");

  if (!paridadCorrecta) {
    Serial.println("ERROR DE PARIDAD (Impar)");
    return;
  }

  int cmd = 0;
  if (codigo == "000") { Serial.print("MENSAJE 1"); cmd = 1; } 
  else if (codigo == "011") { Serial.print("MENSAJE 2"); cmd = 2; } 
  else if (codigo == "101") { Serial.print("MENSAJE 3"); cmd = 3; } 
  else if (codigo == "110") { Serial.print("MENSAJE 4"); cmd = 4; } 
  else {
    Serial.println("MENSAJE DESCONOCIDO");
    return;
  }

  Serial.println();

  contadorMensajesBloque++;
  if (contadorMensajesBloque >= 4) {
    Serial.println(); 
    contadorMensajesBloque = 0;
  }

  if (auto_flag) {
    ejecutarComando(cmd);
    digitalWrite(LED_PIN, HIGH);
    tApagarLed = millis() + 100; 
  }
}

void analizarRGB(int v, unsigned long ahora) {
  switch (estadoOptico) {
    case REPOSO:
      if (v > UMBRAL) {          
        tInicioBloque = ahora;
        tUltimoArriba = ahora;
        estadoOptico  = EN_BLOQUE;
      }
      break;

    case EN_BLOQUE:
      if (v > UMBRAL_REARME) {   
        tUltimoArriba = ahora;
      } else {
        if ((long)(ahora - tUltimoArriba) > (long)FIN_BLOQUE_US) {
          unsigned long dur = tUltimoArriba - tInicioBloque;
          
          if (dur >= MIN_BLOQUE_US && dur <= MAX_BLOQUE_US) {
            if (!hayUltimo || (tInicioBloque - tUltimoBloque) >= SILENCIO_MIN_US) {
              bloquesEnMsj = 0;
              primerBloqueDelMsj = true;
            }

            if (!primerBloqueDelMsj) {
              unsigned long durEspacioNegro = tInicioBloque - tFinBloqueAnt;
              int bitIndex = bloquesEnMsj - 1; 

              if (durEspacioNegro > UMBRAL_BIT_US) {
                bitsMensaje[bitIndex] = 1; 
              } else {
                bitsMensaje[bitIndex] = 0; 
              }
            }

            bloquesEnMsj++;
            tUltimoBloque      = tInicioBloque;
            tFinBloqueAnt      = tUltimoArriba;
            primerBloqueDelMsj = false;
            hayUltimo          = true;

            if (bloquesEnMsj >= N_BLOQUES_MSJ) {
              procesarMensajeDecodificado();
              bloquesEnMsj = 0;
              primerBloqueDelMsj = true;
            }
          }
          estadoOptico = REPOSO;
        }
      }
      break;
  }
}

// ============================================================
// SETUP
// ============================================================
void setup() {
  Serial.begin(921600); 

  // Inicialización del Bluetooth Low Energy (BLE NUS)
  iniciarBLE();

  analogReadResolution(adcResolution);
  analogSetAttenuation(ADC_11db);

  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

  pinMode(PIN_RED, INPUT);
  pinMode(PIN_GREEN, INPUT);
  pinMode(PIN_BLUE, INPUT);
  pinMode(PIN_HALL, INPUT);

  pinMode(enablePin, OUTPUT);
  deshabilitarMotor();

  currentSpeedSPS = (long)(speedRPM * pasosTotalesPorRevolucion / 60.0);

  stepper.setMaxSpeed(abs(currentSpeedSPS) * 2);
  stepper.setSpeed(0);
  stepper.setCurrentPosition(0);

  preferences.begin("pantalla", false);
  int ultimaPosicion = preferences.getInt("pos", POS_DESCONOCIDA);
  bool movimientoInterrumpido = preferences.getBool("moving", false);

  Serial.println("\n========================================");
  Serial.println("CONTROL DE PANTALLA CON BT INTEGRADO");
  Serial.println("========================================");

  int hallRawInicial = analogRead(PIN_HALL);
  hallUltimoEstado = (hallRawInicial < UMBRAL_HALL_ON);
  contadorConfirmacionHall = 0;

  t_hall_ultimo = millis();
  proximaMuestraOptica = micros(); 

  if (ultimaPosicion == POS_ESTE && !movimientoInterrumpido) {
    iniciarSaludoDesdeP1();
  } else {
    Serial.println("ARRANQUE: recuperacion segura hacia P1");
    iniciarRetornoSeguroAP1();
  }
}

// ============================================================
// LOOP
// ============================================================
void loop() {
  // 0. Gestión del apagado del LED de feedback
  if (tApagarLed > 0 && millis() >= tApagarLed) {
    digitalWrite(LED_PIN, LOW);
    tApagarLed = 0;
  }

  // 1. Control del Motor
  controlarMovimiento();

  // 2. Sensor Hall y Teclado local
  muestrearHall();

  // 3. Procesar comandos por Bluetooth
  gold_analyzer();

  // 4. Receptor Óptico por microsegundos (cada 200 µs)
  unsigned long ahoraMicros = micros();
  if ((long)(ahoraMicros - proximaMuestraOptica) >= 0) {
    proximaMuestraOptica += SAMPLE_US;
   
    int r = analogRead(PIN_RED);
    int g = analogRead(PIN_GREEN);
    int b = analogRead(PIN_BLUE);
    int v = min(r, min(g, b));
    
    if (auto_flag) {
      analizarRGB(v, ahoraMicros);
    }
  }
}