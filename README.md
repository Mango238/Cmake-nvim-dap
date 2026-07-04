# 🔨 CMake-nvim-dap

Módulo de **Neovim en Lua** que automatiza el ciclo **build-and-debug** para proyectos **C++ basados en CMake**. Se engancha al campo `program` de **nvim-dap** para verificar, compilar y resolver el ejecutable correcto antes de iniciar cada sesión de debugging — **todo sin bloquear el editor**.

## 🎯 Características

- ✅ **Detección automática de cambios**: Compara timestamps (`mtime`) de archivos fuente con el binario para decidir si recompilar
- ✅ **Build asíncrono**: Ejecuta `cmake --build` sin freezar Neovim
- ✅ **Selección interactiva de ejecutables**: Si apuntas a un directorio, el plugin te deja elegir qué binario debuggear
- ✅ **Salida flexible**: Muestra el output del build en **quickfix** o en un **float window**
- ✅ **Integración directa con nvim-dap**: Funciona como reemplazo de `program` en tu configuración de DAP
- ✅ **Sin bloqueos**: Usa coroutines cuando está disponible, fallback a `vim.wait()` para compatibilidad
- ✅ **Configuración granular**: Controla directorios de búsqueda, extensiones, limites de archivos, etc.

---

## 📋 Requisitos

- **Neovim** >= 0.10 (se recomiendan versiones modernas con `vim.system()`)
- **nvim-dap** (plugin de debugging)
- **CMake** instalado y accesible desde la terminal
- Proyecto **C++** con estructura estándar:
  ```
  proyecto/
  ├── CMakeLists.txt
  ├── src/
  ├── include/
  └── build/           ← directorio de compilación (cmake -S . -B build)
  ```

---

## 🚀 Instalación

Con tu gestor de plugins favorito (ej: `packer.nvim`, `lazy.nvim`):

```lua
-- Con lazy.nvim
{
  "Mango238/Cmake-nvim-dap",
  lazy = true,  -- se carga bajo demanda
}

-- Con packer.nvim
use "Mango238/Cmake-nvim-dap"
```

Luego requiere el módulo en tu configuración de nvim-dap:

```lua
local cmake = require("cmake_builder")
```

---

## 📖 Uso Básico

### Opción 1: Binario con ruta predefinida (recomendado)

```lua
local cmake = require("cmake_builder")

require("dap").configurations.cpp = {
  {
    name = "Launch C++",
    type = "lldb",
    request = "launch",
    program = cmake.program_with_build("build/my_app"),  -- ruta relativa al binario
    cwd = "${workspaceFolder}",
    stopOnEntry = false,
    args = {},
  },
}
```

Cuando inicies una sesión DAP:
1. El plugin pide confirmar la ruta (con `build/my_app` como default)
2. Verifica si el binario está actualizado comparando `mtime`
3. Si hay fuentes más nuevas, ejecuta `cmake --build build`
4. Si el build es exitoso, nvim-dap comienza a debuggear
5. Si falla, muestra los errores en el quickfix

### Opción 2: Selección interactiva (sin ruta predefinida)

```lua
program = cmake.program_with_build(),  -- pide toda la ruta al usuario
```

El usuario puede:
- Confirmar la ruta sugerida (el directorio `build/` del proyecto)
- Escribir una ruta diferente
- Si apunta a un directorio, el plugin lista los ejecutables y permite seleccionar

### Opción 3: Variante síncrona (compatible con versiones viejas de nvim-dap)

```lua
program = cmake.program_with_build_sync("build/my_app"),
```

Usa `vim.wait()` en lugar de coroutines. Puede causar un brief freeze al finalizar el build, pero funciona con cualquier versión de nvim-dap.

---

## ⚙️ Configuración

### Parámetros por defecto

```lua
local cmake = require("cmake_builder")

cmake.setup({
  -- Directorio de build relativo a cwd (sin trailing slash)
  build_dir = "build",

  -- Argumentos adicionales para cmake --build
  cmake_extra_args = {},
  -- Ejemplo: { "--config", "Release", "-j", "4" }

  -- Extensiones de archivos fuente para la detección de cambios
  source_extensions = { "cpp", "cxx", "cc", "c", "h", "hpp", "hxx", "cmake", "CMakeLists.txt" },

  -- Directorios donde buscar fuentes (relativos a cwd)
  -- Si está vacío, escanea el proyecto entero (más lento pero seguro)
  source_dirs = {},
  -- Ejemplo: { "src", "include", "lib" }

  -- Máximo de archivos a escanear para mtime (evita colgarse en proyectos enormes)
  max_source_files = 2000,

  -- Fuerza siempre recompilar sin verificar mtime
  -- Útil para proyectos con generated files o includes externos
  always_build = false,

  -- Dónde mostrar output del build: "quickfix" | "float"
  output_mode = "quickfix",

  -- Abre quickfix automáticamente si hay errores de compilación
  open_quickfix_on_error = true,
})
```

