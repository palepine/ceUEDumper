# UFunction metadata, decompilation, and bytecode patching

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


