# LocalLink の線の形式と受け手の溜まりの方針（Sources/Shared/ETLinkCodec.c）。
# Tests/Native の CMakeLists.txt が下のフォルダとして読む。建てるのは親から:
#   cd Tests/Native && cmake --preset asan && cmake --build --preset asan && ctest --preset asan
# 登録は親の et_native_test（ET_ENTRY(名前) を 1 件ずつ ctest へ。1 件も無ければ止まる）。
cmake_minimum_required(VERSION 3.24)
if(NOT COMMAND et_native_test)
  message(FATAL_ERROR "Configure Tests/Native, not Tests/Native/link on its own")
endif()

et_native_test(link_codec SOURCES link_codec.c "${ET_SHARED}/ETLinkCodec.c" LABELS link)
et_native_test(link_jitter SOURCES link_jitter.c "${ET_SHARED}/ETLinkCodec.c" LABELS link)
# et_check.h（et_test.h に値を出す CHECK を足したもの）はこのフォルダにある。
foreach(t link_codec link_jitter)
  target_include_directories(${t} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
endforeach()
