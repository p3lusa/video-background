# TUI — mejoras y bugs (lista reutilizable)

> Reutilizable si se interrumpe el proceso. Marca `[x]` lo hecho.
> Archivo vivo a modificar: `~/.config/omarchy/plugins/io.github.p3lu.video-background/bin/video-manage.sh`
> (el instalado = el que se ejecuta). Dev tree: `~/Projects/video-wallpaper/plugin`.
> Sin push. Sync installed→dev al terminar.
>
> Herramientas: gum 2.0.0 (confirm = prompt posicional), fzf 0.74.3 (sin acción `redraw` en --bind).
> Aether: `aether --generate <poster> --no-apply --output <dir>` (re-extrae paleta sin aplicar).

## Decisiones / preguntas (telegram)
- [ ] **P6** — Explicar al usuario la diferencia `[own palette]` vs `[library]` y que decida
      (¿cada clip con su propia paleta, o paleta de biblioteca compartida?).
      - own: el clip tiene su propio tema per-clip (`video-<name>`); al reproducir activa SU paleta (extraída de Aether del clip).
      - library: el clip vive solo en el tema compartido `video-wallpaper`; reproduce con la paleta neón de la skin.

## Mejoras
- [ ] **M1. Selección simultánea al añadir** — navegador multi-select (fzf `--multi`); seleccionar varios vídeos y añadirlos en bloque.
- [ ] **M2. Carga masiva de una carpeta** — al seleccionar/entrar a una carpeta, ofrecer "añadir todos los N vídeos de esta carpeta".
- [ ] **M3. Anti-duplicados** — dedup independiente del orden en `scan_library` (2 pases: marcar claims, luego emitir) + idempotencia en `video-add.sh` (ya existe) + limpieza de dups existentes.
- [ ] **M4. Abrir Aether para editar paleta** — acción nueva: re-extraer paleta del clip (Aether) y/o abrir `colors.toml` en el editor; re-aplicar tema.

## Bugs
- [ ] **P1. Duplicado en el menú (yorha)** — `scan_library` emite el clip de la librería (`lib`) ANTES de que el per-clip lo reclame (orden alfabético: `video-wallpaper` < `video-yorha-*`). Fix = M3 (dedup 2 pases). Ya confirmado: yorha sale 2x (lib + own).
- [ ] **P2. Vídeo recién añadido queda estático** — `do_play` hace `omarchy theme bg set <VIDEO.mp4>` (el "background" pasa a ser el .mp4, rompiendo el fallback de imagen y la derivación por base-name). Fix: setear el background al **poster PNG** (`backgrounds/<base>.png`); el QML deriva el vídeo por base-name. Confirmar con probe.
- [ ] **P3. Miniatura persiste al entrar en "añadir"** — el gráfico kitty del preview no se limpia al abrir el navegador. Fix: `clear_graphics()` al inicio de `browser_preview`.
- [ ] **P4. Miniatura no se adapta a la pantalla** — solo limita por ancho; puede desbordar la altura del preview. Fix: acotar `rows` a la altura disponible (tput lines) y escalar `w` en proporción.
- [ ] **P5. Miniatura persiste en "how to use / add / remove"** — mismo origen que P3 (gráfico kitty no limpiado). Fix: `clear_graphics()` al inicio de `preview_cmd`.
- [ ] **P6. Explicar own vs library** — ver sección Decisiones.
- [ ] **P7. Tecla `r` debe ir directo a confirmar el borrado del clip actual** — ahora abre el picker. Fix: bind `r` captura el item destacado (fzf pasa la línea a stdin de `execute-silent`); si es un clip, `do_remove` directo (con confirmación); si no, picker.

## Verificación final
- [ ] `bash -n` en video-manage.sh (y video-add.sh).
- [ ] Tests PTY: multi-select añade en bloque; bulk de carpeta; yorha NO duplicado;
      play de clip recién añadido arranca; preview limpio en acciones; miniatura acotada a altura.
- [ ] Sync instalado → dev tree + fast-forward clone redundante (SIN push).
- [ ] Actualizar memoria (mnemosyne) con las decisiones y fixes.
- [ ] Avisar por Telegram al terminar.
