cmake_minimum_required(VERSION 3.12)
project(NearbyAudioDriver CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(NearbyAudioDriver MODULE Driver.cpp)
target_sources(NearbyAudioDriver PRIVATE
    ../third_party/libASPL-LICENSE.txt
    ../third_party/libASPL-Apple-2012-LICENSE.txt
    ../third_party/libASPL-Apple-2020-LICENSE.txt)
set_source_files_properties(
    ../third_party/libASPL-LICENSE.txt
    ../third_party/libASPL-Apple-2012-LICENSE.txt
    ../third_party/libASPL-Apple-2020-LICENSE.txt
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
target_include_directories(NearbyAudioDriver PRIVATE "${ASPL_PREFIX}/include")
target_link_libraries(NearbyAudioDriver PRIVATE "${ASPL_PREFIX}/lib/libASPL.a" "-framework CoreFoundation")
set_target_properties(NearbyAudioDriver PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION driver
    PREFIX ""
    SUFFIX ""
    MACOSX_BUNDLE ON
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    MACOSX_BUNDLE_BUNDLE_NAME "NearbyAudioDriver"
    MACOSX_BUNDLE_GUI_IDENTIFIER "local.nearbyaudio.driver"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
    MACOSX_BUNDLE_BUNDLE_VERSION "1")

enable_testing()
add_executable(NearbyAudioDriverTests DriverTests.cpp)
target_compile_options(NearbyAudioDriverTests PRIVATE -UNDEBUG)
target_include_directories(NearbyAudioDriverTests PRIVATE "${ASPL_PREFIX}/include")
target_link_libraries(NearbyAudioDriverTests PRIVATE "${ASPL_PREFIX}/lib/libASPL.a" "-framework CoreFoundation")
add_test(NAME NearbyAudioDriverTests COMMAND NearbyAudioDriverTests)
