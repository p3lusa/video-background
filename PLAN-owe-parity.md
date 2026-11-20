# Plan v0.8 — backend OWE nativo, gestión propia

> **ESTADO 2026-11-20: P0 y P1 COMPLETADAS Y EN VIVO.** Dev: 3 commits (294fd52 scripts→mp4,
> ec92ed2 retirada QML v0.8.0, +manifest/README). Instalado: idéntico (release commits).
> Cutover hecho: drop-in hwaccel borrado, shell reiniciado vía omarchy-restart-shell,
> manifest validado (OMIT: registry exige kinds NO vacío + entryPoints → Manager.qml
> servicio vacío, README v0.8 nota). Verificado end-to-end: video-next/prev cambian
> tema+paleta+mp4, owed pinta con VAAPI (engine: renderer, swaps crecen, 0 errores),
> tests del repo 34+35+10 ok, screenshot: wallpaper completo y paleta sincronizada.
> Descubrimiento clave: v0.7 NO reemplazaba al stock — dibujaba encima; el alias de
> primer partido siempre fue del stock (por eso el servicio vacío es seguro).
> Queda: P3 (intros), P4 opcional, push a origin (decisión del usuario), README ya listo para publicar.

> **ESTADO P2 COMPLETADA (mismo día):** commit bd13303 — TUI gana `o` = submenú
> Engine (status legible con hwdec/pauses, pause/resume, always-animate, battery
> mode que escribe ~/.config/owe/config.toml + reload, verificado reversible);
> allowlist de extensiones mp4/mkv/webm/mov/avi en scan TUI, cycle, switcher y
> remove (round-trip .mkv probado: aparece en scan y remove lo borra con póster);
> helper nuevo bin/video-owe.sh (has|status|pause|resume|animate|battery);
> add sigue normalizando a mp4 (biblioteca uniforme). Tests 35+10+line ok;
> ciclo next/prev sin regresión. QUIRK owed 0.2.x detectado (documentado en
> README): fullscreen justo durante theme-switch → pausa antes del primer frame
> → owed marca failed y aparca el still; remedio `owe refresh` (auto: cualquier
> tool). Estado final dejado: video-robot-girl renderizado por owed (engine
> renderer, VAAPI).

> **ESTADO P3 COMPLETADA (mismo día):** Omarchy 4.5 YA tiene sistema de intros
> nativo: backgrounds/intros/<stem>.<ext> junto al póster; se reproduce en login
> (owed --prepare-intro vía omarchy-theme-bg-boot-intro --resolve-startup) y en
> theme-switch (omarchy-theme-set:241 → boot-intro --theme-switch → owe intro
> --start first-frame); toggle global `omarchy theme bg intro`. QUIRKS: resolve_intro
> exige symlink→IMAGEN (por eso el cambio P1 symlink→mp4 desactiva intros en video-
> themes salvo al hacer theme-switch, donde el staged png sí las dispara) y cambiar el
> symlink MATA una intro en curso → helper bin/video-wait-intro.sh (poll
> `owe raw '{"cmd":"intro-status"}'` — intro-status NO es CLI en 0.2.14, solo IPC)
> llamado por cycle/switcher/theme tras el theme set. video-theme.sh --intro instala
> backgrounds/intros/<poster-stem> (hardlink); TUI 'o' añade intros on/off. Test en
> vivo: intro 6s durante cycle: symlink retenido en png, intro ok, luego mp4. No hace
> falta el hook 10-owe-sync (theme-set ya refresca). Commits: dev HEAD=intros,
> instalado idéntico. Pendiente: push + marketplace; P4 opcional.

## Veredicto: VIABLE, y ya probado en vivo (2026-11-20)

Test ejecutado (revertido después, sin efectos residuales): symlink de fondo apuntando
al mp4 del tema katana con el plugin v0.7.1 activo →

- owed tomó la capa: `engine: renderer`, y en el log: **`shell background disabled`** —
  su `setPluginEnabled("omarchy.background")` resolvió el alias hacia TU plugin y lo
  desactivó limpiamente. No hubo doble capa ni pantalla negra.
- Decodificación **VAAPI** (`hwdec: vaapi`), loop sin costura vía EDL
  (`Loop plays as 256 copies of 25.200 s`), crossfade desde el still anterior
  (`transition from ...robot-girl...png`), opaque region on.
