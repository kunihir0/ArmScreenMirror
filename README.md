# ipa-remote

Mirror y control remoto de un iPhone con jailbreak desde un Mac, sobre la red local, con cifrado de extremo a extremo.

El iPhone captura su pantalla en H.264, la cifra con AES-256-GCM y la envía a un servidor que corre en macOS. El servidor decodifica el stream en tiempo real, lo muestra en una ventana y reenvía toques, swipes, teclas y botones físicos al iPhone.

```
┌─────────────────────┐         AES-256-GCM           ┌─────────────────────┐
│  iPhone (jailbreak) │  ───── X25519 ephemeral ───→  │   ScreenMirror.app  │
│  SpringBoard tweak  │   PBKDF2-SHA512 + password    │   macOS 12+ AppKit  │
│  H.264 / 60-fps cap │  ←───── HID inyectado ────── │   AVSampleBuffer    │
└─────────────────────┘     TCP :4878 / Bonjour       └─────────────────────┘
```

## Características

- **Streaming en vivo H.264** con presets de calidad (Low / Medium / High) seleccionables desde la UI.
- **Control remoto completo**: ratón, teclado, gestos sintéticos (swipe, multi-finger), botones físicos (Home, Lock, Vol+/-, Mute, Siri).
- **Navegación rápida** desde la barra superior: páginas previa/siguiente, App Switcher, Centro de Notificaciones.
- **Detección automática de form factor** (Home button / Face ID / iPad) y de versión de iOS para enviar los gestos correctos.
- **Cifrado de extremo a extremo**:
  - X25519 efímero por sesión (forward secrecy).
  - PBKDF2-SHA512 con 600 000 iteraciones para derivar la clave del password compartido.
  - HKDF-SHA256 mezcla el secreto compartido + PBKDF2 → AES-256-GCM.
  - Contadores monótonos como IV; sin reuso.
- **Multi-dispositivo**: la app abre un selector con tu historial de iPhones; puedes elegir uno o varios y se abre una ventana por cada uno.
- **Modo minimalista**: oculta la cromía y deja sólo la pantalla del dispositivo (⌘.).
- **Popover de información** del dispositivo (modelo, iOS, resolución, peer, cifrado).
- **Bonjour** (`_smirror._tcp.`) para que el iPhone descubra el Mac sin teclear IPs.

## Arquitectura

```
┌──────────────────────────── iPhone (SpringBoard tweak) ────────────────────────────┐
│                                                                                    │
│  ScreenCapture ─→ VideoEncoder ─→ NetworkClient ──┐                                │
│  (CARenderServer /                  (X25519 +     │                                │
│   _UICreateScreenUIImage)            PBKDF2 +     │ TCP cifrado                   │
│                                      AES-GCM)     │                                │
│                                                   │                                │
│  TouchInjector ←── NetworkClient ◀────────────────┘                                │
│  (IOHIDEventSystemClient,                                                          │
│   Hand transducer)                                                                 │
│                                                                                    │
└────────────────────────────────────────────────────────────────────────────────────┘
                                    ▲
                                    │ tweak controla un app de control con UI iOS
                                    │ que persiste host/password/enabled en un plist
                                    ▼
                          ScreenMirrorControl.app (iPhone)

┌──────────────────────────── Mac (AppKit) ──────────────────────────────────────────┐
│                                                                                    │
│  DevicePickerWindow ─→ MainWindowController(targetDevice) ──────┐                  │
│                                                                  │                  │
│  ConnectionRouter ◀─── NetworkServer (1 listener, N peers)       │                  │
│   ↓ rutea por handshake                                          │                  │
│  MainWindowController.routerReceivedMessage                      │                  │
│   ↓                                                              │                  │
│  VideoDecoder (VTDecompressionSession) ─→ DeviceView (AVSBDisplayLayer)             │
│                                                                                    │
│  DeviceView ─→ EventForwarder ─→ NetworkServer.send ─→ iPhone                      │
│                                                                                    │
└────────────────────────────────────────────────────────────────────────────────────┘
```