### Ejemplo de configuración avanzada

```lua
cmake.setup({
  build_dir = "out",                    -- CMake usa "-B out"
  cmake_extra_args = { "-j", "8" },    -- Parallelismo
  source_dirs = { "src", "include" },  -- Solo escanea estos directorios
  max_source_files = 500,              -- Limite conservador
  always_build = false,                -- Respeta mtime
  output_mode = "float",               -- Float window en lugar de quickfix
  open_quickfix_on_error = true,
})
```

---

## 🔍 Cómo Funciona

### Flujo de ejecución

```
Usuario presiona nvim-dap.continue() 
         ↓
program_with_build() es invocado
         ↓
Pide/confirma ruta al usuario
         ↓
ensure_built(bin_path, on_ready, on_error)
         ↓
    ├─→ ¿Existe build/? 
    │   ├─→ NO: error, user debe hacer "cmake -S . -B build"
    │   └─→ SÍ: continúa
    │
    ├─→ ¿needs_rebuild(bin_path)?
    │   ├─→ NO: ✓ Binario al día → on_ready()
    │   └─→ SÍ: run_cmake_build()
    │
    └─→ cmake --build build (asíncrono)
        ├─→ ✅ Exitoso → on_ready()
        └─→ ❌ Fallido → on_error() + mostrar errores
```

### Detección de cambios (mtime check)

El plugin usa una heurística eficiente:

1. **Obtiene el timestamp** del binario (`bin_mtime`)
2. **Escanea recursivamente** los directorios fuente
3. **Compara cada archivo** contra `bin_mtime`
4. **Detiene temprano**: si encuentra un archivo más nuevo, sabe que hay rebuild

Esto es mucho más rápido que leer el CMakeCache o invocar cmake --build siempre.

### Output del build

**Modo Quickfix (por defecto):**
- Los errores y warnings se parsean y se populan en `:copen`
- Puedes navegar con `:cn` / `:cp`
- Sincronizado con el árbol de errores de LSP

**Modo Float:**
- Un buffer flotante centrado muestra el build en tiempo real
- Se auto-cierra si el build fue exitoso (tras 1.5s)
- Permanece abierto si hay errores (útil para leer warnings)

---

## 💡 Casos de Uso

### Proyecto simple con un binario

```lua
cmake.setup({ build_dir = "build" })

-- En tu dap config:
program = cmake.program_with_build("build/my_app"),
```

### Monorepo con múltiples binarios

```lua
-- Sin ruta predefinida → el usuario elige interactivamente
program = cmake.program_with_build(),
```

Cuando inicies DAP, el plugin listará todos los ejecutables en `build/` y te dejará seleccionar.

### Proyecto con builds Release y Debug

```lua
cmake.setup({
  cmake_extra_args = { "--config", "Debug", "-j", "8" },
})
```

O configura variantes según tu necesidad:

```lua
require("dap").configurations.cpp = {
  {
    name = "Debug (build)",
    program = cmake.program_with_build("build/debug/app"),
    -- ...
  },
  {
    name = "Release (build)",
    program = cmake.program_with_build("build/release/app"),
    -- ...
  },
}
```

### Proyecto grande: limita el escaneo

```lua
cmake.setup({
  source_dirs = { "src", "include" },      -- Solo escanea fuentes
  max_source_files = 300,                  -- Limite conservador
  output_mode = "float",                   -- Visual feedback rápido
})
```

---

## 🛠️ API Pública

### `M.setup(opts)`

Configura los parámetros por defecto. Se debe llamar una sola vez en tu `init.lua`.

```lua
require("cmake_builder").setup({
  build_dir = "build",
  always_build = false,
  -- ...
})
```

### `M.needs_rebuild(bin_path) → boolean`

Determina si el binario está desactualizado.

```lua
local cmake = require("cmake_builder")
if cmake.needs_rebuild(vim.fn.getcwd() .. "/build/app") then
  vim.notify("Necesita recompilar")
end
```

### `M.ensure_built(bin_path, on_ready, on_error)`

