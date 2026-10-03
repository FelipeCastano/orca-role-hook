# Decisiones de diseño

Registro de las decisiones tomadas en la revisión del 2 de octubre de 2026 y de los cambios que las implementan. Cada entrada dice qué se decidió, por qué, y qué toca en el repo. Cuando algo no se pudo verificar, se dice.

## 1. La configuración es la única fuente de verdad

**Decisión.** Los roles se activan y desactivan solo con `enabled` en `~/.orca-roles/config.json` (o en el `.orca-roles.json` del proyecto). Se eliminaron los atajos `--roles` y `--list` del instalador.

**Por qué.** Dos formas de hacer lo mismo acaban desincronizadas y hay que documentar ambas. Un solo archivo, leído en cada arranque de worktree, es más fácil de razonar y de depurar (`orca-roles.config.json` en la carpeta git del worktree guarda la configuración efectiva).

**Cambios.** `install.sh` sin opciones (solo `--help`); `new-role.sh` reinstala sin `--list`; README reescrito en torno a `config.json`.

## 2. Un solo patrón para todos los prompts, sin archivos de método aparte

**Decisión.** Los siete prompts siguen la misma estructura: `# Rol`, misión, `## Cuando recibas una tarea`, `## Límites`, `## Parámetros`, `## Método ...` (solo quien lo aplica), `## Reporte` y cierre «responde solo "X listo"». La carpeta `prompts/metodos/` desapareció: el método de revisión de código vive dentro de `auditor.md` y el de revisión de planes dentro de `planner.md`.

**Por qué.** Un patrón único hace predecible qué espera cada rol y permite que `nuevo-rol` genere prompts coherentes. Fundir los métodos en el prompt elimina las rutas absolutas a `~/.orca-roles/prompts/metodos/` y la dependencia de que el agente pueda leer un segundo archivo. El Auditor y el Planner releen su propio prompt antes de cada revisión; su ruta ya viene en el mensaje de arranque.

**Cambios.** Reescritos los ocho archivos de `prompts/`; `new-role.sh` genera el mismo esqueleto en sus tres modos y avisa si un archivo copiado no tiene `## Reporte`; el smoke test comprueba las secciones de cada prompt.

## 3. `jq` es requisito duro; Claude Code se comprueba, no se exige

**Decisión.** Sin `jq` el instalador y `launch.sh` fallan con un mensaje claro. `orca` y `claude` siguen siendo avisos. El instalador comprueba que Claude Code ofrece `--permission-mode auto` y avisa si no.

**Por qué.** Todo el kit lee la configuración con `jq`; avisar y luego fallar dos líneas después con un error críptico era peor que negarse. No se fija una versión mínima de Claude Code porque no la pude verificar: se comprueba la capacidad concreta que el kit necesita (verificado con Claude Code 2.1.287, cuyos modos son `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk` y `plan`; `default` en el kit significa «no pasar el flag»).

## 4. El cierre de la sesión extra del composer se acota por título

**Decisión.** Solo se envía `Esc` y `/exit` a una terminal ajena al equipo cuyo título coincide con la clave de Jira o con el nombre de la rama. Sin coincidencia no se toca nada y queda en el log.

**Por qué.** La versión anterior cerraba cualquier terminal ajena que apareciera en 180 segundos y cuyo título no pareciera un shell. Era la parte más arriesgada del kit. Orca nombra esa sesión con el ticket, así que el título es un criterio suficiente y mucho más seguro.

**Cambios.** `kickoff.sh`; `regex_escape` en `lib.sh` para que la rama no se interprete como expresión regular; limitación documentada en el README.

## 5. `custom` aplica `extraArgs`, entrecomilla y expone más placeholders

**Decisión.** En `agent: "custom"` se añaden los `extraArgs` al final del comando, los valores sustituidos se escapan con `printf %q`, y además de `{model}` y `{prompts}` existen `{prompt}` (archivo de prompt del rol) y `{mcp}` (ver punto 9).

