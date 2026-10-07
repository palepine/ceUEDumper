# CE UE Dumper Lua API reference

## Digest

| Function                                           | Description                                            |
| -------------------------------------------------- | ------------------------------------------------------ |
| `ue_initDumper(config)`                            | Blocking initialization                               |
| `ue_isReady()`                                     | Get ready status                                       |
| `ue_isNameReady()`                                 | Get cached names status                                |
| `ue_getStatus()`                                   | Get verbose dumper state                               |
| `ue_detectEngineVersion()`                         | Infer engine version and report evidence/confidence    |
| `ue_getEngineVersion()`                            | Read explicit or last detected engine version          |
| `ue_setEngineVersion(version)`                     | Select/clear engine version for the current script run  |
| `ue_getLayoutOverrides()`                          | Read caller-supplied reflection layout offsets         |
| `ue_setLayoutOverrides(layout)`                    | Supply/clear explicit reflection layout offsets        |
| `ue_getConfig(key)`                                | Read persistent script configuration                   |
| `ue_setConfig(key, value)`                         | Validate and persist one configuration value           |
| `ue_resetConfig(key)`                              | Reset one or all configuration values                  |
| `ue_clearSavedLayout()`                            | Clear current target/version reflection layout cache   |
| `ue_dumpFNames(path)`                              | Dump decoded FName strings                             |
| `ue_dumpTypes(path)`                               | Dump classes, structs, enums, fields, and functions    |
| `ue_dumpObjects(path)`                             | Dump GUObjectArray addresses, types, and paths          |
| `ue_findClass(name)`                               | Find a `UClass` by short name, eg 'GameInstance        |
| `ue_findObjectsOfClass(class, options)`            | Find live objects with an exact or derived class       |
| `ue_findClassReferences(class, options)`           | Find class fields declared with a referenced UClass    |
| `ue_enumFunctions(type)`                           | Enumerate `UFunctions` for type                        |
| `ue_findFunction(type, name)`                      | Find a specific `UFunction` for type                   |
| `ue_getFunctionMetadata(function)`                 | Get `UFunction` obj & parameter metadata               |
| `ue_decompileFunction(function, options)`          | Decompile one Blueprint function to C++ pseudocode     |
| `ue_decompileClass(type, options)`                 | Decompile directly declared functions of a type        |
| `ue_patchFunction(function, bytes, offset)`        | Apply a reversible Blueprint-bytecode patch             |
| `ue_nopFunction(function, options)`                | Replace a void Blueprint body with an immediate return  |
| `ue_patchFunctionOutputs(function, values)`        | Replace a Blueprint body with fixed output assignments  |
| `ue_restoreFunctionPatch(patch, options)`          | Restore one bytecode patch                              |
| `ue_restoreAllFunctionPatches(options)`            | Restore all active bytecode patches                     |
| `ue_getFunctionPatches(function)`                  | List active reversible patches                          |
| `ue_callFunction(this, name, arguments, options)`  | Invoke `UFunction` for an object                       |
| `ue_hookBlueprintFunction(objectPointer, name, options)` | Install a retargetable native Blueprint hook |
| `ue_enumProperties(class)`                         | Enumerate properties for class name UClass addr        |
| `ue_getPropertyOffset(class, property)`            | Resolve one property offset                            |
| `ue_enumObjectProperties(this)`                    | Enumerate class properties via object                  |
| `ue_getObjectPropertyOffset(this, property)`       | Resolve an object property offset                      |
| `ue_resolveObjectPropertyPath(this, path)`         | Enumerate by following object property path            |
| `ue_registerClassOffsets(class, names, namespace)` | Register class property symbols                        |
| `ue_registerObjectOffsets(this, names, namespace)` | Register class property symbols via object             |
| `ue_registerObjectPath(this, path, namespace)`     | Register class property symbols via obj and path       |
| `ue_replaceRegisteredSymbolsWithOffsets()`         | Convert owned symbols to their numerical values across all records |
| `ue_unregisterAllOffsets()`                        | Clear created symbols                                  |
| `ue_clearCache()`                                  | Clear cached `UClass` addresses                        |

---
---
---

# API

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


## Properties and metadata

Enumeration API returns tables keyed by reflected property name (including inherited).