Verifica y compila de forma asíncrona. Llama a `on_ready(bin_path)` si todo va bien, o `on_error()` si falla.

```lua
cmake.ensure_built("/path/to/binary", function(path)
  vim.notify("Build ok: " .. path)
end, function()
  vim.notify("Build failed!")
end)
```

### `M.program_with_build(default_binary) → function`

**Interfaz principal** compatible con nvim-dap. Retorna una función que nvim-dap invocará.

```lua
program = cmake.program_with_build("build/my_app"),
-- or
program = cmake.program_with_build(),
```

### `M.program_with_build_sync(default_binary) → function`

Alternativa síncrona (usa `vim.wait()` en lugar de coroutines). Útil para versiones viejas de nvim-dap.

### `M.select_executable(dir) → string|nil`

Lista todos los ejecutables en un directorio y permite seleccionar uno.

```lua
local bin = cmake.select_executable(vim.fn.getcwd() .. "/build")
if bin then
  vim.notify("Selected: " .. bin)
end
```

---

## 🐛 Troubleshooting

### "El directorio build/ no existe"

**Causa**: CMake no ha sido inicializado en tu proyecto.

**Solución**:
```bash
cd /ruta/del/proyecto
cmake -S . -B build
```

### Build falla pero debería pasar

- Verifica que el build manual funciona: `cmake --build build`
- Si usas `cmake_extra_args`, asegúrate de que son compatibles con tu generador
- Revisa el quickfix (`:copen`) para ver los errores exactos

### El plugin detecta cambios pero no recompila

- `always_build = false` (por defecto): el plugin respeta `mtime`
- Si tus fuentes fueron modificados pero no se refleja en `mtime`, fuerza con:
  ```lua
  cmake.setup({ always_build = true })
  ```

### Neovim se queda "congelado" después del build

Esto puede ocurrir si:
- Usas `program_with_build_sync()` con builds muy largos
- Usa `program_with_build()` en su lugar (requiere nvim-dap con soporte de coroutines)

### El ejecutable no se encuentra

- Asegúrate de que la ruta es correcta (relativa a `cwd` o absoluta)
- Si pasas un directorio, el plugin intentará listar ejecutables automáticamente
- Verifica permisos de ejecución en Unix: `chmod +x /ruta/binario`

---

## 📚 Integración con nvim-dap

### Configuración completa de ejemplo

```lua
-- init.lua

-- 1. Carga y configura el builder
local cmake = require("cmake_builder")
cmake.setup({
  build_dir = "build",
  cmake_extra_args = { "-j", "4" },
  output_mode = "float",
})

-- 2. Carga nvim-dap
local dap = require("dap")

-- 3. Configura adapters
dap.adapters.lldb = {
  type = "executable",
  command = "lldb-vscode",  -- o "lldb-mi" según tu sistema
  name = "lldb",
}

-- 4. Configura configuraciones (aquí va el programa con build)
dap.configurations.cpp = {
  {
    name = "Launch C++ (Debug)",
    type = "lldb",
    request = "launch",
    program = cmake.program_with_build("build/main"),
    cwd = "${workspaceFolder}",
    stopOnEntry = false,
    args = {},
  },
}

-- 5. Mappings (ej con which-key)
vim.keymap.set("n", "<F5>", dap.continue, { noremap = true })
vim.keymap.set("n", "<F10>", dap.step_over, { noremap = true })
vim.keymap.set("n", "<F11>", dap.step_into, { noremap = true })
```

---

## 🤝 Compatibilidad

- **Neovim**: 0.10+
- **nvim-dap**: cualquier versión que cargue el campo `program` (0.5+)
- **CMake**: 3.10+
- **Compiladores**: GCC, Clang, MSVC (cualquiera que soporte `cmake --build`)

### Versiones antiguas de Neovim (0.9.x)

El plugin usa `vim.system()` que está disponible desde Neovim 0.10. Para versiones anteriores, necesitarías reemplazar ese código con `vim.loop` o `nvim_system`. Contacta si necesitas backport.

---

## 📝 Licencia

MIT (o especifica la que uses)

---

## 🎓 Cómo contribuir

Las contribuciones son bienvenidas. Por favor:

1. Haz fork del proyecto
2. Crea una rama para tu feature: `git checkout -b feature/mi-mejora`
3. Commit con mensajes claros
4. Abre un Pull Request

---

## 📞 Soporte

Si encuentras bugs o tienes sugerencias, abre un **issue** en el repositorio.

---

**Disfruta del debugging sin fricción** 🚀