**Por qué.** El README decía que `extraArgs` aplicaba a cualquier CLI, pero el código solo lo hacía en `claude` y `codex`. `{prompt}` hace falta porque los roles creados en modo local viven en `~/.orca-roles/roles/`, no en `prompts/`.

## 6. Validación automática

**Decisión.** `tests/smoke.sh` ejercita `lib.sh`, `agent.sh` y `clean.sh` sin tocar `~/.orca-roles`, usando un `HOME` temporal y binarios simulados (`orca`, `claude`, `codex`, `bash`) que registran los argumentos. Un workflow de GitHub Actions ejecuta shellcheck y el smoke en cada push.

**Por qué.** Un kit que otros instalan con `curl | bash` no debería depender de probarlo a mano. Para poder testear, la lógica de mensajes y de fusión de configuración se movió de los scripts a funciones de `lib.sh` (`planner_msg`, `worker_msg`, `upgrade_config`, `mcp_file`, `codex_mcp_overrides`, `clear_command`).

**Verificado** el 3 de octubre de 2026: shellcheck 0.9.0 pasa sin avisos (ver punto 12).

## 7. Retomar un workspace tras un reinicio

**Decisión.** Cuando `launch.sh` detecta que los handles guardados ya no responden, marca esos roles como «retomados» y el Planner arranca en modo retomar: recupera el Run con `run-use`, lee la lista de tareas y los últimos mensajes con `inbox`, abandona con `worker-abandon` los dispatches de pestañas muertas, revisa `git status`, `git diff` y el log, contrasta todo con los reportes de los workers y presenta un resumen. No reasigna nada hasta que el usuario confirma.

**Por qué.** El estado de orquestación persiste en Orca (comprobado: `run-list` muestra Runs de días anteriores) y el código está en el worktree. Lo único que se pierde al apagar es la conversación de los agentes. Reconstruir el estado desde Orca y git es agnóstico del agente y no depende de que la sesión anterior exista.

**Alternativa descartada por ahora.** Reanudar las sesiones de Claude Code con `--session-id` al crear y `--resume` después. Recuperaría la conversación entera del Planner, pero solo para `claude`. Queda anotada como mejora en el README.

**Cambios.** `launch.sh` (detección y log «Retomando workspace»), `kickoff.sh` (quinto argumento), `planner_msg` (variante de retomar), sección «Retomar un workspace tras un reinicio» en `planner.md`, el Deployer limpia un pid obsoleto, sección «Reanudar tras reiniciar» en el README.

## 8. Limpieza de contexto de los workers, siempre con confirmación

**Decisión.** El Planner puede limpiar el contexto de los workers, al cerrar un paso (si `settings.cleanWorkersAfterStep` está activo) o cuando el usuario lo pide. Antes explica qué va a hacer y qué se pierde, excluye a los workers con tarea en vuelo y espera un sí explícito. Si el usuario dice «siempre», lo recuerda durante la sesión. Nunca se limpia a sí mismo.

**Por qué.** Cada tarea llega con su spec completa, así que la memoria de tareas anteriores no aporta y un contexto largo encarece y degrada. Pero `/clear` borra también el prompt del rol: la limpieza tiene que reenviarlo. Por eso se hace con un script del kit (`bin/clean.sh`) y no con comandos a mano, y es la única excepción a la regla del Planner de no usar `orca terminal send`.

**Detalles.** `clean.sh` acepta identificador, título o handle, y `--all`; comprueba que la pestaña vive, envía el comando de conversación nueva, espera a `tui-idle` y reenvía el mismo mensaje de rol que usa el kickoff (`worker_msg`, compartido para que no diverjan). El comando se toma del campo de rol `clearCommand`, con `/clear` por defecto en `claude` y `/new` en `codex`; en `custom` hay que definirlo.

**No verificado.** El `/new` de Codex se puso por conocimiento de su CLI, sin instalación disponible.

## 9. MCP para cualquier agente

