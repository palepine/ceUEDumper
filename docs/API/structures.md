# Structure Dissect integration

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


