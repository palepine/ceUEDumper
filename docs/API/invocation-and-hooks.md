# UFunction invocation and Blueprint hooks

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



