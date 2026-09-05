# CE UE Dumper Lua API reference

## TODOs
- maps, sets
- arbitrary object name/base lookups for struct dissector
- fname/object descryption
- array limit setting

## Digest

| Function                                           | Description                                            |
| -------------------------------------------------- | ------------------------------------------------------ |
| `ue_initDumper(config)`                            | Init & wait                                            |
| `ue_isReady()`                                     | Get ready status                                       |
| `ue_isNameReady()`                                 | Get cached names status                                |
| `ue_getStatus()`                                   | Get verbose dumper state                               |
| `ue_findClass(name)`                               | Find a `UClass` by short name, eg 'GameInstance        |
| `ue_enumFunctions(type)`                           | Enumerate `UFunctions` for type                        |
| `ue_findFunction(type, name)`                      | Find a specific `UFunction` for type                   |
| `ue_getFunctionMetadata(function)`                 | Get `UFunction` obj & parameter metadata               |
| `ue_callFunction(this, name, arguments, options)`  | Invoke `UFunction` for an object                       |
| `ue_enumProperties(class)`                         | Enumerate properties for class name UClass addr        |
| `ue_getPropertyOffset(class, property)`            | Resolve one property offset                            |
| `ue_enumObjectProperties(this)`                    | Enumerate class properties via object                  |
| `ue_getObjectPropertyOffset(this, property)`       | Resolve an object property offset                      |
| `ue_resolveObjectPropertyPath(this, path)`         | Enumerate by following object property path            |
| `ue_registerClassOffsets(class, names, namespace)` | Register class property symbols                        |
| `ue_registerObjectOffsets(this, names, namespace)` | Register class property symbols via object             |
| `ue_registerObjectPath(this, path, namespace)`     | Register class property symbols via obj and path       |
| `ue_unregisterAllOffsets()`                        | Clear created symbols                                  |
| `ue_clearCache()`                                  | Clear cached `UClass` addresses                        |

---
---
---

# API

## Initialization
- `ue_initDumper(config)`
  > Launch the scanner via Lua. Will clear the cache too.

  - `config.timeout`: wait in millis, default 30000
  - `config.signatureSelection`: `'first'` (default) or `'scored'`

    > Notes: returns `true` on success, `false, errorMessage` on failure
    
    > First uses signatures to lookup fundamental globals w/o scoring heuristics.

```lua
local ready, err = ue_initDumper( { timeout = 120000 } )
assert(ready, err)
```

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


## Property reflection

Enumeration API returns tables keyed by reflected property name. that also includes inherited ones.

| Field             | Type            | Description                                         |
| ----------------- | --------------- | --------------------------------------------------- |
| `offset`          | `number`        | Offset to the field                                 |
| `propertyAddress` | `number`        | `UProperty`/`FProperty` metadata addr               |
| `propertyType`    | `string or nil` | Reflected type (eg `ObjectProperty`)                |
| `size`            | `number or nil` | Element size (when available)                       |
| `structAddress`   | `number or nil` | `UScriptStruct` for `StructProperty`                |
| `structError`     | `string or nil` | reason for struct not being resolved                |
| `byteMask`        | `number or nil` | Boolean mask when that makes sense                  |


## Class-based queries

Names ending in `_number_32HexDigits` have readable runtime alias with trailing suffix removed
Ordinary underscores, numeric suffixes, shorter hexadecimal strings are preserved.

Offset queries and `ue_resolveObjectPropertyPath` accept clean segments or raw generated names.

Ambiguous clean names within one containing type return an error.

Different paths such as `SettingsStruct.Blah.Foo` and `SettingsStruct.SomethingElse.Foo` remain independent.

Enumeration maps keep raw keys. Flattened entries add `rawPath` and `displayPath`
The struct dissect uses displayPath, keeping raw segments where cleaning would be ambiguous.