Detalles del wire format en [`PROTOCOL.md`](PROTOCOL.md).

## Requisitos

### Mac

- macOS 12 (Monterey) o superior.
- Xcode 14+ con Swift 5.7+ (bastan las Command Line Tools: `xcode-select --install`).
- Conexión a la misma red local que el iPhone.

### iPhone

- Jailbreak rootless (palera1n, Dopamine, …) en iOS 11–16.7. El binario se compila para `arm64` y `arm64e`.
- Acceso SSH al dispositivo (puerto 22 abierto, password conocido — el de `mobile`).
- [Theos](https://theos.dev/) instalado en el Mac, con la variable de entorno `THEOS` apuntando a su raíz (típicamente `~/theos`).

## Instalación

### 1. Clona el repo

```sh
git clone https://github.com/<tu-usuario>/ipa-remote.git
cd ipa-remote
```

### 2. Compila e instala la app del Mac

```sh
cd mac
swift build -c release
```

Esto produce el binario en `mac/.build/arm64-apple-macosx/release/ScreenMirrorServer`.

Para empaquetar en un `.app` con icono, instalarlo en `/Applications` y firmarlo ad-hoc en un solo paso, usa el helper:

```sh
cd ..
./scripts/install-mac-app.sh
open /Applications/ScreenMirror.app
```

Si prefieres hacerlo a mano:

```sh
APP=/Applications/ScreenMirror.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp mac/.build/arm64-apple-macosx/release/ScreenMirrorServer "$APP/Contents/MacOS/ScreenMirror"
cp mac/Resources/Info.plist "$APP/Contents/Info.plist"
# Genera el icono opcional (si lo omites, macOS dibujará un icono genérico):
swift scripts/generate_icon.swift /tmp/icon.png
# (luego construye el .iconset y conviértelo con iconutil — ver scripts/install-mac-app.sh)
codesign --force --deep --sign - "$APP"
open "$APP"
```

Para arrastrarla al Dock basta con tirarla desde Finder, o:

```sh
defaults write com.apple.dock persistent-apps -array-add \
  "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>/Applications/ScreenMirror.app</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
killall Dock
```

### 3. Compila el tweak para el iPhone

Asegúrate de tener Theos:

```sh
git clone --recursive https://github.com/theos/theos.git ~/theos
export THEOS=~/theos
```

Compila el tweak para jailbreak rootless:

```sh
cd ios
THEOS_PACKAGE_SCHEME=rootless make package FINALPACKAGE=1
```

El `.deb` queda en `ios/packages/com.example.screenmirror_*.deb`.

> **Nota**: si tu jailbreak es **rootful** (Unc0ver, Chimera, antiguos checkra1n), omite `THEOS_PACKAGE_SCHEME=rootless`. El paquete entonces se instalará en `/Library/MobileSubstrate/...` en lugar de `/var/jb/Library/MobileSubstrate/...`.

### 4. (Opcional) Compila la app de control para el iPhone

La app de control corre en el iPhone y permite cambiar host/password sin SSH:

```sh
cd ios/control-app
THEOS_PACKAGE_SCHEME=rootless make package FINALPACKAGE=1
```

### 5. Despliega ambos paquetes en el iPhone

Por SSH:

```sh
# Tweak
scp ios/packages/com.example.screenmirror_*.deb mobile@<IP-iPhone>:/var/mobile/sm.deb
ssh mobile@<IP-iPhone> 'sudo dpkg -i /var/mobile/sm.deb && sudo killall -9 SpringBoard'

# App de control
scp ios/control-app/packages/com.example.screenmirror-control_*.deb mobile@<IP-iPhone>:/var/mobile/smc.deb
ssh mobile@<IP-iPhone> 'sudo dpkg -i /var/mobile/smc.deb'
```

`killall SpringBoard` (respring) es necesario después de instalar el tweak para que SpringBoard cargue el dylib.

## Configuración

### Password compartido

El tráfico se cifra con una clave derivada del password compartido. **Tiene que ser idéntico en los dos lados** o el handshake fallará silenciosamente con `decrypt failed`.

- **Mac**: la primera vez que abras la app te pedirá el password. Mínimo 8 caracteres. Se guarda en `~/Library/Preferences/com.example.ScreenMirrorServer.plist` (suite `com.example.ScreenMirrorServer`, clave `smir-shared-password`). Puedes cambiarlo desde el botón **Password** en la barra inferior, o desde el menú **ScreenMirror → Change Password…** (⌘,).
- **iPhone**, opción A — **app de control**: abre **ScreenMirror** en el iPhone, escribe la IP del Mac y el mismo password, deja el switch en **on**, pulsa **Apply and reconnect**.
- **iPhone**, opción B — **manual**: edita por SSH `/var/mobile/Library/Preferences/com.example.screenmirror.plist`:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <plist version="1.0">
  <dict>
      <key>host</key><string>192.168.1.42</string>
      <key>password</key><string>tu-password-secreto</string>
      <key>enabled</key><true/>
  </dict>
  </plist>
  ```

  El tweak releerá el archivo en cada intento de reconexión (cada 5 s).

### Bonjour (descubrimiento automático)

El Mac se anuncia como `_smirror._tcp.` en `local.`. En la app de control puedes pulsar el botón de Bonjour para autodescubrir el Mac sin teclear IPs.

## Uso

1. Abre **ScreenMirror.app** en el Mac (Dock, Spotlight, o `open /Applications/ScreenMirror.app`).
2. La primera vez que cualquier iPhone conecte, su entrada se guarda en el historial; en arranques posteriores aparece el **picker de dispositivos**:
   - Selecciona un dispositivo (o varios con ⌘-click) y pulsa **Connect** — se abrirá una ventana por cada selección.
   - O pulsa **Listen for any device** para abrir una ventana sin filtro que acepta el primer iPhone que conecte.
3. En el iPhone, asegúrate de que el tweak está cargado (si acabas de instalarlo, hace falta `killall SpringBoard`). El tweak se reconecta automáticamente cada 5 s mientras el switch en la app de control esté **on**.
4. Una vez conectado:
   - **Click** = tap.
   - **Click + arrastrar** = swipe.
   - **Teclado** = se reenvía como HID al iPhone.
   - **Botones inferiores**: Home, Lock, Vol +/-, Mute, Siri (mantener pulsado para Siri).
   - **Barra superior**: Página anterior, Página siguiente, App Switcher, Notificaciones.
   - **⌘.** = modo minimalista (sólo la pantalla).
   - **⌘I** = info del dispositivo.
   - **⌘1 / ⌘2 / ⌘3** = calidad Baja / Media / Alta.

## Estructura del repositorio

```
ipa-remote/
├── README.md                     ← este archivo
├── PROTOCOL.md                   ← formato del wire (HELLO, mensajes cifrados)
├── ios/
│   ├── Makefile                  ← Theos: produce el tweak rootless
│   ├── ScreenMirror.plist        ← MobileSubstrate filter (carga sólo en SpringBoard)
│   ├── entitlements.plist        ← entitlements privados HID/IOSurface
│   ├── src/
│   │   ├── Tweak.x               ← controlador principal del tweak
│   │   ├── ScreenCapture.{h,m}   ← captura con CARenderServer / fallback
│   │   ├── VideoEncoder.{h,m}    ← VTCompressionSession H.264
│   │   ├── NetworkClient.{h,m}   ← cliente TCP + handshake X25519 + AES-GCM
│   │   ├── TouchInjector.{h,m}   ← IOHIDEventSystemClient (Hand transducer)
│   │   ├── Crypto.{h,m}          ← PBKDF2-SHA512 + HKDF-SHA256
│   │   ├── X25519.{h,c}          ← scalarmult basado en TweetNaCl
│   │   └── Protocol.h            ← tipos de mensaje + estructuras
│   └── control-app/              ← app iOS para configurar host/password
│       └── src/
│           ├── ViewController.m  ← UI principal
│           └── AppDelegate.m
└── mac/
    ├── Package.swift
    ├── Resources/Info.plist
    └── Sources/ScreenMirrorServer/
        ├── main.swift
        ├── AppDelegate.swift             ← arranca server + muestra picker
        ├── DevicePickerWindowController  ← lista del historial
        ├── DeviceHistory.swift           ← persistencia del listado
        ├── ConnectionRouter.swift        ← rutea conexiones a la ventana correcta
        ├── MainWindowController.swift    ← ventana de streaming (una por device)
        ├── NetworkServer.swift           ← listener TCP + handshake servidor
        ├── Crypto.swift                  ← CryptoKit + CommonCrypto
        ├── VideoDecoder.swift            ← VTDecompressionSession
        ├── DeviceView.swift              ← AVSampleBufferDisplayLayer + input
        ├── EventForwarder.swift          ← serializa toques/swipes/teclas/botones
        ├── NavBar.swift                  ← barra superior con accesos rápidos
        ├── ButtonBar.swift               ← botones físicos del iPhone
        ├── ConnectionOverlay.swift       ← animación "esperando / cifrando"
        ├── Quality.swift                 ← presets Low / Medium / High
        └── Keychain.swift                ← persistencia del password
```

## Solución de problemas

### `decrypt failed — password incorrect` en el log del Mac

El password del Mac y el del iPhone no coinciden. Verifica:

```sh
# Mac
defaults read com.example.ScreenMirrorServer smir-shared-password

# iPhone
ssh mobile@<IP> 'cat /var/mobile/Library/Preferences/com.example.screenmirror.plist'
```

Tienen que ser idénticos byte-a-byte.

### El icono del Dock no se actualiza tras una recompilación

```sh
touch /Applications/ScreenMirror.app
killall Dock
# o si persiste:
rm -rf ~/Library/Caches/com.apple.iconservices.store
sudo find /private/var/folders/ -name com.apple.dock.iconcache -exec rm {} \;
killall Dock
```

### `IOSurface NULL` o pantalla negra en el Mac

El backend de captura del iPhone está cayendo a `_UICreateScreenUIImage`. Revisa los logs de SpringBoard:

```sh
ssh mobile@<IP> 'tail -n 200 /var/log/syslog | grep SMIR'
```

Si aparece `Jetsam` justo antes, posiblemente sea fuga de memoria — usa el preset **Low** desde la app del Mac (⌘1).

### El listener Mac dice `READY` pero `lsof :4878` no muestra nada

`lsof` filtra agresivamente. Usa `netstat -an -p tcp | grep 4878` o conecta con `nc 127.0.0.1 4878` para confirmar.

### `Local Network` denegado por macOS

macOS Sonoma+ pide permiso explícito para descubrimiento Bonjour la primera vez que la app abre un listener. Si no salió el diálogo, fuerza la concesión:

```sh
tccutil reset NSLocalNetworkUsageDescription com.example.ScreenMirrorServer
```

Y reabre la app — debería aparecer el prompt.

## Seguridad

- **Forward secrecy**: cada sesión genera un par X25519 efímero; el secreto compartido se borra inmediatamente después de derivar la clave AES, así que comprometer el password después no permite descifrar capturas anteriores.
- **Autenticación mutua**: ambos lados derivan la misma clave AES-256 sólo si conocen el mismo password. Un atacante en LAN sin password no puede descifrar el stream ni inyectar mensajes (las MAC GCM lo evitan).
- **El password debe ser ≥ 8 caracteres** y nunca debería ser reutilizado fuera de este uso. PBKDF2-SHA512 con 600 000 iteraciones (recomendación OWASP 2023) hace inviable un brute-force offline en hardware típico.
- **TCP en claro a vista de Wireshark**: el wire format es opaco — sólo se ve un HELLO de longitud fija + bloques cifrados con tag GCM de 16 bytes.

## Licencia

MIT — ver [`LICENSE`](LICENSE) (añade el archivo si aún no existe).

## Reconocimientos

- [Theos](https://theos.dev/) por el toolchain de tweaks.
- [TweetNaCl](https://tweetnacl.cr.yp.to/) — base de la implementación X25519 en C.
- Veency / Activator por el patrón de inyección HID con `Hand transducer`.
