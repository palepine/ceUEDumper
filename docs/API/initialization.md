# Initialization, engine version, layout, and status

## Initialization

#### `ue_initDumper(config)`
> Run reflection scan synchronously and clear the lookup cache.

- `config.signatureSelection`: `'first'` (default) or `'scored'`
- `config.launchScanner`: set to `false` to query existing ready state without starting anew

  > Returns `true` on success or `false, errorMessage` on failure
  > Use ceUEDumper menu for asynchronous initialization to keep CE GUI responsive
    
  > First uses signatures to lookup fundamental globals w/o scoring heuristics.

```lua
local ready, err = ue_initDumper()
assert(ready, err)
```

### Engine version and layout fallback

#### `ue_detectEngineVersion()`
> Try to infer UE version

```lua
local version, err = ue_detectEngineVersion()
assert(version, err)

print( version.major, version.minor, version.patch )
print( version.source, version.confidence, version.raw )
```

The result contains:

| Field        | Description |
| ------------ | ----------- |
| `major`      | Unreal major version (`4` or `5`) |
| `minor`      | Unreal minor version |
| `patch`      | Patch version when available |
| `source`     | `embedded-unreal-branch`, `file-product-version`, `file-version-text`, or `file-version-components` |
| `raw`        | Original branch/version text |
| `module`     | Executable module source |

#### `ue_setEngineVersion(versionOrMajor, minor, patch)`
> Select an explicit version for the current loaded script.

```lua
assert( ue_setEngineVersion('5.7.1') )
assert( ue_setEngineVersion( { major = 4, minor = 24 } ) )
assert( ue_setEngineVersion( 5, 3, 2 ) )

-- clear the selection and expose the last detected value again
assert( ue_setEngineVersion(nil) )
```
#### `ue_getEngineVersion()`
> Return the explicit selection first, otherwise the last detection

#### `ue_setLayoutOverrides(layout)`
> Set known member offsets manually. Takes precedence over restored/inferred values

    Notes:
      - call it before `ue_initDumper()` to avoid inference
      - partial tables are fine
      -  ue_setLayoutOverrides(nil) disables manual values, needs rescan

```lua
local newLayout =
{
  UObject =
  {
    Class = 0x10,
    Name = 0x18,
  },

  UStruct =
  {
    SuperStruct = 0x40,
    Children = 0x48,
    ChildProperties = 0x50,
    PropertiesSize = 0x58,
    MinAlignment = 0x5C,
    Script = 0x60,
  },

  UClass =
  {
    SuperStruct = 0x40,
    PropertyLink = 0x70,
    PropertyLinkAlt = 0x50,
  },

  FFieldClass =
  {
    Name = 0,
    SuperClass = 0x20,
  },

  FField =
  {
    Class = 0x8,
    Owner = 0x10,
    PropertyLinkNext = 0x20,
    Name = 0x28,
  },

  FProperty =
  {
    Class = 0x8,
    Owner = 0x10,
    Name = 0x28,
    Size = 0x3C,
    Offset = 0x4C,
    PropertyLinkNext = 0x58,
  },

  UFunction =
  {
    FunctionFlags = 0xB0,
    NumParms = 0xB4,
    ParmsSize = 0xB6,
    ReturnValueOffset = 0xB8,
    RPCId = 0xBA,
    RPCResponseId = 0xBC,
    FirstPropertyToInit = 0xC0,
    EventGraphFunction = 0xC8,
    EventGraphCallOffset = 0xD0,
    Func = 0xD8,
  },

  ObjectArrayEntryStructSize = 0x18,
  ObjectArrayObjectOffset = 0,
}

assert( ue_setLayoutOverrides( newLayout ) )

assert( ue_initDumper() )
```

#### `ue_getLayoutOverrides()`
> Return set layout

### Initialization status

#### `ue_isReady()`
  > `true` when object array/reflection layout fields are done.

#### `ue_isNameReady()`
  > `true` when the selected FNamePool decoded successfully and its contents
passed validation.

#### `ue_getStatus()`
  > get status table

| Field                     | Type            | Description                                                                        |
| ------------------------- | --------------- | ---------------------------------------------------------------------------------- |
| `ready`                   | `boolean`       | Reflection layout available                                                        |
| `namesReady`              | `boolean`       | FNames parsed                                                                      |
| `running`                 | `boolean`       | Scanner still running?                                                             |
| `error`                   | `string or nil` | Last scan failure error                                                            |
| `log`                     | `string`        | Composed logging notes                                                             |
| `namePool`                | `number or nil` | `FNamePool` allocator addr                                                         |
| `namePoolValidated`       | `boolean`       | Name pool passed validation                                                        |
| `namePoolSourceModule`    | `string or nil` | Name pool owner module                                                             |
| `namePoolDiscoveryMethod` | `string or nil` | How name pool was found                                                            |
| `cachedNameCount`         | `number`        | Unique names cached                                                                |
| `fnameToString`           | `number or nil` | ::ToString func resolved (dont bother for now)                                     |
| `engineVersion`           | `table or nil`  | Explicit or last detected engine-version descriptor                                |
| `layoutOverrides`         | `table or nil`  | Current caller-supplied layout overrides                                            |