Symbol registration uses clean aliases by default. For now it validates the whole selection before replacing any symbols. Raw generated paths are available when disambiguation is needed.

#### `ue_registerObjectStructOffsets( objectAddr , selectedPaths, symbolPrefix )`
> register object offsets cumulatively.

    Exact prefix defaults to its class name. Supplying one overrides it

```lua
local world = readPointer( "pGWorld" ) -- instance
local path, err = ue_resolveObjectPropertyPath( world, 'OwningGameInstance' ) -- by property name
assert(path, err)
local ginstance = assert( readPointer( path.fieldAddress ) ) -- fieldAddress is a pointer to GI from the World instance

local offsetPath = { 'SettingsStruct.Cheats.InfiniteAmmo' }
local symbols, symbolError = ue_registerObjectStructOffsets( ginstance, offsetPath, 'OwningGameInstance' )
assert(symbols, symbolError)
-- OwningGameInstance.SettingsStruct.Cheats.GodMode is now an offset
```

### Embedded struct queries and rendering

#### `ue_enumProperties( typeNameOrAddress )`
  > accepts reflected names and UClass/UScriptStruct objects, including Blueprint-derived metaclasses

#### `ue_findStruct(name)`
  > resolve a script-struct via name.

#### `ue_getPropertyOffset( typeNameOrAddress, 'SettingsStruct.Cheats.InfiniteAmmo')`
  > return the sum of the embedded offsets relative to `type`. A dotted offset cannot cross object pointer.
  
#### `ue_getObjectPropertyOffset(this, path)`
  > ue_getPropertyOffset, but using object instance

#### `ue_enumFlattenedProperties( typeNameOrAddress )`
  > return dotted names and cumulative offsets, including both struct entries and their leaves.
  
    Notes: unknown/ambiguous struct types, cycles return nil, error

#### `ue_registerStructOffsets( typeNameOrAddress, selectedPaths, namespace )`
  > register these cumulative offsets
  
    Notes: Pass nil for selectedPaths to register all entries
    
    The type may also be a class containing structs. 
    
    note that `ue_registerObjectPath` continues to register each segment's local offset, not cumulative offsets

```lua
-- provided we have gameInstance instance
local offsetPath = 'SettingsStruct.Gameplay.Difficulty'
local offset, err = ue_getObjectPropertyOffset( gameInstance, offsetPath )
assert(offset, err)
print( ('Difficulty offset: 0x%X'):format(offset) )

local path, pathError = ue_resolveObjectPropertyPath( gameInstance, offsetPath )
assert(path, pathError)
print( ('Difficulty address: 0x%X'):format( path.fieldAddress ) )

-- create a struct
local structure, structureError = ue_createStructureFromObject( gameInstance )
assert( structure, structureError )
local form = createStructureForm()
form.MainStruct = structure
form.Column[0].Address = gameInstance
```

#### `ue_createStructureFromType( typeNameOrAddress, baseAddr )`
  > create a struct dissect form view. baseAddr is optional (would just build a struct otherwise)


#### `ue_findClass(className)`
  > Find UClass by its short reflected name, return its address or nil

```lua
local gameEngineClass = assert( ue_findClass('GameEngine') )
```

#### `ue_enumProperties(classNameOrAddress)`
  > Enumerates a short class name (or UClass addr). Returns `properties` /  `nil, errorMessage`.

```lua
local properties, err = ue_enumProperties('GameEngine')
assert(properties, err)

for name, property in pairs(properties) do
  print( ('%s = 0x%X'):format( name, property.offset ) )
end
```

### UFunction metadata

#### `ue_enumFunctions(classNameOrAddress)`
  > return UClass/UScriptStruct UFunctions keyed by reflected name.
   
#### `ue_findFunction(classNameOrAddress, funcName)`
  > return one func descriptor.
  
#### `ue_getFunctionMetadata(address)`
  > decode function header and its parameter properties

