# Unreal Engine Dumper

A standalone, portable Unreal Engine reflection dumper for Cheat Engine with Lua API inspired by GDDumper.


## Functionality

Currently supports
- Resolving offsets using UClass/runtime UObjects
- Registering the said offsets as symbols accordingly
- UFunction invocation & enumeration  (both experimental)
- Uniform Struct dissector
- Portability

## Installation

Copy and merge the `autorun` folder into the root Cheat Engine directory.

## Usage

- When installed, run Cheat Engine
- Attach to an UE process
- `ceUEDumper` menu item should appear at the top
- Choose `Initialize UE reflection` to launch the scanner
- (optional) choose `Attach to table` to embed the script to the Cheat Table as files

An embedded copy can be loaded using this Lua script (lua script table or via a memrec AutoAssemble script)
```lua
local function loadScriptFromTable(fileName)
  if isNullOrNil(fileName) then error('Filename invalid') end
  local tableFile = findTableFile( fileName )
  if tableFile == nil then error('No script file found') end
  local fileStream = tableFile.getData()
  local scriptString = readStringLocal(fileStream.Memory, fileStream.Size)
  if scriptString == nil then error('Script not loaded from file') end
  local doScript = loadstring(scriptString)
  if type(doScript) == 'function' then
    return doScript()
  else
    error('Script not parsed')
  end
end

loadScriptFromTable('ceUEDumper')
```

## API

See the [currenly supported Lua API reference](docs/API.md).


## Trying it out

Provided CE is attached to a supported UE process, you may initialize and test the script with:
```lua
createThread(
  function()
    print("will take a while")

    local ready, err = ue_initDumper( { timeout = 120000 } )
    assert( ready, err )

    print("im ok")

    local offset, offsetError = ue_getPropertyOffset( 'GameEngine', 'TinyFont' )
    assert( offset, offsetError )

    print( ('GameEngine.TinyFont = 0x%X'):format(offset) )
  end
)
```

You can quickly resolve offsets (or sequences of offsets) with some runtime obj instance like `UWorld`:
```lua
local world = readPointer( "pGWorld" )
local path, pathError = ue_resolveObjectPropertyPath( world, 'OwningGameInstance.LocalPlayers' )
-- you can go deeper with 'OwningGameInstance.SettingClass.GraphicsClass.fpsLimitField'
assert( path, pathError )

print( ('UWorld::OwningGameInstance = 0x%X'):format( path.steps[1].offset ) )
print( ('OwningGameInstance::LocalPlayers = 0x%X'):format( path.steps[2].offset ) )
```

## Status

The script is WIP, but most of the features are fairly consistent. More to come!

It's generally expected the script would function with the mainstream UE4/5 engine compiled targets.

This scripts supports UE4/5 x64 targets.

The core script is based on the Dark Byte's UnrealEngineTools implementation that's been extended and refactored (with the help of LLM tools).

Any feedback and contribution is welcomed!


## Support

If you find the script useful, [consider supporting me here so I keep improving the tool](https://ko-fi.com/vesperpallens)

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/R6R813UKCL)


## License

This project is released under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