**Decisión.** `mcpServers` define los servidores una vez y `mcp` elige cuáles carga cada rol, sea cual sea su agente. El kit genera por rol un archivo `{"mcpServers": {...}}` y lo entrega según el agente: `--mcp-config` en `claude`; overrides `-c mcp_servers.<nombre>.<campo>=<valor TOML>` en `codex`; placeholder `{mcp}` y variable `ORCA_ROLES_MCP` en `custom`. `"all"` significa en todos los casos «usa la configuración propia del agente».

**Por qué.** Con MCP solo en Claude, el Planner (que necesita Jira) y el Visual-Tester (Playwright) estaban atados a Claude de facto. El formato `mcpServers` es el que leen también Cursor y Gemini CLI, así que es el mejor denominador común. Se añadió `atlassian` (MCP remoto oficial, OAuth en el agente) a los servidores de serie para que mover el Planner a otro agente sea cuestión de listar `["atlassian", "context7"]`. El Planner por defecto sigue en `"all"` porque con Claude Code eso carga los conectores ya autorizados del usuario.

**No verificado.** El mapeo a `-c` de Codex y el soporte de `url` en sus servidores MCP; no hay Codex instalado. Está marcado así en el README, con `extraArgs` o `config.toml` como vía de escape.

## 10. Prueba visual con Playwright headless y sesión del usuario

**Decisión.** El Visual-Tester sigue usando el MCP de Playwright (nunca el navegador embebido de Orca), ahora configurado `--headless --isolated --storage-state {browserState} --output-dir {worktree}/{evidenceDir}`. La sesión la aporta el usuario una vez con `bin/browser-login.sh <url>`, que abre un Chromium visible y guarda cookies y localStorage en `~/.orca-roles/browser/<proyecto>.json`. Los `args`, `env` y `url` de `mcpServers` admiten placeholders (`{worktree}`, `{project}`, `{evidenceDir}`, `{browserState}`, `{kit}`, `{home}`) que `agent.sh` expande al generar el archivo MCP del rol. El Deployer pasa de «la API» a «la aplicación y sus servicios», con un pid y un log por servicio.

**Por qué.** La experiencia previa del usuario con el navegador de Orca tenía dos problemas de fondo: las capturas fallaban si el panel no estaba visible («tab may not be visible»), lo que le impedía trabajar en otra cosa, y los clics sobre elementos fuera de la vista caían fuera. Playwright captura por CDP (sin depender de la visibilidad) y espera accionabilidad antes de pulsar, así que ambos desaparecen. Headless por defecto garantiza que no haya ventana que atender. Lo que el navegador de Orca sí aportaba era la sesión de Entra con MFA en un perfil persistente; `--storage-state` la sustituye, y `--isolated` evita que dos worktrees se peleen por el bloqueo de un perfil en disco. El hook sobre XHR para ver cuerpos de red, que ya funcionó, se mantiene como técnica documentada en el prompt (vía `browser_evaluate`).

**Alternativa descartada.** `--user-data-dir` con un perfil persistente: más parecido a lo que hacía Orca, pero un perfil de Chromium no admite dos procesos a la vez y acumula estado entre pruebas.

**No verificado.** Que la sesión de la aplicación concreta del usuario sobreviva en `storage-state` depende de que sus tokens estén en cookies o `localStorage` (MSAL por defecto usa `sessionStorage`, configurable a `localStorage`), y de la caducidad del refresh token de Entra. Hay que probarlo con la SPA real. También está pendiente comprobar que `browser_take_screenshot` con `filename` con subcarpeta resuelve relativo a `--output-dir` en la versión actual del MCP; el prompt pide al agente verificar con `ls` y mover si hace falta.

## 11. Publicación pendiente

**Decisión.** El placeholder `OWNER/orca-roles` se mantiene en `install.sh` y en el README hasta que exista el repositorio en GitHub. Los scripts ya tienen permiso de ejecución. El bloque «Publicar el repo» del README tiene los comandos.

## 12. Revisión del 3 de octubre de 2026: Jira, cierre del composer y portabilidad