```lua
local jump = assert( ue_findFunction('MyCharacter_C', 'Jump') )
local info = assert( ue_getFunctionMetadata(jump) )

print(
        ('flags=%08X native=%s bytecode=%X size=%d params=%d frame=%d')
        :format( info.functionFlags, tostring(info.native), info.bytecode or 0, info.bytecodeSize or 0, info.numParms, info.parmsSize )
    )

for name, parameter in pairs( info.parameters ) do
  if parameter.isParameter then
    print( name, parameter.propertyType, parameter.offset, parameter.isOutParameter, parameter.isReturnParameter )
  end
end
```

#### `ue_callFunction(objectAddress, functionName, arguments, options)`
  > UFunction invokation on the object with the following arguments (nil if void). Returns nil, errorMessage on some failure

    Notes: calls are synchronous and use CE calling API. Hance it doesn't call functions on the UE game thread. UFunction that requires game-thread context may spoil the day.

Supported argumet types :

| Reflected Property                                    | Lua Argument                                                                           |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `BoolProperty`                                        | `true` / `false`                                                                       |
| `ByteProperty`                                        | Lua number, signed/unsigned                                                            |
| `FloatProperty`, `DoubleProperty`                     | Lua number                                                                             |
| `EnumProperty`                                        | Underlying numeric value                                                               |
| `ObjectProperty`, `ClassProperty`, `ClassPtrProperty` | Raw `UObject` / `UClass` address, or `nil` for null                                    |
| `NameProperty`                                        | Cached name string, numeric comparison index, or `{ comparisonIndex = n, number = n }` |
| POD `StructProperty`                                  | Table keyed by reflected member name; nested POD structs are recursive                 |


Object arguments are copied as pointers. The API doesnt construct/clone/add references/manage the pointed UObject

An FName string must already exist in the validated cached name pool:

```lua
local arguments =
{ -- names must match parameter names, ok? Order irrelevant. Check the argument names beforehand
  punchStrength = 100,
  laughterAttenuationFactor = 1.5,
  funnyObject = otherObject,
}

assert( ue_callFunction(objectThis, 'Reset') ) -- no args

return ue_callFunction( objAddr, 'doTheFunny', arguments ) -- last parameter is timeout like { timeout = 1000 }
```

```lua
-- Checking parameters (don't bother with outparams, function returns them)
local functionAddress = assert( ue_findFunction('MyObjectClass_C', 'SetExampleValue') )
local metadata = assert( ue_getFunctionMetadata( functionAddress ) )

print( ('parameter buffer size: 0x%X'):format( metadata.parmsSize ) )

for name, parameter in pairs( metadata.parameters ) do

  if parameter.isParameter then
    print(
            ('%s: %s at +0x%X, size=0x%X, out=%s, return=%s')
            :format( name, tostring(parameter.propertyType), parameter.offset, parameter.size or 0, tostring(parameter.isOutParameter), tostring(parameter.isReturnParameter) )
          )
  end

end
```


```lua
return ue_callFunction( objectAddr, 'SetStateName', { NewState = 'Running', } )
-- alternatively you may pass
--[[
NewState = { comparisonIndex = existingNameIndex, number = 0, }
]]

```

Supported inline struct is supplied using its reflected member names:

```lua
local args =
{ -- ONLY Plain Old Data
  NewLocation =
  {
    X = 100.0,
    Y = 200.0,
    Z = 300.0,
  },
}

return ue_callFunction(actorThis, 'SetTargetLocation', args )
```

```lua
-- in case of no return property result.returnValue is nil.
-- outParameters is always a table and includes reflected output parameters after the call
local result, err = ue_callFunction(objectThis, 'GetExampleValue')
assert(result, err)

print('return:', result.returnValue)
for name, value in pairs(result.outParameters) do
  print('out:', name, value)
end
```

## Object queries

#### `ue_getPropertyOffset(classNameOrAddress, propertyName)`
  > Return one property offset relative for a class

