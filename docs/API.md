# CE UE Dumper Lua API reference

## [Initialization, engine version, layout, status](API/initialization.md)

`ue_initDumper`

`ue_detectEngineVersion`

`ue_setEngineVersion`

`ue_getEngineVersion`

`ue_setLayoutOverrides`

`ue_getLayoutOverrides`

`ue_isReady`

`ue_isNameReady`

`ue_getStatus`

## [Properties and reflection metadata](API/reflection.md)
    
`ue_findClass`

`ue_findObjectsOfClass`

`ue_findClassReferences`

`ue_findStruct`

`ue_enumProperties`

`ue_enumObjectProperties`

`ue_enumFlattenedProperties`

`ue_getPropertyOffset`

`ue_getObjectPropertyOffset`

`ue_clearCache`

## [Structure Dissect integration](API/structures.md)

`ue_createStructureFromObject`

`ue_createStructureFromType`

`ue_setStructureDissectEnabled`

`ue_isStructureDissectEnabled`

## [CE symbols, offsets, object paths](API/offsets-and-paths.md)

`ue_registerClassOffsets`

`ue_registerObjectOffsets`

`ue_registerObjectPath`

`ue_resolveObjectPropertyPath`

## [UFunction metadata, decompilation, bytecode patching](API/functions-and-bytecode.md)

`ue_enumFunctions`

`ue_findFunction`

`ue_getFunctionMetadata`

`ue_decompileFunction`

`ue_decompileClass`

`ue_patchFunction`

`ue_nopFunction`

`ue_patchFunctionOutputs`

`ue_restoreFunctionPatch`

`ue_restoreAllFunctionPatches`

`ue_getFunctionPatches`

## [UFunction invocation, Blueprint hooks](API/invocation-and-hooks.md)

`ue_callFunction`

`ue_findFunction`

`ue_getFunctionMetadata`

`ue_hookBlueprintFunction`

`ue_setBlueprintHookEnabled`

`ue_removeBlueprintHook`

`ue_removeAllBlueprintHooks`

`ue_getBlueprintHooks`

## [Cleanup, text dumps](API/cleanup-and-dumps.md)

`ue_unregisterAllOffsets`

`ue_clearCache`

`ue_dumpFNames`

`ue_dumpTypes`

`ue_dumpObjects`

## [Portability, reflection debugging](API/portability-and-debug.md)

`ue_attachToTable`

`ue_setReflectionMetadataVisible`

`ue_isReflectionMetadataVisible`

## [Persistent configuration, target layouts](API/configuration-and-persistence.md)

`ue_getConfig`

`ue_setConfig`

`ue_resetConfig`

`ue_clearSavedLayout`

`ue_replaceRegisteredSymbolsWithOffsets`

`ue_dumpTypes`

`ue_registerClassOffsets`