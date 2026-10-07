# Portability and reflection debugging

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


