# 📡 ESP32 BLE Control & Debug Suite

![License: MIT](https://img.shields.io/badge/License-MIT-emerald.svg)
![Platform: iOS | Android | Web](https://img.shields.io/badge/Platform-iOS%20%7C%20Android%20%7C%20Web-sky.svg)
![Protocol: BLE NUS UART](https://img.shields.io/badge/Protocol-BLE%20NUS%20UART-indigo.svg)

> **Descripción del Repositorio:** Suite multiplataforma (iOS, Android y Web PWA) para control remoto, telemetría y debugging de proyectos con ESP32 por Bluetooth Low Energy (BLE UART), con plantillas personalizables, parada de emergencia y monitor serial en vivo.

Suite multiplataforma (**iOS, Android y Web**) para control y debugging de proyectos con **ESP32** mediante **Bluetooth Low Energy (BLE UART / NUS)**, reemplazando y modernizando la antigua aplicación de MIT App Inventor manteniendo retrocompatibilidad total con el protocolo de strings (`"1\n"` al `"13\n"`).

---

## 📂 Estructura del Repositorio

```text
📦 codigo_publiyaw/
 ┣ 📂 Master_Control_Bluetooth/  # Firmware Arduino/ESP32 actualizado a BLE (Nordic UART Service)
 ┣ 📂 docs/                      # Web App BLE (PWA) lista para GitHub Pages (iOS Bluefy / Android Chrome)
 ┣ 📂 flutter_app/               # Código fuente nativo en Flutter (flutter_blue_plus) para iOS y Android
 ┣ 📂 app inventor/              # Respaldo legado del proyecto original en MIT App Inventor (.aia)
 ┗ 📜 README.md                  # Documentación general y protocolo de comandos
```

---

## 🔢 Tabla de Comandos BLE (`1\n` al `13\n`)

La aplicación es **agnóstica al proyecto** mediante **Plantillas editables**, enviando siempre por BLE los siguientes códigos terminados en salto de línea (`\n`):

| Botón Base | String BLE | Acción en `Master_Control_Bluetooth.ino` |
| :--- | :---: | :--- |
| **Option 1** | `"10\n"` | Mover a **P1 (ESTE / Home)** (`ejecutarComando(1)`) |
| **Option 2** | `"11\n"` | Mover a **P2** (`ejecutarComando(2)`) |
| **Option 3** | `"12\n"` | Mover a **P3** (`ejecutarComando(3)`) |
| **Option 4** | `"13\n"` | Mover a **P4 (OESTE)** (`ejecutarComando(4)`) |
| **▲ Arriba** | `"1\n"` | Libre / Ajuste manual (*Jog +*) |
| **◀ Izquierda** | `"2\n"` | Libre / Ajuste manual (*Jog ESTE*) |
| **▶ Derecha** | `"3\n"` | Libre / Ajuste manual (*Jog OESTE*) |
| **▼ Abajo** | `"4\n"` | Libre / Ajuste manual (*Jog -*) |
| **➕ Plus** | `"5\n"` | Alternar `auto_flag` (Activa/Desactiva sensor óptico RGB) |
| **➖ Minus** | `"6\n"` | Auxiliar libre |
| **🛑 STOP** | `"7\n"` | **Parada de Emergencia Inmediata** (`detenerMotor()`) |
| **💾 SAVE** | `"8\n"` | Auxiliar libre |
| **▶️ PLAY** | `"9\n"` | Auxiliar libre |

---

## ✨ Características Principales de la Nueva App

1. **⚡ Conexión Rápida + 📡 Escáner BLE Universal:**
   * **Botón `📡 BLE`:** Abre la lista de todos los ESP32 cercanos que estén transmitiendo por BLE (por ejemplo `joystick`, `Joystick 5`, `ESP32_Servo`, etc.) para elegir a cuál conectarte.
   * **Botón `⚡ Rápida`:** Reconecta en un toque al último ESP32 utilizado sin configurar nada.
2. **📋 Plantillas Personalizables en Vivo:**
   * Toca **`+ Plantilla`** para crear un perfil nuevo para otro proyecto o **`✏️ Editar`** para tocar cualquier botón en pantalla y cambiarle el nombre visible sin alterar el código (`1\n`..`13\n`) que envía por debajo.
3. **🌙 / ☀️ Modo Oscuro y Claro:**
   * Detecta automáticamente el tema del teléfono e incluye un botón dedicado en la esquina superior derecha (tras el separador) para alternar entre modo claro y oscuro.
4. **💻 Monitor Serial BLE Bidireccional:**
   * Recibe en tiempo real los mensajes del ESP32 (`enviarConsolaBLE(...)`) sin congelar ni usar timers bloqueantes, y permite enviar cualquier comando numérico manual.

---

## 🚀 Cómo usarla en iOS y Android desde GitHub (Forma más rápida)

1. Sube este repositorio a tu cuenta de **GitHub**.
2. En GitHub, ve a **Settings → Pages** y en **Branch** selecciona `main` y la carpeta **`/docs`**, luego pulsa **Save**.
3. GitHub te dará una URL pública (`https://tu-usuario.github.io/tu-repo/`):
   * **En iPhone / iPad (iOS):** Descarga gratis de la App Store el navegador **Bluefy – Web BLE Browser** y abre ahí la URL de tu GitHub Pages.
   * **En Android / Windows / Mac:** Abre la URL directamente en **Google Chrome** (puedes tocar *"Añadir a pantalla de inicio"* para instalarla como App).

---

## 🛠️ Configuración del ESP32

* El archivo `Master_Control_Bluetooth/Master_Control_Bluetooth/Master_Control_Bluetooth.ino` utiliza la librería estándar `BLEDevice.h` incluida en el core de ESP32 para Arduino.
* Para cambiar el nombre Bluetooth de una placa específica (ej. `"Joystick 5"`), basta con modificar la línea 23:
  ```cpp
  String device_name = "Joystick 5";
  ```
