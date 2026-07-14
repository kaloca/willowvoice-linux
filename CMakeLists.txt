cmake_minimum_required(VERSION 3.20)

project(willow-linux-bridge VERSION 0.1.0 LANGUAGES CXX)

include(CTest)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Qt6 REQUIRED COMPONENTS Core Gui)
find_package(KF6GlobalAccel REQUIRED)

add_executable(willow-dictate-ptt src/ptt/main.cpp)
target_compile_definitions(
    willow-dictate-ptt
    PRIVATE WILLOW_BRIDGE_VERSION="${PROJECT_VERSION}"
)
target_compile_options(
    willow-dictate-ptt
    PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang>:-Wall;-Wextra;-Wpedantic;-Wshadow;-Wconversion>
)
target_link_libraries(
    willow-dictate-ptt
    PRIVATE
        Qt6::Core
        Qt6::Gui
        KF6::GlobalAccel
)

if(BUILD_TESTING)
    add_test(NAME ptt-version COMMAND willow-dictate-ptt --version)
    set_tests_properties(ptt-version PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
endif()