**Decisión.** La clave de Jira se lee de `linkedWorkItem.jiraIdentifier`, que Orca guarda al crear un worktree desde un ticket (tipo `WorkspaceLinkedItem` en `src/shared/worktree/types.ts` de Orca; el setup script solo recibe `ORCA_ROOT_PATH`, `ORCA_WORKTREE_PATH` y `ORCA_WORKSPACE_NAME`, ninguna con el ticket). Antes se buscaba una URL de `atlassian.net`, que no existe en Jira Server o Data Center. Sin enlace, se toma de la rama solo si abre la rama o uno de sus segmentos y está en mayúsculas. La sesión extra del composer solo se cierra si su título es exactamente la rama o empieza por la clave seguida de un separador. `.orca-roles.json` se busca también en el checkout principal. El archivo MCP de cada rol va a la carpeta git del worktree (`orca-roles-mcp-<rol>.json`) en lugar de un temporal nuevo en cada arranque.

**Por qué.** La expresión anterior convertía `feature/fix-123` en `FIX-123` y `release-1.4` en `RELEASE-1`: el Planner buscaba tickets inexistentes y esa clave falsa entraba en el criterio de cierre. Además, el título se comparaba como subcadena, así que con una rama `api` se cerraría cualquier terminal ajena con «api» en el título, justo lo que el punto 4 quería evitar. Un `.orca-roles.json` sin commitear no llegaba a los worktrees nuevos. Los temporales MCP se acumulaban.

**Portabilidad.** Se corrigieron dos expansiones de listas vacías (`codex` sin argumentos y `clean.sh --all` sin workers) que fallan con `set -u` en bash 3.2, el de macOS; el instalador elige `~/.bash_profile` para bash en macOS y `~/.profile` para otros shells; los mensajes indican cómo instalar `jq` en macOS y en Ubuntu; el bloque de publicación del README usa `perl -pi` en lugar de `sed -i ''`, que solo funciona en macOS; el Deployer tiene `ss -ltn` como alternativa a `lsof`.

**Verificado (Jira)** con Orca 1.4.219 en Windows/WSL: `orca worktree show --json` devuelve `result.worktree.linkedWorkItem` (null en worktrees sin enlace). No había ningún worktree enlazado a Jira, así que la forma del objeto relleno (`provider`, `jiraIdentifier`, `url`) se tomó del tipo `WorkspaceLinkedItem` del código fuente.

**Verificado.** shellcheck 0.9.0 sin avisos y smoke test completo en Ubuntu (WSL2) con bash 5.2 y jq 1.7. **No verificado:** ejecución en un Mac real con bash 3.2 (los tests de listas vacías pasan también en bash 5, así que en Linux no detectan la regresión), el formato exacto del título que Orca da a la sesión del composer y el funcionamiento en Windows/WSL con Orca.

## 13. Windows con WSL2 y el nombre del CLI de Orca

**Decisión.** Windows se soporta a través de WSL2, no con una versión nativa. Cuando `orca` no está en el PATH pero Orca indica otro nombre en `ORCA_CLI_COMMAND`, `lib.sh` crea `~/.orca-roles/shim/orca` (un `exec "$ORCA_CLI_COMMAND" "$@"`) y lo antepone al PATH. `launch.sh` falla con un mensaje claro si no encuentra ningún CLI de Orca. Se añade `.github/workflows/ci.yml`: shellcheck en Ubuntu y smoke test en Ubuntu y en macOS con el bash 3.2 del sistema.

**Por qué.** En Orca 1.4.219 para Windows, las terminales de WSL no tienen `orca`: tienen `orca-ide` (`$ORCA_CLI_COMMAND`, en `$ORCA_WSL_CLI_DIR`), un lanzador que pasa por PowerShell a `orca.exe`. El código fuente de Orca muestra también `orca-dev`, así que el nombre no es fijo. Sin el envoltorio no funcionaba ningún script del kit ni ninguna llamada `orca orchestration` de los agentes. Con él no hay que tocar prompts, permisos ni mensajes, y en macOS o Linux, donde existe `orca`, no hace nada. Portar a PowerShell supondría reescribir ~1.300 líneas y mantener dos versiones; Git Bash exigiría reescribir el comando de cada pestaña y traducir rutas, sin poder probarlo. Orca ya ejecuta terminales y setup script dentro de WSL cuando el repo vive ahí.

