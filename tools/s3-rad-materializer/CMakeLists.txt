cmake_minimum_required(VERSION 3.16)

project(s3_rad_materializer VERSION 0.1.0 LANGUAGES CXX)

option(S3_RAD_BUILD_TESTS "Build the RAD prelude parser tests" ON)

find_package(Threads REQUIRED)
find_package(ZLIB REQUIRED)
find_package(OpenSSL REQUIRED)
find_package(CURL REQUIRED)
find_package(AWSSDK REQUIRED COMPONENTS s3)

add_library(rad_prelude STATIC
    src/rad_prelude.cpp
)
target_include_directories(rad_prelude PUBLIC include)
target_compile_features(rad_prelude PUBLIC cxx_std_17)
target_compile_options(rad_prelude PRIVATE -Wall -Wextra -Wpedantic)

add_executable(s3-rad-materialize
    src/main.cpp
    src/s3_materializer.cpp
)
target_include_directories(s3-rad-materialize PRIVATE include)
target_compile_features(s3-rad-materialize PRIVATE cxx_std_17)
target_compile_options(s3-rad-materialize PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(s3-rad-materialize PRIVATE
    rad_prelude
    Threads::Threads
    ${AWSSDK_LINK_LIBRARIES}
)

install(TARGETS s3-rad-materialize RUNTIME DESTINATION bin)

if(S3_RAD_BUILD_TESTS)
    enable_testing()
    add_executable(rad-prelude-tests tests/rad_prelude_test.cpp)
    target_compile_features(rad-prelude-tests PRIVATE cxx_std_17)
    target_link_libraries(rad-prelude-tests PRIVATE rad_prelude)
    add_test(NAME rad-prelude-tests COMMAND rad-prelude-tests)
endif()
