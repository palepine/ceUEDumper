# Properties and reflection metadata

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






