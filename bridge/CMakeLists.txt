cmake_minimum_required( VERSION 3.23 )

project( ceUEDumper LANGUAGES CXX )

include(CTest)

if( NOT WIN32 OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8 )
  message( FATAL_ERROR "ceUEDumperBridge supports Win x64 targets only" )
endif()

add_library(ceUEDumperBridge SHARED
  src/Bridge.cpp
)

target_compile_features( ceUEDumperBridge PRIVATE cxx_std_20 )

target_include_directories(ceUEDumperBridge PUBLIC
  include
)

target_compile_definitions(ceUEDumperBridge PRIVATE
  WIN32_LEAN_AND_MEAN
  NOMINMAX
  CEUEDUMPER_BRIDGE_EXPORTS
)

if(MSVC)
  target_compile_options(ceUEDumperBridge PRIVATE
    /W4
    /permissive-
    /EHsc
  )
  
  set_property(TARGET ceUEDumperBridge PROPERTY
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
  )

endif()

set_target_properties(ceUEDumperBridge PROPERTIES
  OUTPUT_NAME "ceUEDumperBridge"
  PREFIX ""
)

if(BUILD_TESTING)
  add_executable(ceUEDumperBridgeTests
    tests/BridgeTests.cpp
  )

  target_compile_features( ceUEDumperBridgeTests PRIVATE cxx_std_20 )

  target_link_libraries(ceUEDumperBridgeTests PRIVATE
    ceUEDumperBridge
  )

  if(MSVC)
    target_compile_options(ceUEDumperBridgeTests PRIVATE
      /W4
      /permissive-
      /EHsc
    )

    set_property(TARGET ceUEDumperBridgeTests PROPERTY
      MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
    )

  endif()

  add_test(NAME ceUEDumperBridgeTests
    COMMAND ceUEDumperBridgeTests
  )

endif()