# CE symbols, offsets, and object paths

## Working with CE symbols
    Symbols do NOT persist by design. Use offset resolution api on each run.

### Simple (Bulk / Selective)

#### `ue_registerClassOffsets(className, propertyNames, namespace)`
> Register selected properties/fields for `class name`. Use namespace when you need a prefix.

    Notes: propertyNames must be a table. If it's nil - it registers all fields (including inherited)

    Also works on UScriptStruct fields

```lua
local symbols, err = ue_registerClassOffsets( 'GameEngine', { 'TinyFont', 'GameInstance' } ) -- GameEngine.TinyFont and GameEngine.GameInstance available
assert( symbols, err )
return symbols -- if you want to see the table
```

#### `ue_registerObjectOffsets(objectAddress, propertyNames, namespace, symbolPrefix)`
  > same as `ue_registerClassOffsets` but via obj instance

    Notes:
    
    Also works on UScriptStruct fields

    exact prefix defaults to its class name. Supplying one overrides it

```lua
assert( ue_registerObjectOffsets( worldAddr, { 'OwningGameInstance' } ) ) -- again, UClass name would be used: World.OwningGameInstance

local offsetPath = { 'Settings.Cheats.GodMode' }

local symbols, symbolError = ue_registerObjectOffsets( gameInstanceAddr, offsetPath, '', 'OwningGameInstance') -- if symbolPrefix - it will use the object's class name: whateverOGI.Settings.Cheats.GodMode
assert(symbols, symbolError)
-- OwningGameInstance.Settings.Cheats.GodMode is now an offset
```


### Object Paths

#### `ue_registerObjectPath(rootObject, propertyPath, namespace)`
  > Resolve the path starting from root & register every segment independently

    Notes:
    rootObject is an obj instance the script will follow from.

    propertyPath segments must be property names an object has

    Doesn't work on containers.

```lua
local symbols, err = ue_registerObjectPath( worldThis, 'OwningGameInstance.LocalPlayers', "World" )
assert(symbols, err)
-- The "World" we pass is namespace
-- World.OwningGameInstance --  without namespace it would simply be 'OwningGameInstance'
-- World.OwningGameInstance.LocalPlayers  --  'OwningGameInstance.LocalPlayers' w/o namespace

-- AGAIN, .LocalPlayers offset as relative to OwningGameInstance base, not World

-- let's say pGWorld is UWorld*
-- then [[pGWorld]+World.OwningGameInstance]+World.OwningGameInstance.LocalPlayers resolves to LocalPlayers address (which is an object addr, it being a poitner)
```


## UObject Instance Property Paths

### `ue_resolveObjectPropertyPath(rootObject, propertyPath)`
  > similar to `ue_registerObjectPath`, but returns a table

    Notes: see `ue_registerObjectPath`


Parameters:
- `rootObject`: root instance addr (from which the path would start parsing)
- `propertyPath`: dot-separated string or array of segment names

Path traversal doesnt work on containers.

The result contains:
| Field           | Type      | Description                        |
| --------------- | --------- | ---------------------------------- |
| `rootObject`    | `number`  | Original pointer                   |
| `steps`         | `table[]` | Ordered metadata for every segment |
| `objectAddress` | `number`  | Object containing the final field  |
| `fieldAddress`  | `number`  | Address of the final field storage |
| `offset`        | `number`  | Final segment offset               |

Each step contains `name`, `offset`, `propertyType`, `propertyAddress`, `classAddress`, `objectAddress`, `fieldAddress`

For embedded struct steps, `classAddress` key holds its UScriptStruct descriptor and `objectAddress` holds its inline data base.
They do not imply the struct data is a UObject instance. The final `objectAddress` denotes the containing base

```lua
-- If final 'Player' is direct UObject ptr, read it
local playerAddr = readPointer(path.fieldAddress)
assert( playerAddr and playerAddr ~= 0, 'Player is null')

local path, err = ue_resolveObjectPropertyPath( worldAddr, 'OwningGameInstance.LocalPlayers' )
assert(path, err)
-- it does roughly UWorld::OwningGameInstance offset > dereference OwningGameInstance UObject pointer > OwningGameInstanceClass::LocalPlayers offset

print( ('UWorld::OwningGameInstance = 0x%X'):format( path.steps[1].offset ) )
print( ('OwningGameInstance::LocalPlayers = 0x%X'):format( path.steps[2].offset ) )
print( ('LocalPlayers field address = 0x%X'):format( path.fieldAddress ) )
```