- Al volver el symlink al png: `engine: shell`, `shell background enabled`,
  `renderer parked`. Handoff bidireccional perfecto.

### Aclaración de arquitectura (recuerdo del usuario matizado con evidencia)

Realmente hay **un plugin + un tema**, no dos plugins:
- **Tema companion** `p3lusa/video-wallpaper` (repo padre en `~/Projects/video-wallpaper`):
  los temas `video-<clip>` (paleta `colors.toml`, `backgrounds/<stem>.png`, `videos/<stem>.mp4`).
- **Plugin** `io.github.p3lu.video-background` (repo hijo en `~/Projects/video-wallpaper/plugin`):
  dentro tiene las dos piezas que creías separadas:
  1. `Background.qml` — el renderizador QML (lo que "hace lo que OWE"): **esto es lo que se retira**.
  2. `bin/` — la gestión (TUI `video-manage.sh`, `video-theme.sh` que genera el tema por clip,
     ciclo next/prev, keybinds escritos en `~/.config/hypr/bindings.lua`): **esto se conserva intacto**.

### Arquitectura objetivo (v0.8)

```
TUI/ciclo/atajos (plugin, sin cambios de concepto)
   └─ video-theme.sh: omarchy theme set video-<clip>   → paleta/colores (OWE no toca paleta)
   └─ symlink current/background → videos/<stem>.mp4   → owed lo ve por inotify y pinta
      (png emparejado se queda en backgrounds/ como póster para picker/lock/batería)
```

El acoplamiento clip↔tema↔paleta sobrevive tal cual: owed nunca interviene en
temas/paleta, solo en la capa visual. Bonus gratis: el picker nativo de 4.5
(Super+Ctrl+W) ya lista vídeos con miniaturas.

## Fases

### P0 — Higiene (≈30 min)
1. Sync instalado→dev: commit `5fd9a55` (pósters por extensión) + los 3 bin divergentes
   (`video-add.sh`, `video-manage.sh`, `video-remove.sh`) al dev-tree.
2. Limpiar basura del dev-tree (`II\,d[...`, `*_REPORT.md`, `test_*.sh` sueltos → `tests/`).
3. Decidir push (todo quedó sin pushear a propósito).

### P1 — v0.8.0: cambiar el backend (≈2 tardes) ← el corazón
1. **Scripts**: donde hoy se enlaza/usa el png como background, enlazar el **mp4**
   (directo con `ln -nsf` — owed vigila el symlink; o `owe set <clip>` que valida y hace
   lo mismo). Afecta a `video-next/prev/cycle/switcher/theme` y al flujo `add`.
   El png emparejado NO desaparece: sigue en `backgrounds/` como póster (thumbnail,
   lock, modo batería poster).
2. **Retirar el servicio QML**: quitar `kinds: ["service"]` + `Background.qml` + `entryPoints`
   del manifest (precedente: `io.github.p3lu.wg-omarchy-nmcli` funciona sin service;
   los keybinds viven en bindings.lua, no dependen del QML). Si el schema rechaza un
   manifest sin entryPoints → dejar un service fino que sea copia del stock nuevo.
3. **post-update hook**: eliminar la lógica que deshabilita `omarchy.background` y
   habilita el plugin (ahora el stock es el servicio correcto); quitar la aplicación
   de `video-hwaccel.sh` (mpv `hwdec=auto-safe` → VAAPI en tu AMD, mejor que el drop-in
   `QT_FFMPEG_*`). Borrar el drop-in systemd残留 si existe.
4. **Matriz de verificación**: vídeo/still × lock × fullscreen × batería × restart shell
   × `omarchy update`; comprobar handoffs con `owe status` y journal de owed.
5. Tag v0.8.0, changelog, README actualizado (quitar sección hwaccel/motor propio).

### P2 — Paridad de superficie en el TUI (≈2-3 tardes)
1. `video-status`: pasar `owe status|config|render-status` (JSON → legible): engine,
   reason de pausa, hwdec, failed_path.
2. Teclas TUI/atajos: `owe pause` / `owe resume` / `owe always-animate on|off`
   (policies completas de OWE ya activas: fullscreen, DPMS, idle, sleep…).
3. **Formatos**: aceptar en add/TUI `mp4 mkv webm mov avi mpeg ts wmv flv ogv 3gp gif`
   (mpv los decodifica todos; hoy el flujo impone mp4).
