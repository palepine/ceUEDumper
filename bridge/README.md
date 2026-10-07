# ceUEDumper BP Hook bridge

## Build

Requirements:
- CMake 3.23 or newer
- Visual Studio 2022 Build Tools with the **Desktop development with C++** workload
- Windows 10/11 SDK

```
cmake -S . -B build -A x64
cmake --build build --config Release
```

Place in `\autorun\ceUEDumperModules`

## Functionality

- `UFunction::Func` swap-based (not `ProcessLocalScriptFunction`)
- filtering via object
- ANDed scalar conditions on `object`, `FFrame::Locals` or `RESULT_DECL`
- scalar writes before/after call
- conditional early return
- graceful toggling/removal of `UFunction::Func`