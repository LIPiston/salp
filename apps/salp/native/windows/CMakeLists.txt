# Build libserialport from the unmodified, hash-verified 0.1.2 source.
include(FetchContent)
FetchContent_Declare(serialport_source
  URL https://codeload.github.com/sigrokproject/libserialport/tar.gz/bc8f88ef3399b76da7992a99badebada419d0e19
  URL_HASH SHA256=8850669c1867e466d87edfbd2120bac5b35f8e6df2c330b0e77e083a52249b28
)
FetchContent_MakeAvailable(serialport_source)
add_library(serialport SHARED
  "${serialport_source_SOURCE_DIR}/serialport.c"
  "${serialport_source_SOURCE_DIR}/timing.c"
  "${serialport_source_SOURCE_DIR}/windows.c"
)
set_target_properties(serialport PROPERTIES OUTPUT_NAME libserialport)
target_compile_definitions(serialport PRIVATE LIBSERIALPORT_MSBUILD)
target_link_libraries(serialport PRIVATE setupapi)
install(TARGETS serialport RUNTIME DESTINATION bin)
install(FILES "${serialport_source_SOURCE_DIR}/COPYING"
  DESTINATION licenses/libserialport)
# Include the complete LGPL library source in the development archive.
install(DIRECTORY "${serialport_source_SOURCE_DIR}/"
  DESTINATION sources/libserialport)