4. **Clip sin póster obligatorio**: generar `ffmpeg -vframes 1 → webp` a `backgrounds/`
   al añadir (equivalente al poster extraction de OWE; mantiene picker/lock bonitos).
5. **Config OWE desde el TUI**: escribir `~/.config/owe/config.toml` con toggles
   (ojo: por defecto `battery_mode = "play"` — sigue decodificando en batería;
   recomendar `poster` en laptops) y `blocklist` de procesos.
6. Nota audio: clips actuales todos sin pista de audio (verificado con ffprobe);
   los nuevos con audio sonarían (OWE no muta el loop normal) → advertir en `add`
   o re-codificar sin audio.

### P3 — Intros de tema (≈1 tarde)
- El `owed.service` ya arranca con `--prepare-intro "$(...omarchy-theme-bg-boot-intro --resolve-startup)"`:
  mirar qué resuelve ese helper de Omarchy y exponer en el TUI "marcar clip como intro del tema".
- Considerar `omarchy hook install theme-set /usr/share/owe/10-owe-sync` (hoy no está
  instalado; owed ya vigila el symlink, pero da resync inmediato al cambiar tema).

### P4 — Fallback para máquinas sin OWE (opcional, solo si se publica)
- Conservar rama `legacy-qml` con el motor v0.7 (rebaseado sobre el stock NUEVO de 4.5,
  que ya trae el contrato OWE: `suspended`/`setSuspended`/`isVideo` — el fork actual
  está sobre el stock viejo, 525 líneas de diff).
- El TUI detecta la ausencia del socket `$XDG_RUNTIME_DIR/owe/owed.sock` y ofrece el modo legacy.

## Riesgos y mitigaciones
- **Picker nativo desincroniza**: Super+Ctrl+W puede poner un vídeo sin cambiar de tema
  → paleta desparejada. Mitigación: comando TUI `re-sync` (detecta basename del symlink
  ≠ tema activo y re-aplica `video-theme.sh`), o simplemente documentarlo.
- **owed es experimental** y se actualiza solo (0.2.14 hoy; `loops/<stem>.mp4` es del
  branch main, aún NO en el 0.2.14 instalado — no depender de esa convención).
- **Dos escritores del symlink**: dejar los scripts del plugin como únicos escritores.
- Si OWE se rompe en una update: el png sigue en `backgrounds/`; un `ln -nsf` al png
  devuelve el modo estático en 1 segundo.

## Publicación (v0.8 = "OWE wallpaper manager")

Decisiones de forma acordadas 2026-11-20:
- **Se mantiene el MISMO plugin** (id `io.github.p3lu.video-background`), no hay plugin nuevo:
  la gestión de temas vive en `bin/video-theme.sh`, no en el QML retirado.
- Relación con OWE: plugin = manager/frontend de un servicio del sistema (owed), no plugin-sobre-plugin.
- **Dependencia externa**: el schema `schemaVersion: 1` no tiene campo `dependencies`;
  precedente `crmne.hyprmoncfg` usa clave propia → añadir
  `"owe": {"package": "owe", "minimumVersion": "0.2.14"}` al manifest + detección runtime
  (socket `$XDG_RUNTIME_DIR/owe/owed.sock`) + prerequisito en README (`omarchy pkg add owe`).
- "Tema solo" descartado: sin el plugin no hay acoplamiento clip↔paleta, y la convención
  `loops/<stem>.mp4` de tema-solo no existe en owe 0.2.14.
- Canales: plugin → marketplace Omarchy (precedente issue #7401); tema companion →
  omarchy-site (loop de review omabot conocido); OWE queda como upstream ajeno.
- Pitch del listing: gestor de fondo de vídeo sobre OWE — librería TUI, un tema por clip
  (paleta sincronizada), ciclo instantáneo. Cosas que OWE no tiene y venden.
- Pendiente técnico menor: probar si el registry acepta plugin con cero entrypoints
  (solo scripts/bin); si no, dejar un `service` mínimo vacío.

## Referencias
- Test en vivo: journal owed 2026-11-20 16:02 (`shell background disabled` → `engine: renderer` → revert OK).
- Upstream: github.com/omacom/owe (README + docs/architecture.md leídos enteros; 0.2.14 instalado).
- Shell: `/usr/share/omarchy/shell/shell.qml:919,1774,1815`; stock nuevo:
  `/usr/share/omarchy/shell/plugins/background/Background.qml` (contrato OWE, 532 líneas).