**Verificado** en Orca 1.4.219 sobre WSL2/Ubuntu: `ORCA_CLI_COMMAND=orca-ide`; el envoltorio responde (`orca terminal show` → `ok: true`); funcionan `terminal list`, `terminal show`, `worktree show`, `worktree list` y `orchestration`; `repo hooks` no existe (en ninguna versión; ver punto 14).

**No verificado.** Que el setup script reciba `ORCA_CLI_COMMAND` (lo necesita `launch.sh`); un arranque completo de equipo en WSL; el workflow de CI hasta el primer push.

## 14. Registrar el kit en un proyecto: Settings o `roles-yaml`

**Decisión.** `apply-hooks.sh` ya no intenta `orca repo hooks set`: solo explica las dos vías. La nueva es `bin/orca-yaml.sh` (comando `roles-yaml`), que crea en la raíz del checkout principal un `orca.yaml` con `scripts.setup: $HOME/.orca-roles/bin/launch.sh`, lo lista en `.worktreeinclude` y añade ambos a `.git/info/exclude`. Nunca modifica un `orca.yaml` o un `.worktreeinclude` commiteados ni un `orca.yaml` ajeno: en esos casos dice qué línea añadir. `roles-yaml --remove` lo deshace.

**Por qué.** `orca repo hooks` no existe en ninguna versión de Orca (el CLI de `repo` solo tiene `list`, `add`, `show`, `set`, `set-base-ref` y `search-refs`; hay una petición abierta, stablyai/orca#21584). El kit lo daba por hecho sin haberlo verificado. Según el código de Orca, el setup script sale del `orca.yaml` del worktree nuevo o de la configuración local de Settings, que vive en los archivos internos de Orca; editarlos no está soportado y Orca los reescribe mientras está abierto. Un `orca.yaml` commiteado lo verían los compañeros y habría que commitearlo en cada proyecto. Ignorado, en cambio, no llegaría a los worktrees nuevos, salvo por `.worktreeinclude`: Orca lo lee del checkout principal y copia al worktree nuevo los archivos listados que `git check-ignore` da por ignorados (lo que incluye `.git/info/exclude`), y lo hace al materializar el worktree, antes de `prepareRuntimeLocalWorktreeSetup`, que es donde busca el setup script. Se usa `.git/info/exclude` y no `.gitignore` porque `.gitignore` suele estar commiteado y tocarlo dejaría un cambio pendiente.

**Detalles.** Por defecto Orca ejecuta el setup sin preguntar (`setupRunPolicy: run-by-default`). Si el repo tiene un setup script local en Settings y no se eligió política, Orca usa solo ese (`local-only`) e ignora `orca.yaml`; está documentado. `orca.yaml` lo lee la librería `yaml`, así que el bloque `setup: |` es válido.

**Verificado.** `roles-yaml` en repos de prueba: crea los archivos, `git status` queda vacío, `git check-ignore` los da por ignorados, es idempotente y `--remove` lo deja todo como estaba. El comportamiento de Orca (`.worktreeinclude`, orden de copia, política de origen) se tomó de su código fuente (rama main del 3 de octubre de 2026). **No verificado:** creando un worktree de verdad en Orca, y si Orca pide confirmar la primera vez que ejecuta el setup de un `orca.yaml`.

## Principios que atraviesan todo

- **Nada escrito es evidencia.** Es la regla madre de los métodos de revisión y también de este registro: lo que no se pudo ejecutar se marca como no verificado.
- **Agnóstico del agente por defecto.** La comunicación pasa por Orca (terminales y `orca orchestration`), así que el kit evita depender de Claude salvo donde Claude ofrece algo que otros no (permisos, `--add-dir`, diálogo de confianza).
- **El Planner pide confirmación antes de actuar sobre el equipo** (plan, limpieza, reasignación tras reinicio) y los workers nunca hablan con el usuario.
- **Todo lo que se pueda testear sin Orca real, se testea** con binarios simulados; lo que no, se documenta como no verificado.
