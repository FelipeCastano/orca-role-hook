# orca-roles

Kit para [Orca](https://github.com/stablyai/orca) que abre automáticamente un equipo de agentes con roles definidos en cada worktree nuevo y los coordina mediante **Orca Orchestration**. Tú solo hablas con el Planner; el resto del equipo recibe todo su trabajo de él.

Toda la configuración (qué roles están activos, con qué modelo, agente, MCP y parámetros) vive en un único archivo: `~/.orca-roles/config.json`. Ver [Configuración](#configuración).

## Roles

Por defecto:

| Pestaña | Modelo | MCP | Rol |
|---|---|---|---|
| **Planner** | Opus 5.5 | Todos los tuyos (incl. Jira) | Único agente que habla contigo. Planifica por pasos, audita su plan con su método de revisión de planes antes de presentártelo, reparte el trabajo, supervisa y te reporta. |
| **Researcher** | Opus 5.5 | context7 | PoC, métricas, rendimiento, carga y capacidad. Trabaja en `research/`. |
| **Dev** | Sonnet 5.5 | context7 | Implementa el código de producción. |
| **Tester** | Sonnet 5.5 | Ninguno | No revisa: implementa y ejecuta los tests, con límites de cantidad, paralelismo y tiempo, y limpieza obligatoria al terminar. |
| **Auditor** | Opus 5.5 | Ninguno | Revisa el código de Dev y los tests del Tester con su método de revisión de código (incluye mutación, siempre en una copia temporal). |
| **Visual-Tester** | Opus 5.5 | Playwright | Propone un plan de prueba visual de la aplicación (front o API) y, tras aprobarlo tú, lo ejecuta en un navegador headless con tu sesión, con capturas en los puntos clave. |
| **Deployer** | Sonnet 5.5 | Ninguno | Levanta y para la aplicación en local (API, front y servicios necesarios) cuando se lo piden, y mantiene `DESPLIEGUE.md` con el paso a paso para dev y pro. Nunca despliega. |

Todos arrancan en **auto mode**. Los workers saben que todo su trabajo llega del Planner y comparten reglas comunes (`prompts/comun-workers.md`): no crear worktrees ni terminales, no tocar git fuera de su worktree, no hacer push y limpiar lo que lancen.

### Estructura de los prompts

Todos los prompts de rol siguen el mismo patrón, en este orden:

1. `# Rol: NOMBRE` y la misión en una o dos frases.
2. `## Cuando recibas una tarea`: pasos numerados (si el rol tiene varios tipos de tarea, una subsección por tipo).
3. `## Límites`: qué no debe hacer.
4. `## Parámetros`: los que recibe de `config.json` y su valor por defecto (o «Ninguno»).
5. `## Método ...` (solo cuando el rol aplica uno: el Auditor y el Planner).
6. `## Reporte`: formato exacto del `worker_done`.
7. Cierre: «Ahora responde solo "X listo" y espera tareas».

El Planner es la excepción parcial: no es worker, así que sus secciones son Arranque, Equipo, Fase 1, Mecánica, Fase 2, Límites, Parámetros, Método de revisión de planes y Reporte al usuario. Los métodos de revisión viven dentro del prompt del rol que los aplica, no en archivos aparte: el Auditor y el Planner releen su propio prompt antes de cada revisión.

## Flujo de cada paso

1. **Researcher** investiga si hay que decidir algo antes.
2. **Dev** implementa.
3. **Tester** implementa y ejecuta los tests. Si fallan por el código, Dev corrige.
4. **Auditor** revisa código y tests. Sus hallazgos van a Dev o al Tester según corresponda, y se repite hasta que acepta (con 3 rondas rechazadas, el Planner te consulta).
5. Si hace falta prueba visual: **Deployer** levanta la aplicación → **Visual-Tester** propone un plan → tú lo apruebas → **Visual-Tester** lo ejecuta → **Deployer** la para.
6. **Researcher** valida rendimiento o capacidad si hace falta.
7. **Deployer** actualiza `DESPLIEGUE.md`.
8. El **Planner** te reporta el paso.

Si un rol está desactivado en la configuración, el Planner salta su parte del flujo y te avisa cuando un paso la habría necesitado.

## Instalación

Clona el repo y ejecuta el instalador desde el clon:

```bash
git clone git@github.com:FelipeCastano/orca-role-hook.git && bash orca-role-hook/install.sh
```

Instala en `~/.orca-roles/`, crea tu `~/.orca-roles/config.json`, añade los comandos `roles`, `nuevo-rol` y `roles-yaml` a tu shell y te explica cómo registrar el kit en tus proyectos. **Para actualizar**, trae los cambios y repite el instalador: tu configuración se conserva (valores y orden de tus roles) y solo se le añaden las opciones nuevas.

```bash
git -C orca-role-hook pull && bash orca-role-hook/install.sh
```

Si el repo fuera público, también se podría instalar sin clonar (de momento es privado y GitHub no sirve sus archivos sin autenticación):

```bash
curl -fsSL https://raw.githubusercontent.com/FelipeCastano/orca-role-hook/main/install.sh | bash
```

El instalador no admite opciones: los roles se activan y desactivan con `enabled` en `config.json` (ver [Configuración](#configuración)).

La primera vez que el Visual-Tester use el navegador, puede hacer falta `npx playwright install chromium`.

## Configurar un proyecto (una vez por proyecto)

**Add Project → Browse folder**, eligiendo la raíz del repo (la carpeta con `.git`), no un worktree. Después, registra el kit como setup script del proyecto por una de estas dos vías. El CLI de Orca no tiene ningún comando para los setup scripts, así que el instalador no puede hacerlo por ti.

**a) En Settings.** **Settings → Repository → *tu proyecto* → Setup script**:
```
$HOME/.orca-roles/bin/launch.sh
npm install
```
La segunda línea es opcional. Deja `launch.sh` primero y **Run setup command** activado.

**b) Con `roles-yaml`.** En una terminal dentro del proyecto (en cualquier worktree o en el checkout principal):
```bash
roles-yaml            # para deshacerlo: roles-yaml --remove
```
Crea en la raíz del checkout principal un `orca.yaml` con el setup script y lo lista en `.worktreeinclude`. Los dos quedan ignorados en `.git/info/exclude`, el equivalente local de `.gitignore`: no se toca el `.gitignore` del proyecto ni queda nada que commitear, y tus compañeros no ven nada. Funciona porque Orca copia a cada worktree nuevo los archivos ignorados que lista `.worktreeinclude`, antes de buscar su setup script. Solo afecta a los worktrees que crees a partir de ahora.

- Si el proyecto ya tiene un `orca.yaml` o un `.worktreeinclude` commiteados, `roles-yaml` no los modifica: te dice qué línea añadir. Usa la vía a) si no quieres tocarlos.
- Si el proyecto tiene además un setup script en Settings, Orca usa ese e ignora `orca.yaml` (salvo que en Settings elijas ejecutar ambos). Con `launch.sh` ya en Settings no necesitas `roles-yaml`.
- Los cambios en `orca.yaml` (por ejemplo, añadir `npm install`) se hacen en el del checkout principal; cada worktree nuevo recibe una copia.

## Uso

Crea un worktree desde el **"+"** del proyecto. En unos segundos tendrás las pestañas de tus roles y el Planner empezará a planificar contigo.

- **Desde un ticket de Jira:** el kit lee el ticket que Orca enlaza al worktree (`linkedWorkItem` en `orca worktree show`) y se lo pasa al Planner, que lo lee y planifica desde ahí. Si el worktree no está enlazado, lo intenta con la rama, pero solo cuando la clave en mayúsculas abre la rama o uno de sus segmentos (`DEVGD-220-nueva-api`, `feature/DEVGD-220`), para que `fix-123` o `release-1.4` no se tomen por tickets. La sesión que Orca crea por defecto con el nombre del ticket se interrumpe y se cierra sola.
- **Donde el hook no se ejecuta** (checkout principal, proyectos de carpeta, worktrees existentes): ejecuta `roles` en una terminal del workspace. No duplica pestañas abiertas.

## Prueba visual: navegador, sesión y capturas

El Visual-Tester no usa el navegador embebido de Orca: controla su propio Chromium mediante el MCP de Playwright. Las capturas se piden por protocolo, no son capturas de pantalla, así que salen aunque la ventana esté detrás o no exista. De serie el navegador es **headless**: puedes seguir trabajando mientras prueba.

**Sesión.** Si tu aplicación pide login (Entra, Google, MFA...), inícialo tú una vez:

```bash
~/.orca-roles/bin/browser-login.sh https://localhost:5173
```

Abre un navegador visible, esperas a que la aplicación cargue con tu sesión, cierras la ventana y la sesión (cookies y localStorage) queda guardada en `~/.orca-roles/browser/<proyecto>.json`. El Visual-Tester arranca con ella en modo aislado: nada se escribe en disco durante la prueba y varios worktrees pueden probar a la vez. Si la aplicación le pide login, el Visual-Tester no intenta autenticarse: avisa al Planner, que te pedirá ejecutar el comando y volverá a lanzar la tarea. La primera vez puede hacer falta `npx playwright install chromium`.

Depende de que tu aplicación guarde la sesión en cookies o `localStorage`; si la guarda en `sessionStorage`, no sobrevive. Los tokens caducan según tu proveedor de identidad: cuando el Visual-Tester vuelva a ver la pantalla de login, repite el comando.

**Capturas.** Van a `<evidenceDir>/paso-<N>/` del worktree (por defecto `qa-evidence/`, ignorada localmente por git) gracias a `--output-dir`. **Red.** Para validar payloads, el Visual-Tester inyecta un hook sobre XHR/fetch con `browser_evaluate` y lee los cuerpos desde la página; nunca registra cabeceras.

**Regresión.** Es validación exploratoria. El Visual-Tester reporta la secuencia exacta de pasos que ejecutó para que, si un flujo merece repetirse, el Planner se lo pase al Tester como test de Playwright.

Todo esto se configura en el servidor `playwright` de `mcpServers`; ver [placeholders](#placeholders-en-mcpservers) para quitar `--headless` o cambiar rutas.

## Limpiar el contexto de los workers

Cada worker acumula en su conversación todo lo que ha hecho. Al cerrar un paso ese contexto ya no sirve (cada tarea nueva llega con su spec completa) y un contexto largo encarece y degrada las respuestas. Limpiarlo abre una conversación nueva en el agente (`/clear` en Claude Code) y le reenvía su rol y sus parámetros, así que el worker vuelve a quedar «listo» como al arrancar.

- **Al cerrar cada paso**, el Planner te lo propone junto con el reporte (si `cleanWorkersAfterStep` está activado).
- **Cuando se lo pidas**, para los workers que digas o para todos.

En ambos casos el Planner primero explica qué va a hacer y qué se pierde, excluye a los workers con una tarea en vuelo y espera tu confirmación. Si le dices que lo haga siempre sin preguntar, lo recuerda durante la sesión. Nunca se limpia a sí mismo: su contexto es la memoria del plan.

Por debajo ejecuta `~/.orca-roles/bin/clean.sh <rol> [...]` (o `--all`), que también puedes lanzar tú desde una terminal del worktree. Acepta el identificador del rol, el título de la pestaña o el handle.

## Reanudar tras reiniciar

Si apagas el equipo o cierras Orca, las pestañas de los roles mueren, pero el estado no: las tareas, los mensajes y los Runs de Orca Orchestration persisten, y el código está en el worktree. Lo que se pierde es la memoria de conversación de cada agente.

Para retomar, ejecuta `roles` en una terminal del workspace (el hook no se dispara en worktrees existentes). El kit detecta que los handles guardados ya no responden, abre pestañas nuevas y arranca al Planner en **modo retomar**: antes de hablar contigo, recupera el Run con `run-use`, lee la lista de tareas y las últimas comunicaciones del equipo, cierra los dispatches que apuntaban a pestañas muertas, revisa `git status`, `git diff` y el log, y te presenta un resumen: qué se cerró, qué estaba en curso, qué preguntas quedaron sin responder y qué propone hacer. No reasigna nada hasta que confirmes.

Los workers vuelven limpios; no les hace falta memoria porque cada tarea les llega con su spec completa (es el mismo principio que la [limpieza de contexto](#limpiar-el-contexto-de-los-workers)). El Deployer detecta que la API anterior murió y la vuelve a levantar si se lo piden.

## Crear un rol nuevo

```bash
nuevo-rol                         # lo guarda en tu instalación
nuevo-rol --repo ~/ruta/orca-role-hook  # lo guarda en tu clon del repo, para versionarlo
```

El asistente te pregunta todo lo necesario y actualiza la configuración:

- **Identidad:** identificador, título de la pestaña y una **descripción** para el Planner (qué hace y cuándo usarlo). El Planner recibe esa descripción al arrancar y lo integra en el flujo.
- **Agente:** `claude`, `codex` o `custom` (con su comando), modelo exacto y modo de permisos.
- **MCP y herramientas** (con `claude`): qué servidores carga, con opción de definir servidores nuevos; herramientas permitidas y carpetas extra.
- **Otros:** argumentos extra, variables de entorno, parámetros del rol, posición de la pestaña y si queda activo.
- **Prompt:** generado a partir de unas preguntas (pasos, límites, contenido del reporte y si emite veredicto), copiado de un archivo tuyo, o escrito en tu editor (`$EDITOR`, `nano` por defecto). En los tres casos el resultado sigue la [estructura común de los prompts](#estructura-de-los-prompts); si copias un archivo que no la sigue, el asistente te avisa.

Antes de guardar te enseña un resumen. Guarda una copia de la configuración anterior (`.bak`).

| Modo | Prompt | Configuración |
|---|---|---|
| Local | `~/.orca-roles/roles/<id>.md` (no se borra al actualizar el kit) | `~/.orca-roles/config.json` |
| `--repo` | `prompts/<id>.md` del clon | `config.default.json` del clon; ofrece reinstalar y te recuerda hacer commit |

Todos los workers reciben además las reglas comunes de `prompts/comun-workers.md`. Para editar un rol más tarde, cambia su entrada en la configuración y su archivo de prompt, o vuelve a ejecutar `nuevo-rol` con el mismo identificador para sobrescribirlo.

## Configuración

Toda la configuración vive en `~/.orca-roles/config.json`. Se lee cada vez que se crea un worktree, así que no hace falta reinstalar tras editarla. Es la única fuente de verdad: no hay flags ni atajos que la sustituyan.

```json
{
  "settings": {
    "launchWaitSeconds": 15,
    "kickoffTimeoutSeconds": 180,
    "jiraHandoff": true,
    "closeComposerAgent": true,
    "composerAgentWindowSeconds": 180
  },
  "defaults": {
    "agent": "claude",
    "permissionMode": "auto",
    "mcp": [],
    "allowedTools": ["Bash(orca orchestration:*)", "Read"],
    "extraDirs": [], "extraArgs": [], "env": {}, "params": {}
  },
  "mcpServers": {
    "context7": { "type": "http", "url": "https://mcp.context7.com/mcp" },
    "playwright": { "command": "npx", "args": ["-y", "@playwright/mcp@latest"] }
  },
  "roles": {
    "dev": { "title": "Dev", "enabled": true, "model": "claude-sonnet-5-5", "mcp": ["context7"] },
    "tester": { "title": "Tester", "enabled": true, "model": "claude-sonnet-5-5",
                "params": { "maxNewTests": 10, "maxWorkers": 2, "timeoutMinutes": 10 } }
  }
}
```

### Activar y desactivar roles

Cambia `enabled` en el rol. El `planner` está siempre activo aunque pongas `false`. Para un solo proyecto, usa la [configuración por proyecto](#configuración-por-proyecto).

```json
"visual-tester": { "enabled": false }
```

### Opciones de cada rol

Cada rol hereda de `defaults` lo que no defina.

| Campo | Qué hace |
|---|---|
| `enabled` | Activa o desactiva el rol (el `planner` siempre está activo). |
| `title` | Nombre de la pestaña y del rol que ve el Planner. |
| `description` | Qué hace el rol y cuándo usarlo. El Planner la recibe al arrancar; imprescindible en roles creados por ti. |
| `prompt` | Archivo de instrucciones del rol (por defecto `prompts/<rol>.md`). Admite `~`. |
| `agent` | Qué CLI se lanza: `claude`, `codex` o `custom`. |
| `model` | Modelo exacto que se pasa al agente. |
| `permissionMode` | En `claude`, el `--permission-mode` (`auto`, `acceptEdits`, `manual`...). `default` significa no pasar el flag. En `codex`, `auto` equivale a `--full-auto`. |
| `mcp` | `"all"` para que el agente use su propia configuración de MCP (en `claude`, todos tus conectores), o una lista de nombres de `mcpServers` (`[]` = ninguno). Funciona con cualquier agente: ver [MCP en otros agentes](#mcp-en-otros-agentes). |
| `allowedTools` | Herramientas permitidas sin preguntar. Solo `claude`. |
| `extraDirs` | Carpetas extra a las que el agente puede acceder. Solo `claude`. |
| `extraArgs` | Argumentos adicionales, tal cual, para el CLI. En `custom` se añaden al final del comando. |
| `env` | Variables de entorno para ese agente (`defaults.env` y las del rol se mezclan). |
| `params` | Parámetros que se le pasan al rol en su mensaje de arranque (límites del Tester, `maxMutants` del Auditor, `evidenceDir` del Visual-Tester...). Cada prompt documenta los suyos y su valor por defecto. |
| `command` | Solo con `agent: "custom"`: comando a ejecutar. Admite `{model}`, `{prompts}`, `{prompt}` y `{mcp}`. |
| `clearCommand` | Comando que abre una conversación nueva en el agente, para la limpieza de contexto. Por defecto `/clear` en `claude` y `/new` en `codex`; en `custom` hay que definirlo o el rol no se limpia. |

El orden de las pestañas es el orden de los roles en el JSON.

### Usar otros agentes

```json
"dev":    { "agent": "codex", "model": "<modelo-de-codex>" },
"tester": { "agent": "custom", "command": "opencode --model {model}", "model": "<modelo>" }
```

Los roles reciben sus instrucciones igual que con Claude (el kit escribe en su terminal cuando están listos), así que funcionan con cualquier agente con interfaz de terminal que pueda leer archivos y ejecutar `orca orchestration`.

Con `agent: "custom"`:

- El `command` se ejecuta con `bash -lc`, es decir, en un shell de login con el PATH de tu perfil (nvm, brew, etc.).
- Placeholders: `{model}` → campo `model`; `{prompts}` → carpeta `~/.orca-roles/prompts`; `{prompt}` → ruta del archivo de prompt del rol (útil si el rol vive en `~/.orca-roles/roles/`); `{mcp}` → archivo con los servidores MCP del rol (vacío con `mcp: "all"`). Los valores se entrecomillan automáticamente.
- `extraArgs`, `env` y `mcp` sí se aplican. `permissionMode`, `allowedTools` y `extraDirs` no: son de Claude Code. Pasa lo equivalente en el propio `command` o con `extraArgs`.
- El agente tiene que poder leer `~/.orca-roles/prompts` (y `~/.orca-roles/roles` si usas roles propios) por su cuenta: nadie le pasa `--add-dir`.
- La aceptación del diálogo de confianza y el cierre de la sesión extra del composer buscan textos de Claude Code; con otro agente no se detectan, pero el arranque funciona igual.

### MCP en otros agentes

`mcpServers` define los servidores una sola vez y `mcp` elige cuáles carga cada rol, sea cual sea su agente. El kit genera por rol un archivo `{"mcpServers": {...}}` con los elegidos y se lo entrega a cada agente como ese agente sepa recibirlo:

| Agente | Cómo lo recibe |
|---|---|
| `claude` | `--strict-mcp-config --mcp-config <archivo>`. Con `"all"` no se pasa nada y Claude Code usa todos tus conectores. |
| `codex` | Un override `-c mcp_servers.<nombre>.<campo>=<valor>` por campo (`command`, `args`, `url`, `env`), sin tocar `~/.codex/config.toml`. Con `"all"` usa su configuración propia. **No verificado contra una instalación de Codex**: si tu versión no admite `url` o el formato cambia, usa `extraArgs` o su `config.toml`. |
| `custom` | El placeholder `{mcp}` en `command` y la variable `ORCA_ROLES_MCP` apuntan al archivo. El formato `mcpServers` es el que leen también Cursor y Gemini CLI; para un agente con otro formato, convierte el archivo en un script envoltorio. |

Con esto el Planner no está atado a Claude. De serie, `mcpServers` incluye `atlassian` (el MCP remoto oficial, `https://mcp.atlassian.com/v1/sse`, que pide OAuth en el agente la primera vez). El Planner por defecto usa `"all"` porque con Claude Code eso carga tus conectores ya autorizados; para llevarlo a otro agente, dale los servidores por nombre:

```json
"planner": { "agent": "codex", "model": "<modelo>", "mcp": ["atlassian", "context7"] }
```

El Visual-Tester sigue necesitando el servidor `playwright`, que es un proceso local (`npx @playwright/mcp`): funciona en cualquier agente que lo pueda arrancar.

### Placeholders en `mcpServers`

En `args`, `env` y `url` de cualquier servidor se expanden al arrancar cada rol:

| Placeholder | Valor |
|---|---|
| `{worktree}` | Ruta absoluta del worktree |
| `{project}` | Nombre de la carpeta del repo principal (no del worktree) |
| `{evidenceDir}` | `params.evidenceDir` del rol (o del Visual-Tester, o `qa-evidence`) |
| `{browserState}` | `~/.orca-roles/browser/{project}.json`, la sesión guardada por `browser-login.sh` (se crea vacía si no existe) |
| `{kit}`, `{home}` | `~/.orca-roles` y tu `$HOME` |

El servidor `playwright` de serie los usa así:

```json
"playwright": { "command": "npx", "args": ["-y", "@playwright/mcp@latest", "--headless", "--isolated",
                                          "--storage-state", "{browserState}", "--output-dir", "{worktree}/{evidenceDir}"] }
```

Para ver el navegador en un proyecto, quita `--headless` en su `.orca-roles.json` (las listas se sustituyen enteras, así que copia los demás args).

### Configuración por proyecto

Un `.orca-roles.json` en la raíz de un repo se mezcla encima de tu configuración global solo para ese proyecto. Se busca en la raíz del worktree y, si no está, en la del checkout principal, así que funciona aunque no lo commitees. Por ejemplo, para una librería sin API:

```json
{ "roles": { "visual-tester": { "enabled": false }, "deployer": { "enabled": false } } }
```

Los objetos se mezclan campo a campo; las listas se sustituyen enteras.

### Ajustes generales (`settings`)

| Campo | Qué hace |
|---|---|
| `launchWaitSeconds` | Máximo que espera el setup a que Orca tenga listo el worktree (sale antes si ya lo está). |
| `kickoffTimeoutSeconds` | Máximo que espera a que cada agente esté listo para recibir su rol. |
| `jiraHandoff` | Pasar al Planner el ticket de Jira del worktree. |
| `closeComposerAgent` | Cerrar la sesión extra que abre el composer de Orca. Solo se cierra una terminal ajena al equipo cuyo título es exactamente el nombre de la rama o empieza por la clave de Jira (`DEVGD-220`, `DEVGD-220: resumen`); si no hay ninguna, no se toca nada y queda anotado en el log. |
| `composerAgentWindowSeconds` | Durante cuánto tiempo se vigila esa sesión extra. |
| `cleanWorkersAfterStep` | Si el Planner propone limpiar el contexto de los workers al cerrar cada paso. Con `false` solo lo hace cuando se lo pides. |

## Archivos

```
orca-role-hook/                  # este repo → se instala en ~/.orca-roles/
├── install.sh
├── config.default.json          # configuración de serie (tu copia: ~/.orca-roles/config.json)
├── bin/
│   ├── launch.sh                # script de setup: abre las pestañas y guarda sus handles
│   ├── agent.sh                 # lanza el agente de un rol según la configuración
│   ├── kickoff.sh               # envía el rol a cada agente, pasa el Jira y cierra el agente extra
│   ├── clean.sh                 # limpia el contexto de los workers y les reenvía su rol
│   ├── browser-login.sh         # guarda tu sesión de la aplicación para el Visual-Tester
│   ├── new-role.sh              # asistente para crear roles (comando nuevo-rol)
│   ├── lib.sh                   # funciones compartidas
│   ├── orca-yaml.sh             # registra el kit en un proyecto con un orca.yaml local (comando roles-yaml)
│   └── apply-hooks.sh           # explica al instalar cómo registrar el kit en cada proyecto
├── prompts/
│   ├── comun-workers.md         # reglas comunes a todos los workers
│   └── <rol>.md                 # instrucciones de cada rol (con su método de revisión, si lo tiene)
├── decisions.md                 # registro de decisiones de diseño y qué no se pudo verificar
├── tests/
│   └── smoke.sh                 # pruebas de configuración, herencia, mezcla y actualización
└── .github/workflows/ci.yml     # shellcheck + smoke en cada push
```

Para cambiar el comportamiento de un rol, edita `prompts/<rol>.md` en el repo y vuelve a ejecutar el instalador. Lo que edites directamente en `~/.orca-roles/prompts/` se sobrescribe al actualizar; tu `config.json` y tus roles de `~/.orca-roles/roles/` no.

Dentro de cada worktree:

- `research/` y `qa-evidence/`: trabajo del Researcher y capturas del Visual-Tester. Se ignoran localmente en `.git/info/exclude`, sin tocar tu `.gitignore`.
- `DESPLIEGUE.md`: manual del Deployer. No se commitea salvo que lo pidas.
- En la carpeta git del worktree (`git rev-parse --git-dir`): `orca-roles.config.json` (configuración efectiva usada), `orca-roles-mcp-<rol>.json` (servidores MCP que recibió cada rol), `orca-roles.env` (handles), `orca-roles-launch.log` y `orca-roles-kickoff.log` (arranque), `orca-<servicio>.log` y `orca-<servicio>.pid` (servicios locales del Deployer).
- Fuera del worktree: `~/.orca-roles/browser/<proyecto>.json`, la sesión del navegador para el Visual-Tester.
- En Windows (WSL): `~/.orca-roles/shim/orca`, el envoltorio del CLI de Orca (ver [Windows con WSL2](#windows-con-wsl2)).

## Plataformas

| Sistema | Estado |
|---|---|
| **macOS** | Plataforma principal. Los scripts están escritos para el bash 3.2 que trae el sistema (sin probar aún en un Mac real). |
| **Linux** (Ubuntu, Debian...) | Soportado: los scripts usan solo herramientas comunes a GNU y BSD. Depende de que Orca tenga versión para tu distribución. |
| **Windows** | Con **WSL2** (ver abajo). No hay versión nativa para PowerShell o Git Bash: el kit son scripts de Bash. |

### Windows con WSL2

Orca para Windows ejecuta las terminales, y con ellas los agentes y el setup script, dentro de WSL cuando el repo vive en el sistema de archivos de WSL. El kit se instala y funciona ahí como en Linux.

1. **WSL2 con Ubuntu** (`wsl --install` en PowerShell). Para `browser-login.sh` hace falta además WSLg (incluido en Windows 11 y en Windows 10 con `wsl --update`), que es lo que permite abrir un navegador visible desde WSL.
2. **El repo dentro de WSL**, en `~/...`, no en `/mnt/c/...`: en el disco de Windows git y los agentes van mucho más lentos. Clónalo desde WSL; si lo clonas desde Windows con `core.autocrlf=true`, los scripts tendrán finales de línea CRLF y bash no los ejecutará.
3. **En Orca, añade el proyecto con su ruta de WSL**: `\\wsl.localhost\Ubuntu\home\<usuario>\<repo>`. Así Orca abre sus terminales dentro de WSL.
4. **Instala dentro de WSL, desde una terminal de Orca**: `sudo apt install jq`, Claude Code y Node dentro de WSL (no los de Windows), y después el instalador del kit.
5. **Registra el kit en cada proyecto** con `roles-yaml` o en Settings (ver [Configurar un proyecto](#configurar-un-proyecto-una-vez-por-proyecto)).
6. **Visual-Tester**: `npx playwright install --with-deps chromium` dentro de WSL.

**El CLI de Orca se llama distinto.** En las terminales de WSL, Orca no instala `orca` sino un lanzador cuyo nombre indica `$ORCA_CLI_COMMAND` (`orca-ide` en Orca 1.4.219), que llama a `orca.exe` en Windows. El kit lo detecta y crea el envoltorio `~/.orca-roles/shim/orca`, que antepone al PATH de sus scripts y de los agentes; los prompts y los permisos (`Bash(orca orchestration:*)`) siguen funcionando sin cambios. Por eso el CLI solo está disponible en terminales abiertas por Orca: los comandos del kit (`roles`, `clean.sh`, el instalador) hay que lanzarlos desde una de ellas.

El instalador añade los comandos `roles`, `nuevo-rol` y `roles-yaml` a `~/.zshrc` (zsh), a `~/.bashrc` (bash en Linux), a `~/.bash_profile` (bash en macOS) o a `~/.profile` (otros shells).

## Requisitos

- Orca con Orchestration activado (Settings > Experimental).
- `jq` (macOS: `brew install jq`; Ubuntu/Debian: `sudo apt install jq`). Es imprescindible: el instalador y el kit fallan con un mensaje claro si falta.
- Claude Code (`claude`) con `--permission-mode auto` disponible. El instalador lo comprueba y avisa si tu versión no lo ofrece; en ese caso actualiza Claude Code o cambia `permissionMode` en `config.json`. Comprobado con la 2.1.x.
- Los CLI de cualquier otro agente que configures.
- `curl` y `tar` (vienen con macOS y Ubuntu), Node (`npx`, para Playwright). Para el Visual-Tester, Chromium de Playwright: `npx playwright install chromium` (en Ubuntu, `npx playwright install --with-deps chromium`, que además instala las librerías del sistema que necesita y pide sudo).

## Desarrollo

```bash
tests/smoke.sh                                   # no toca ~/.orca-roles
shellcheck -S warning install.sh bin/*.sh tests/*.sh
```

El workflow de GitHub Actions ejecuta lo mismo en cada push.

## Solución de problemas

| Síntoma | Qué revisar |
|---|---|
| No se abren las pestañas | `orca-roles-launch.log` del worktree, y el setup script del proyecto |
| Con `roles-yaml`, el worktree nuevo no arranca el kit | Que el worktree tenga `orca.yaml` (si no, `.worktreeinclude` no lo copió: `git check-ignore -v orca.yaml` en el checkout principal debe responder), y que el proyecto no tenga un setup script en Settings, que tendría prioridad |
| «No encuentro el CLI de Orca» (Windows) | Lanza el comando desde una terminal de Orca: fuera de ellas no existen `orca` ni `$ORCA_CLI_COMMAND` |
| Los agentes no reciben su rol | `orca-roles-kickoff.log` del worktree |
| «Configuración inválida» | Valida tu JSON: `jq . ~/.orca-roles/config.json` (y el `.orca-roles.json` del proyecto) |
| Un agente arranca con otro modelo o MCP | `orca-roles.config.json` en la carpeta git del worktree muestra la configuración que se usó |
| Un agente pide permisos | Que esté en auto mode (`Shift+Tab` muestra el modo actual) |
| Pestañas en otro workspace | `launch.sh` usa `ORCA_WORKTREE_ID`; puedes forzarlo con `launch.sh id:<ORCA_WORKTREE_ID>` |
| Tras reiniciar, el Planner no retoma el estado | `orca-roles-launch.log` debe decir «Retomando workspace». Si no, el archivo `orca-roles.env` de la carpeta git del worktree no existía o estaba vacío |
| La limpieza de un worker falla | `clean.sh` dice por qué: pestaña muerta (ejecuta `roles`), o agente `custom` sin `clearCommand` |
| La sesión extra del composer no se cierra | Su título no coincide con la clave de Jira ni con la rama; `orca-roles-kickoff.log` lo indica. Ciérrala a mano o desactiva `closeComposerAgent` |
| El Visual-Tester no abre el navegador | `npx playwright install chromium` |
| El Visual-Tester ve la pantalla de login | Ejecuta `~/.orca-roles/bin/browser-login.sh <url>` y pide al Planner que limpie al Visual-Tester (`clean.sh visual-tester`) para que arranque con la sesión nueva |
| El Planner no recibe el ticket de Jira | Crea el worktree desde el ticket en Orca para que quede enlazado (`orca worktree show --json` debe mostrar `linkedWorkItem`). Sin enlace, la rama tiene que empezar por la clave en mayúsculas |
| Las capturas no están en `qa-evidence/` | Comprueba el `--output-dir` del servidor `playwright` en `orca-roles.config.json` del worktree |
| Un servicio local no se para | `ls "$(git rev-parse --git-dir)"/orca-*.pid` y mata esos procesos |

## Limitaciones conocidas

- El hook solo se dispara al crear un worktree; en otros casos (incluido retomar tras un reinicio) usa `roles`.
- Al retomar, el Planner reconstruye el estado desde Orca y git, pero no recupera su conversación anterior: las decisiones que tomaste de palabra y no quedaron en una tarea se pierden. Reanudar las sesiones de Claude Code con `--resume` es una mejora posible.
- Orca no tiene setup script global: hay que configurarlo una vez por proyecto.
- El cierre de la sesión extra del composer depende de que Orca la titule con la rama exacta o empezando por la clave de Jira. Si la titula de otra forma, no se cierra (el formato exacto del título no está verificado).
