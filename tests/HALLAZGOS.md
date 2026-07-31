# Hallazgos — suite de pruebas de `cmake_builder.lua`

Entorno: Docker `archlinux:base`, Neovim 0.12, cmake + gcc, plenary.nvim.
**Sin snacks.nvim ni dressing.nvim** — es justo esa ausencia lo que destapa los dos fallos críticos.

Estado: **24 tests, 22 verdes, 2 rojos.** #1 y #2 corregidos; #3 y #4 siguen abiertos.

Reproducir: `./tests/run.sh` (o `./tests/run.sh cmake_builder_spec` para uno solo).

---

## #1 — `program_with_build` colgaba la sesión DAP en Neovim sin snacks · CRÍTICO · CORREGIDO

`lua/cmake_builder.lua:587-594` (idéntico en `program_with_build_sync`, `:675-682`)

`vim.ui.input` de stock (`/usr/share/nvim/runtime/lua/vim/ui.lua:135-140`) invoca
`on_confirm` **de forma síncrona**, antes de retornar. El código hace:

```lua
vim.ui.input({...}, function(input)
    bin_path = input
    coroutine.resume(co_input)   -- co_input es la coroutine EN EJECUCIÓN
end)
coroutine.yield()                -- nadie la va a despertar
```

`coroutine.resume` sobre la coroutine que está corriendo devuelve
`false, "cannot resume non-suspended coroutine"`. El valor de retorno **no se comprueba**,
así que el error se pierde en silencio y el `yield()` siguiente suspende para siempre.

Efecto para el usuario: `:DapContinue` se queda colgado sin mensaje ni error. Solo funciona
hoy porque snacks.nvim sustituye `vim.ui.input` por una versión asíncrona.

**Fix:** helper `await_ui` (`lua/cmake_builder.lua:68-97`). Deja que el callback marque si
respondió *antes* del `yield`; en ese caso devuelve el valor sin suspender, y solo hace
`resume` cuando la coroutine está realmente suspendida. Los tres sitios afectados pasan por
él. Se eliminaron de paso `result_path` y `build_ok`, que estaban muertas.

Evidencia: `tests/cmake_builder_spec.lua` — los pares `stub_ui("sync")`/`stub_ui("async")`
dan ahora el mismo resultado. Antes del fix el síncrono expiraba por timeout.

---

## #2 — Misma carrera en `select_executable` · CRÍTICO · CORREGIDO

`lua/cmake_builder.lua:126-134`

Idéntico patrón con `vim.ui.select`. Solo se dispara con **2 o más ejecutables** en `build/`
(con uno hay early-return en `:119`, con cero se sale en `:111`), lo que explica que pase
desapercibido en proyectos de un solo target.

El fallback de `:138-150` (`vim.fn.inputlist`) solo se alcanza sin coroutine (llamada directa
desde código de usuario); con `nvim-dap` siempre la hay. Se mantiene intacto.

**Fix:** mismo `await_ui` que #1.

Evidencia: `tests/cmake_builder_spec.lua`, caso "varios ejecutables con UI sincrona".

---

## #3 — `max_source_files` inventa recompilaciones · MEDIO

`lua/cmake_builder.lua:173` vs `:205`

Las dos ramas del tope se contradicen:

- `:173` — al **entrar** a un subdirectorio con el cupo agotado devuelve `true` (= "recompilar").
- `:205` — al **agotar** el cupo dentro de un directorio devuelve `false`, y el escaneo del
  directorio padre **continúa igualmente**: el tope no corta nada, solo cambia el resultado.

Con 11 fuentes todas más antiguas que el binario (respuesta correcta: `false`):

| `max_source_files` | 1 | 2 | 3 | 4 | 5 | 6 | 2000 |
|---|---|---|---|---|---|---|---|
| `needs_rebuild` | false | false | **true** | **true** | **true** | **true** | false |

No es monótono y depende del orden que devuelva `fs_scandir`. Un tope de seguridad como mucho
debería producir un falso negativo (no detectar un cambio), nunca un rebuild inventado.

Evidencia: `tests/cmake_builder_spec.lua:70`.

---

## #4 — `reconfigure_debug` usa `getcwd()` como source dir · MEDIO

`lua/cmake_builder.lua:325-326`

```lua
{ "cmake", "-S", cwd, "-B", build_dir, ... }
```

Asume que el cwd de Neovim es la raíz del proyecto. Si el usuario hizo `:cd` a un
subdirectorio y apunta `build_dir` hacia arriba (`"../../build"`), cmake aborta:

```
CMake Error: The source directory "/tmp/p/src/deep" does not appear to contain CMakeLists.txt.
```

y el plugin lo reporta como "Reconfigure de CMake falló" sin decir por qué. La ruta correcta
está en el propio cache: `CMAKE_HOME_DIRECTORY` en `CMakeCache.txt`, que ya se está leyendo
en `get_cache_build_type` (`:296-309`).

Evidencia: `tests/integration_spec.lua:103`.

---

## Menores, sin test dedicado

- `:424` — `vim.cmd("cclose")` tras un build correcto cierra el quickfix aunque el usuario
  lo tuviera abierto por otra cosa.
- `:16` — `require("bit")` es de LuaJIT. Innecesario: `mode % 512 >= 64` o
  `vim.fn.executable()` cubren lo mismo sin la dependencia.
- Encabezado (`:1`) y README discrepan: el fichero dice `lua/utils/cmake_builder.lua`, el
  módulo real es `lua/cmake_builder.lua` (`require("cmake_builder")`, como sí usa el README).

## Hipótesis descartadas por los tests

- `setup()` **no** fusiona listas mal: desde Neovim 0.10 `vim.tbl_deep_extend` reemplaza
  las listas en vez de mezclarlas por índice. Queda un test de regresión que lo fija.
- El escaneo de mtime **sí** excluye correctamente `build_dir`, `.git` y `node_modules`.
- La reconfiguración a Debug **sí** funciona en el caso normal: el `CMakeCache.txt` acaba en
  `Debug` y el binario resultante trae sección `.debug_info` (verificado con `readelf -S`).
- El parseo de errores al quickfix **sí** produce items con `type = "E"`, fichero y línea
  correctos, tanto en `output_mode = "quickfix"` como en `"float"`.