| Field             | Type            | Description                                         |
| ----------------- | --------------- | --------------------------------------------------- |
| `offset`          | `number`        | Offset to the field                                 |
| `propertyAddress` | `number`        | `UProperty`/`FProperty` metadata addr               |
| `propertyType`    | `string or nil` | Reflected type (eg `ObjectProperty`)                |
| `size`            | `number or nil` | Element size (when available)                       |
| `structAddress`   | `number or nil` | `UScriptStruct` for `StructProperty`                |
| `structError`     | `string or nil` | reason for struct not being resolved                |
| `innerProperty`   | `table or nil`  | `ArrayProperty` element metadata                     |
| `elementProperty` | `table or nil`  | `SetProperty` element metadata                       |
| `keyProperty`     | `table or nil`  | `MapProperty` key metadata                           |
| `valueProperty`   | `table or nil`  | `MapProperty` value metadata                         |
| `innerError`      | `string or nil` | reason an array element descriptor was not resolved  |
| `elementError`    | `string or nil` | reason a set element descriptor was not resolved     |
| `mapError`        | `string or nil` | reason map key/value descriptors were not resolved   |
| `byteMask`        | `number or nil` | Boolean mask when that makes sense                  |


    Names ending in _number_32HexDigits have readable runtime alias with trailing suffix removed.
    
    Ordinary underscores, spaces, numeric suffixes, shorter hexadecimal strings are preserved.

    Offset queries accept clean segments or raw generated names.
    
    Ambiguous clean names within one containing type return an error.

    Different paths such as 'Settings.Blah.Foo' and 'Settings.SomethingElse.Foo' remain independent.

    Enumeration maps keep raw keys. Flattened entries add rawPath and displayPath

    The struct dissect uses displayPath. It keeps raw segments where it would be ambiguous otherwise.

    Symbol registration uses clean aliases by default. For now it validates the whole selection before replacing any symbols. Raw generated paths are available when disambiguation is needed.

---

### Meta objects retrieval

#### `ue_findClass(className)`
  > Find UClass by its name, return its address or nil

```lua
return ue_findClass('GameEngine')
```

#### `ue_findObjectsOfClass(classNameOrAddress, options)`

Find runtime `UObject` instances using UClass. Exact-class query are default
Scans all objects on every call!

```lua
local objects, err, statistics = ue_findObjectsOfClass('GameInstance')
assert(objects, err)

-- local actors, err = ue_findObjectsOfClass( 'Actor', { includeSubclasses = true, excludeDefaultObjects = true, } )
-- assert(actors, err)

for _, object in ipairs(objects) do
  print(
        ('0x%X'):format(object.objectAddress),
        object.objectName,
        object.className,
        object.objectIndex
      )
end

print('Matches:', statistics.matchedObjectCount)
```

`options` fields:

| Field                   | Default | Description |
| ----------------------- | ------- | ----------- |
| `includeSubclasses`     | `false` | Include instances whose runtime class derives from the requested class |
| `excludeDefaultObjects` | `false` | Exclude objects whose name begins with `Default__` |
| `limit`                 | `nil`   | Stop after this many results; must be a positive integer |

Each result contains:

| Field           | Description |
| --------------- | ----------- |
| `objectAddress` | Runtime `UObject*` |
| `objectIndex`   | Zero-based GUObjectArray index |
| `objectName`    | Reflected instance name |
| `classAddress`  | Actual `UClass*` |
| `className`     | Actual class name |
| `isExactClass`  | `true` when `classAddress` exactly equals the requested class |

#### `ue_findClassReferences(classNameOrAddress, options)`

Build/query reverse reflection index and return fields
whose declared type references the requested `UClass` (using metadata only)

`ue_clearCache()` also clears this reverse index.

```lua
local options =
{
  includeBaseDeclarations = true, -- fields declared as Character/Object/etc that can hold PlayerCharacter_C
  includeDerivedDeclarations = true, -- fields explicitly declared as subclasses of PlayerCharacter_C
}
local references, err, statistics = ue_findClassReferences('PlayerCharacter_C') -- suing deafult options
assert( references, err )



for _, reference in ipairs(references) do
  print(
        reference.ownerClassName,
        reference.path,
        reference.propertyType,
        reference.referencedClassName,
        reference.staticOffset
      )
end

print('Classes scanned:', statistics.scannedClassCount)
print('References indexed:', statistics.referenceCount)
```

`options` fields:

| Field                        | Default | Description |
| ---------------------------- | ------- | ----------- |
| `rebuild`                    | `false` | Discard compatible reverse index  & rebuild it |
| `includeBaseDeclarations`    | `false` | Include fields declared as an ancestor of the target; such fields can hold the target class |
| `includeDerivedDeclarations` | `false` | Include fields declared as a descendant of the target |

It follows object/class/interface references inside embedded structs,
arrays, sets, and map keys or values. Paths use these forms:

```text
DirectObject
Settings.Owner
Objects[]
ObjectSet{}
ObjectMap{Key}
ObjectMap{Value}
```