```lua
local offset, err = ue_getPropertyOffset( 'GameEngine', 'TinyFont' )
assert( offset, err )
print( ('TinyFont = 0x%X'):format( offset ) )
```

#### `ue_enumObjectProperties(objectAddress)`
  > Enumerate class properties via object instance

```lua
local properties, err = ue_enumObjectProperties( worldAddr )
assert( properties, err )
```

### `ue_getObjectPropertyOffset(objectAddress, propertyName)`
  > Return one field offset via object instance

```lua
local offset, err = ue_getObjectPropertyOffset( worldAddr , 'OwningGameInstance' )
assert( offset, err )
```

## UObject property paths

### `ue_resolveObjectPropertyPath(rootObject, propertyPath)`

Parameters:
- `rootObject`: root instance addr (from which the path would start parsing)
- `propertyPath`: dot-separated string or array of segment names

Path traversal doesnt work on TArray/TMap/TSet containers or smart pointers.

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
-- If final `Player` is direct UObject ptr, read it
local playerAddr = readPointer(path.fieldAddress)
assert( playerAddr and playerAddr ~= 0, 'Player is null')
```


```lua
local path, err = ue_resolveObjectPropertyPath( worldAddr, 'OwningGameInstance.Player' )
assert(path, err)
-- it does roughly UWorld::OwningGameInstance offset > dereference OwningGameInstance UObject pointer > OwningGameInstanceClass::Player offset

print( ('UWorld::OwningGameInstance = 0x%X'):format( path.steps[1].offset ) )
print( ('OwningGameInstance::Player = 0x%X'):format( path.steps[2].offset ) )
print( ('Player field address = 0x%X'):format( path.fieldAddress ) )
```

## CE symbols

Symbols do NOT persistent by design. Call registration after each attachment.
`ue_unregisterAllOffsets()` removes every symbol created through this API.

#### `ue_registerClassOffsets(className, propertyNames, namespace)`
  > Register selected fields by class name. Pass nil for `propertyNames` to register all inherited fields. Use namespace when you need to have a prefix.

```lua
local symbols, err = ue_registerClassOffsets( 'GameEngine', { 'TinyFont', 'GameInstance' } )
assert( symbols, err )
```

### `ue_registerObjectOffsets(objectAddress, propertyNames, namespace)`
  > like ue_registerClassOffsets but via obj instance

```lua
local symbols, err = ue_registerObjectOffsets( worldAddr, { 'OwningGameInstance' } ) -- again, UClass name would be used
assert(symbols, err)
```

#### `ue_registerObjectPath(rootObject, propertyPath, namespace)`
  > Resolve the path from root & register every segment independently

```lua
local symbols, err = ue_registerObjectPath( worldThis, 'OwningGameInstance.Player', "World" ) -- World is a namespace!
-- this creates:
-- World.OwningGameInstance
-- World.OwningGameInstance.Player -- again, Player offset as relative to OwningGameInstance base, nothing else
-- let's say GWorld is UWorld*
-- then [[GWorld]+World.OwningGameInstance]+World.OwningGameInstance.Player resolves to player address (which is an object addr, it being a poitner)
assert(symbols, err)
```

#### `ue_unregisterAllOffsets()`
  > unregister all symbols created by class, object, path registration calls

#### `ue_clearCache()`
  > Clear cached UClass addrs while keeping registered CE symbols.

### Portability

- `ue_attachToTable()`
> attach the script to CE table

    > Notes: returns `true` on success,  `nil, errorMessage` on some failure


### Debug reflection

`ceUEDumper > Explore UClass/UProperty metadata` menu toggle enables partial UClass structure dissection for whatever purpuse while dissecting object properties. It's not final though and a little misleading.

Can also be set via:
```lua
ue_setReflectionMetadataVisible( true )
print( ue_isReflectionMetadataVisible() ) -- true
```
