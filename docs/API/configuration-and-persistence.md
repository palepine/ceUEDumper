# Persistent configuration and target layouts

## Persistent configuration

```lua
local config = ue_getConfig()
print(config.maxArrayElements)

assert( ue_setConfig('maxArrayElements', 512) )
assert( ue_setConfig('maxMapElements', 128) )

-- Read one value.
print( ue_getConfig('maxMapElements') )

-- Restore one default, or omit the key to restore every default.
assert( ue_resetConfig('maxMapElements') )
assert( ue_resetConfig() )
```

| Key | Type | Default | Effect |
|---|---|---:|---|
| `maxArrayElements` | integer `0..65536` | `256` | Maximum `TArray` entries created to Struct Dissect |
| `maxMapElements` | integer `0..65536` | `256` | Maximum occupied `TMap` entries created |
| `maxSetElements` | integer `0..65536` | `256` | Maximum occupied `TSet` entries created |
| `maxDelegateElements` | integer `0..65536` | `256` | Maximum multicast-delegate invocation entries created |
| `decompileUbergraphs` | boolean | `false` | Default Ubergraph behavior for `ue_dumpTypes`; an explicit call option overrides it |

## Persistent layout
#### `ue_clearSavedLayout()`

Delete saved scanned values for the attached executable with its current version identifier

```lua
local cleared, removedCountOrError, settingsKey = ue_clearSavedLayout()
assert( cleared, removedCountOrError )
print( ('Removed %d saved values from %s'):format( removedCountOrError, settingsKey ) )
```

#### `ue_replaceRegisteredSymbolsWithOffsets()`

Replace owned property symbols in all memrecords with their resolved numerical offsets.

```lua
assert( ue_registerClassOffsets( 'World', {'OwningGameInstance' } ) )

local statistics, rewriteError = ue_replaceRegisteredSymbolsWithOffsets()

assert( statistics, rewriteError )
print( ('Changed %d records with %d replacements'):format( statistics.recordsChanged, statistics.totalReplacements ) )
```

Stats contain:
- `registeredSymbolCount`
- `recordsVisited`
- `recordsChanged`
- `addressReplacements`
- `offsetReplacements`
- `totalReplacements`

