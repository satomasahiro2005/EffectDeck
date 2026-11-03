# ドライバのゼロタイムスタンプ（Sources/Extension/ETZeroTimeStamp.c）。
# Tests/Native の CMakeLists.txt が下のフォルダとして読む。建てるのは親から:
#   cd Tests/Native && cmake --preset asan && cmake --build --preset asan && ctest --preset asan
# 登録は親の et_native_test（ET_ENTRY(名前) を 1 件ずつ ctest へ。1 件も無ければ止まる）。
cmake_minimum_required(VERSION 3.24)
if(NOT COMMAND et_native_test)
  message(FATAL_ERROR "Configure Tests/Native, not Tests/Native/driver on its own")
endif()

set(ET_DRIVER_EXT "${ET_REPO}/Sources/Extension")
et_native_test(driver_zero_timestamp
  SOURCES zero_timestamp.c "${ET_DRIVER_EXT}/ETZeroTimeStamp.c" LABELS driver)
# 検査の書き方（et_check.h）は link と共有する。
target_include_directories(driver_zero_timestamp PRIVATE
  "${ET_DRIVER_EXT}" "${CMAKE_CURRENT_SOURCE_DIR}/../link")