Each returned record contains:

| Field                    | Description |
| ------------------------ | ----------- |
| `ownerClassAddress`      | Declaring `UClass` address |
| `ownerClassName`         | Declaring class name |
| `propertyName`           | Referencing leaf property's reflected name |
| `propertyAddress`        | `UProperty`/`FProperty` descriptor address |
| `propertyType`           | Object, class, interface, or related property kind |
| `propertyOffset`         | Offset stored in the leaf property descriptor |
| `staticOffset`           | Complete class-relative offset for direct or embedded-struct fields; `nil` inside containers |
| `rootPropertyOffset`     | Offset of the top-level class field |
| `path`                   | Complete property/container path |
| `wrappers`               | Enclosing struct/container kinds |
| `referencedClassAddress` | Referenced `UClass` address |
| `referencedClassName`    | Referenced class name |
| `referenceMember`        | Descriptor member used: `PropertyClass`, `MetaClass`, or `InterfaceClass` |
| `referenceMemberOffset`  | Inferred offset of that member inside the property descriptor |

#### `ue_findStruct(name)`
  > For `UScriptStruct`, find UScriptStruct object via its name
```lua
return ue_findStruct('SomeGameStructure')
```

### Bulk enumeration

#### `ue_enumProperties( typeNameOrAddress )`
  > get UClass/UScriptStruct property metadata via a reflected name or UClass/UScriptStruct objects.

```lua
local properties, err = ue_enumProperties('GameEngine')
assert(properties, err)

for name, property in pairs(properties) do
  print( ('%s = 0x%X'):format( name, property.offset ) )
end
```

#### `ue_enumObjectProperties(objectAddress)`
  > get UClass property metadata via an object instance. Similar to `ue_enumProperties`.

```lua
local properties, err = ue_enumObjectProperties( worldAddr )
assert( properties, err )
```

#### `ue_enumFlattenedProperties( typeNameOrAddress )`
  > For `UScriptStruct`, return dotted names & collapsed offsets, including both struct entries and their leaves
  
    Notes: unknown/ambiguous struct types, cycles return nil, error

    Well, you can actually use it like ue_enumProperties on UClasses too, but the opposite isn't productive


### Selective enumeration

#### `ue_getPropertyOffset(typeNameOrAddress, propertyName)`
  > Return one property offset for a UClass or UScriptStruct via its name

    Notes: propertyName can also be a path for an inline struct (MyClass.FooStruct.ba.rr)

```lua
local offset, err = ue_getPropertyOffset( 'GameEngine', 'TinyFont' )
assert( offset, err )

print( ('GameEngine.TinyFont = 0x%X'):format( offset ) )

-- for a Player class that has a UScriptStruct inlined/embedded inside it
assert( ue_getPropertyOffset( 'Player', 'Settings.Cheats.GodMode' ) )

-- for a UScriptStruct named 'SomeGameStructure' that has fields Foo.bar
assert( ue_getPropertyOffset('SomeGameStructure', 'Foo.bar') )

```

#### `ue_getObjectPropertyOffset(this, path)`
  > Return one property offset for an object instance. Similar to `ue_getPropertyOffset`.

    Notes: Use dots for inlined/embedded field structures

```lua
local offset, err = ue_getObjectPropertyOffset( worldAddr , 'OwningGameInstance' )
assert( offset, err )
assert( ue_getObjectPropertyOffset( playerAddr, 'Settings.Cheats.GodMode' ) )
```





## Structure Dissecting

Toggle `ceUEDumper > Toggle Struct Guessing` to enable CE Struct Dissect to guess UObjects:
- name lookup
- struct layout
- try find base for a field

```lua
-- toggle it from lua
assert( ue_setStructureDissectEnabled(true) )
print( ue_isStructureDissectEnabled() )
assert( ue_setStructureDissectEnabled(false) )
```

#### `ue_createStructureFromObject( objectAddr )`
  > create a laid out structure for a Structure Dissect form using an object instance
```lua
local structure, structureError = ue_createStructureFromObject( gameInstance )
assert( structure, structureError )
local form = createStructureForm()
form.MainStruct = structure
form.Column[0].Address = gameInstance
```

#### `ue_createStructureFromType( typeNameOrAddress )`
  > same as `ue_createStructureFromObject` but using reflected type name

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


## UFunction meta & invoking

### UFunction meta

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

### Blueprint bytecode pseudocode

#### `ue_decompileFunction(functionAddress, options)`

Decompiles `UFunction::Script` byte array into C++ pseudocode.
Return source text. Second optional ret is the intermediate model
containing `statements`, `trace`, `errors` and parser state

