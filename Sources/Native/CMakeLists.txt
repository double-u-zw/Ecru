cmake_minimum_required(VERSION 3.19)
project(EcruInk LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
include(FetchContent)
set(ABSL_PROPAGATE_CXX_STD ON)
FetchContent_Declare(abseil-cpp
  GIT_REPOSITORY https://github.com/abseil/abseil-cpp.git
  GIT_TAG 5650e9cf76d3be4318d5fa3af38ee483ddfd5e4a)
FetchContent_MakeAvailable(abseil-cpp)
set(INK_STROKE_MODELER_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(INK_STROKE_MODELER_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory(../../ThirdParty/ink-stroke-modeler ink-stroke-modeler)
add_library(EcruInk STATIC InkModelerBridge.cc)
target_link_libraries(EcruInk PRIVATE InkStrokeModeler::stroke_modeler)
target_include_directories(EcruInk PRIVATE ../../ThirdParty/ink-stroke-modeler)

include(../../ThirdParty/google-ink/sources.cmake)
# Position is modeled once in the bridge; upstream PassthroughModel keeps it.
add_library(GoogleInk STATIC ${GOOGLE_INK_SOURCES})
target_include_directories(GoogleInk PUBLIC ../../ThirdParty/google-ink)
target_link_libraries(GoogleInk PUBLIC absl::absl_check absl::absl_log absl::status absl::statusor absl::status_macros absl::strings absl::str_format absl::flat_hash_map absl::flat_hash_set absl::btree absl::inlined_vector absl::time absl::synchronization)
target_sources(EcruInk PRIVATE GoogleInkBridge.cc)
target_link_libraries(EcruInk PRIVATE GoogleInk)

file(SHA256 "${CMAKE_CURRENT_SOURCE_DIR}/AdaptivePositionModel.h" ECRU_POSITION_SHA256)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/EcruInkBuild.h" "#define ECRU_POSITION_SHA256 \"${ECRU_POSITION_SHA256}\"\n")
target_include_directories(EcruInk PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
