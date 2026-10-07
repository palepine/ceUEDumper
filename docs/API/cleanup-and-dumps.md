# Cleanup and text dumps

## Cleanup

#### `ue_unregisterAllOffsets()`
  > drop all symbols created by the script

#### `ue_clearCache()`
  > drop UClass addr cache


## Text dumps

These functions are synchronous and return
`outputPath, entryCount` on success or `nil, errorMessage` on failure.
`outputPath` is optional, defaults to executable folder

#### `ue_dumpFNames(outputPath)`
> Write one decoded FName string per line in comparison-index order

```lua
local path, count = ue_dumpFNames()
assert(path, count)
print( ('Dumped %d names to %s'):format( count, path ) )
```

#### `ue_dumpTypes(outputPath, options)`
> Dump indexed `UClass`, `UScriptStruct`, `UEnum`

```lua
local path, count = ue_dumpTypes()
assert(path, count)
print( ('Dumped %d reflected types to %s'):format(count, path) )
```

#### `ue_dumpObjects(outputPath)`
> Dump readable GUObjectArray entry

```lua
local path, count = ue_dumpObjects()
assert(path, count)
print( ('Dumped %d UObjects to %s'):format( count, path ) )
```

Explicit writable destination can be supplied too:

```lua
assert(ue_dumpTypes([[C:\Dumps\MyGame_Types.txt]]))
```

Decompiler-related options:
`decompileFunctions`, `decompileUbergraphs`, `includeOpcodeTrace`,
`includeMetadata`, `includeStatementOffsets`

Blueprint functions are decompiled in the type dump by default.
`ExecuteUbergraph_*` remain as sygnatures
unless `decompileUbergraphs` is explicitly enabled

```lua
ue_dumpTypes(nil, { decompileFunctions = false })

-- Opt in when a complete Ubergraph pseudocode dump is wanted
ue_dumpTypes(nil, { decompileUbergraphs = true })
```