```lua
local functionAddress = assert( ue_findFunction( 'BP_DamageSystem_C', 'TakeDamage' ) )

local source, modelOrError = ue_decompileFunction(functionAddress)
assert(source, modelOrError)
print(source)
```

| Option | Default | Description |
|---|---:|---|
| `includeOpcodeTrace` | `true` | Include offset/opcode/token list above the body |
| `includeMetadata` | `true` | Include UFunction, Script, and reflected-local comments |
| `includeStatementOffsets` | `true` | Prefix pseudocode statements with bytecode offsets |
| `maxInstructionCount` | `max(0x10000, Script.Num)` | Optional explicit expression safety limit |

#### `ue_decompileClass(classNameOrAddress, options)`

Decompile all functions declared directly by a `UClass`/`UScriptStruct`
Inherited functions remain attached to their declaring type.
Opcode traces arent enabled by default, `{ includeOpcodeTrace = true }` does that.

```lua
local options =
{
  includeOpcodeTrace = false,
  includeStatementOffsets = true,
}
local source, err = ue_decompileClass( 'BP_DamageSystem_C', options )

assert(source, err)
print(source)
```

### Blueprint bytecode patching

#### `ue_patchFunction(functionAddress, patchBytes, byteOffset)`
> replace raw bytes inside `UFunction::Script` array

    `byteOffset` is zero-based optional index.
    Returns a handle with original bytesused to restore original bytes

```lua
local functionAddress = assert( ue_findFunction( 'BP_ThirdPersonCharacter_C', 'ReceiveBeginPlay' ) )

local patch = assert( ue_patchFunction( functionAddress, { 0x04, 0x0B, 0x53 }, 0 ) ) -- EX_Return EX_Nothing EX_EndOfScript

assert( ue_restoreFunctionPatch(patch) ) -- reverting
```

#### `ue_nopFunction(functionAddress, options)`
> Patches a void Blueprint function to immediately return from the prologue

    `ue_nopFunction(functionAddress, { allowNonVoid = true })` ignores return property check
    making the caller accept an uninitialized result, i.e. UB

```lua
local functionAddress = assert( ue_findFunction( 'BP_ThirdPersonCharacter_C', 'ReceiveTick' ) )

local patch, patchError = ue_nopFunction(functionAddress)
assert(patch, patchError)

assert( ue_restoreFunctionPatch(patch) ) -- reverting
```

#### `ue_patchFunctionOutputs(functionAddress, outputValues)`

Replace BP function body with assignments to selected output parameters with a return followed.
Keys in `outputValues` must match the UFunction parameter names.

| Property | Lua value |
|---|---|
| `BoolProperty` | `true` or `false` |
| `ByteProperty`, `UInt8Property` | Integer from `0` through `255` |
| `IntProperty`, `Int32Property` | Signed 32-bit integer |
| `Int64Property`, `UInt64Property` | Lua integer in the corresponding range |
| `FloatProperty`, `DoubleProperty` | Lua number |
| `ObjectProperty`, `ClassProperty`, `ClassPtrProperty` | Raw address; use `0` for null |

```lua
local functionAddress = assert( ue_findFunction( 'BP_ThirdPersonCharacter_C', 'CheckStuff' ) )

local patch, patchError = ue_patchFunctionOutputs( functionAddress, { HaveBullets = true } )

assert( ue_restoreFunctionPatch(patch) ) -- restoring
```

#### ue_restoreFunctionPatch(patch, options )
> tries to safely restore a patch via a func address
`ue_restoreFunctionPatch(patch, { force = true })` or `ue_restoreAllFunctionPatches({ force = true })` to force-patch

```lua
-- all active patches
local active = ue_getFunctionPatches()
local forFunction = ue_getFunctionPatches(functionAddress)

local restoredCount, restoreError = ue_restoreAllFunctionPatches()
assert(restoredCount, restoreError)
```

### Invoking & argument passing

#### `ue_callFunction(objectAddress, functionName, arguments, options)`
  > UFunction invocation on the object with the following arguments (nil if void). Returns nil, errorMessage on failure.

    Calls are synchronous. Direct mode uses CE's remote calling thread.
    Set `options.executionThread = 'game'` to register a function to run in the game thread

    Returned table includes `functionAddress`, `processEventAddress`, `processEventSource`, `processEventVtableOffset`, `executionResult`, decoded output parameters
    `options.processEventVtableOffset` selects an explicit byte offset in the target object's vtable
    `options.processEventAddress` bypasses resolution with a known callable address
    `options.processEventMode` can be `auto`, `vtable`, `signature`, `actor-signature`
    `actor-signature` must only be used with an `AActor` instance

    Object arguments are copied as pointers. The API doesnt construct/clone/add references/manage the pointed UObject
    An FName string must already exist in the validated cached name pool

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


