# Display Flow

App de barra de menú para macOS que cuida tus monitores — pensada para reducir el riesgo de burn-in en pantallas OLED.

## Cómo funciona

Pinta un overlay sobre cada pantalla **protegida** y lo oculta cuando el cursor entra a esa pantalla. La pantalla con el cursor queda 100 % visible, las demás se oscurecen.

Por defecto, **solo el monitor externo está protegido**: la pantalla del MacBook se deja en paz. Lo cambiás en Preferences si querés.

## Métodos de cuidado incluidos

- **Cursor follow** — la pantalla sin cursor se oscurece con fade.
- **Pause when media is playing** — detecta video, llamadas (Zoom, Meet) y apps que mantienen la pantalla despierta vía IOKit power assertions. Mientras haya algo reproduciéndose, los overlays se quitan.
- **Blackout when idle** — después de N minutos sin tocar mouse/teclado, oscurece todas las pantallas protegidas.
- **Rest Now** — botón manual para apagar las pantallas protegidas hasta que vos lo desactives.
- **Per-display protection** — toggle por monitor. Default inteligente: external sí, builtin no.

## Cómo ejecutar

```sh
cd "/Users/vitio/display flow + care"
./run.sh
```

Compila, firma ad-hoc y abre `Display Flow.app`. El ícono aparece arriba a la derecha en la barra de menú.

Click en el ícono → **Preferences…** abre la ventana SwiftUI con todos los controles.

## Estructura

- [Sources/DisplayFlow/main.swift](Sources/DisplayFlow/main.swift) — entry + AppController
- [Sources/DisplayFlow/Settings.swift](Sources/DisplayFlow/Settings.swift) — `ObservableObject` + ScreenInfo
- [Sources/DisplayFlow/Overlay.swift](Sources/DisplayFlow/Overlay.swift) — overlay window + tick logic
- [Sources/DisplayFlow/MediaWatcher.swift](Sources/DisplayFlow/MediaWatcher.swift) — IOKit power assertions + idle detection
- [Sources/DisplayFlow/UI.swift](Sources/DisplayFlow/UI.swift) — menú + ventana SwiftUI

## Detener

Ícono → **Quit Display Flow**, o:
```sh
pkill -x DisplayFlow
```
