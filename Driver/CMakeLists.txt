cmake_minimum_required(VERSION 3.12)
project(ShenglinDriver CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(ShenglinDriver MODULE Driver.cpp)
target_sources(ShenglinDriver PRIVATE
    ../third_party/libASPL-LICENSE.txt
    ../third_party/libASPL-Apple-2012-LICENSE.txt
    ../third_party/libASPL-Apple-2020-LICENSE.txt)
set_source_files_properties(
    ../third_party/libASPL-LICENSE.txt
    ../third_party/libASPL-Apple-2012-LICENSE.txt
    ../third_party/libASPL-Apple-2020-LICENSE.txt
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
target_include_directories(ShenglinDriver PRIVATE "${ASPL_PREFIX}/include")
target_link_libraries(ShenglinDriver PRIVATE "${ASPL_PREFIX}/lib/libASPL.a" "-framework CoreFoundation")
set_target_properties(ShenglinDriver PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION driver
    PREFIX ""
    SUFFIX ""
    MACOSX_BUNDLE ON
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    MACOSX_BUNDLE_BUNDLE_NAME "ShenglinDriver"
    MACOSX_BUNDLE_GUI_IDENTIFIER "local.shenglin.driver"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
    MACOSX_BUNDLE_BUNDLE_VERSION "1")

enable_testing()
add_executable(ShenglinDriverTests DriverTests.cpp)
target_compile_options(ShenglinDriverTests PRIVATE -UNDEBUG)
target_include_directories(ShenglinDriverTests PRIVATE "${ASPL_PREFIX}/include")
target_link_libraries(ShenglinDriverTests PRIVATE "${ASPL_PREFIX}/lib/libASPL.a" "-framework CoreFoundation")
add_test(NAME ShenglinDriverTests COMMAND ShenglinDriverTests)
