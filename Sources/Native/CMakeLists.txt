cmake_minimum_required(VERSION 3.19)
project(EcruInk LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
include(FetchContent)
if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()
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

# Preserve source page streams when older PDFKit re-encodes the annotation export.
include(ExternalProject)
set(ECRU_JPEG_SOURCE "${CMAKE_BINARY_DIR}/_deps/libjpeg_turbo-src")
set(ECRU_JPEG_BUILD "${CMAKE_BINARY_DIR}/_deps/libjpeg_turbo-build")
file(MAKE_DIRECTORY "${ECRU_JPEG_SOURCE}" "${ECRU_JPEG_BUILD}")
ExternalProject_Add(ecru_jpeg
  URL https://codeload.github.com/libjpeg-turbo/libjpeg-turbo/tar.gz/c85e6b905bf237038faa936dab160ebfc5da0344
  URL_HASH SHA256=45209a3f315ed6156dac8d7fa451b8be62d83f2daa5581cb6b94ee9f3f82cf6f
  SOURCE_DIR "${ECRU_JPEG_SOURCE}" BINARY_DIR "${ECRU_JPEG_BUILD}"
  CMAKE_ARGS -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES=${CMAKE_OSX_ARCHITECTURES}
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_SIMD=OFF
  BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target jpeg-static -j 6
  INSTALL_COMMAND ""
  BUILD_BYPRODUCTS "${ECRU_JPEG_BUILD}/libjpeg.a")
add_library(ecru_jpeg_static STATIC IMPORTED GLOBAL)
set_target_properties(ecru_jpeg_static PROPERTIES IMPORTED_LOCATION "${ECRU_JPEG_BUILD}/libjpeg.a")
add_dependencies(ecru_jpeg_static ecru_jpeg)
# Never discover a host-only Homebrew JPEG/zlib in a cross-architecture build.
set(PKG_CONFIG_EXECUTABLE /usr/bin/false CACHE FILEPATH "" FORCE)
execute_process(COMMAND xcrun --show-sdk-path OUTPUT_VARIABLE ECRU_MACOS_SDK OUTPUT_STRIP_TRAILING_WHITESPACE)
set(ZLIB_H_PATH "${ECRU_MACOS_SDK}/usr/include" CACHE STRING "" FORCE)
set(ZLIB_LIB_PATH "${ECRU_MACOS_SDK}/usr/lib/libz.tbd" CACHE STRING "" FORCE)
set(LIBJPEG_H_PATH "${ECRU_JPEG_SOURCE}/src;${ECRU_JPEG_BUILD}" CACHE STRING "" FORCE)
set(LIBJPEG_LIB_PATH ecru_jpeg_static CACHE STRING "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_STATIC_LIBS ON CACHE BOOL "" FORCE)
set(BUILD_DOC OFF CACHE BOOL "" FORCE)
set(USE_IMPLICIT_CRYPTO OFF CACHE BOOL "" FORCE)
set(REQUIRE_CRYPTO_NATIVE ON CACHE BOOL "" FORCE)
FetchContent_Declare(qpdf
  URL https://codeload.github.com/qpdf/qpdf/tar.gz/4eba95899886e851cc41d76886483b347612f2a8
  URL_HASH SHA256=c6de7611d2651ac71eebbabd0132b1dc13e8def0e4e640e791190f903490c799)
FetchContent_MakeAvailable(qpdf)
add_dependencies(libqpdf_object ecru_jpeg)
add_dependencies(libqpdf ecru_jpeg)
target_sources(EcruInk PRIVATE PDFPagePreservation.cc)
target_link_libraries(EcruInk PRIVATE libqpdf ecru_jpeg_static)