```lua
-- scheduling to run the function in the game thread
local options = 
{
  executionThread = 'game',
  processEventMode = 'vtable',
  processEventVtableOffset = 0x260,
  timeout = 5000,
}

return ue_callFunction( player, 'I_Do_Mess_Up_Physics', nil, options )
```
Game-thread execution options:

| Option | Meaning |
| --- | --- |
| `executionThread = 'game'` | Queue to run in the game-thread. Defaults to CE execution |
| `gameThread = true` | Alias for `executionThread = 'game'` |
| `runs = N` | Execute the function N times before returning; defaults to `1` |
| `intervalDispatches = N` | Skip N in-game-thread `ProcessEvent` executions between runs |
| `timeout = milliseconds` | Max time to wait for all requested runs |
| `bridgePath = path` | Optional explicit bridge DLL path |

The returned `executionResult` is the number of completed runs in game-thread mode.
Output parameters and the return value are read after the last run.

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

### BP function hooks

#### `ue_hookBlueprintFunction(objectPointerAddress, functionName, options)`

Hook a non-native BP function.
The first param is a pointer containing the UObject,
it must be of the same type or nullptr if overwritten

```lua
local options =
{
  -- backend = 'auto', -- hooks BP VM dispatcher
  -- allInstances = true, -- to affect all instances

  -- every condition must match
  conditions =
  {
    {
      source = 'self', -- this
      property = 'bIsDead',
      value = true  -- this->bIsDead == true
    },
    {
      parameter = 'ActionIndex',
      operation = 'eq',
      value = 3 -- ActionIndex == 3
    },
  },

  writes =
  {
    {
      result = true,
      phase = 'after', -- or 'before' to write before
      value = false
    },

    {
      parameter = 'WasHandled',
      phase = 'after',
      value = true
    },
  },
  skipOriginal = true,
}

local enemyPointer = allocateMemory(8)
writePointer( enemyPointer, enemyComponent )

local hook, err = ue_hookBlueprintFunction( enemyPointer, 'CanPerformSharedAction', options )
assert(hook, err)

-- writePointer( enemyPointer, 0 ) -- every call now falls through to original
-- update the enemy object
writePointer( enemyPointer, newEnemyComponent )

-- temp switch without destroying hook record
assert( ue_setBlueprintHookEnabled(hook, false) )
assert( ue_setBlueprintHookEnabled(hook, true) )

-- unhook and restore
assert( ue_removeBlueprintHook(hook) )
-- assert( ue_removeAllBlueprintHooks() )

-- only after removing the hook, UB otherwise
deAlloc(enemyPointer)

-- return ue_getBlueprintHooks()
```

Backend:

| `options.backend` | Behavior |
|---|---|
| `auto`/skipped | use `ProcessLocalScriptFunction` or `ProcessInternal` fallback |
| `script` | require `ProcessLocalScriptFunction` or error |
| `processInternal` | use `ProcessInternal` stored in `UFunction::Func` |
| `func` | Per-function `UFunction::Func` swap |

`scriptDispatcherAddress` can be used to pass a verified dispatcher
`frameNodeOffset` defaults to `0x08` and identifies `FFrame::Node`
`frameLocalsOffset` defaults to `0x20`

Notes:

| Form | Meaning |
|---|---|
| `{ parameter='Name', value=... }` | `FFrame::Locals + parameter offset` |
| `{ result=true, value=... }` | `RESULT_DECL` |
| `{ source='self', property='Name', value=... }` | `this->Name` |
| `{ source='self', offset=0x120, type='i32', value=... }` | Raw location |

Scalar types: `u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`, `i64`, `f32`, `f64`, `pointer`

Conditionals: `eq`, `ne`, `lt`, `le`, `gt`, `ge`, `anyBits`, `allBits`

`frameLocalsOffset` defaults to `0x20`


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


## Portability

#### `ue_attachToTable()`
> attach the script to CE table

    Notes: returns `true` on success,  `nil, errorMessage` on some failure


## Debug reflection

`ceUEDumper > Explore UClass/UProperty metadata` menu toggle enables partial UClass structure dissection for whatever purpuse while dissecting object properties. It's not final though and a little misleading.

Can also be set via:
```lua
ue_setReflectionMetadataVisible( true )
print( ue_isReflectionMetadataVisible() ) -- true
```

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