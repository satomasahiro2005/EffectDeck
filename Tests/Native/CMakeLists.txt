# Tests/Native: Sources/Shared の C を机の上で建てて試す。
#
#   cmake --preset asan && cmake --build --preset asan && ctest --preset asan
#   cmake --preset tsan && cmake --build --preset tsan && ctest --preset tsan   # ラベル tsan だけ
#   cmake --preset engine ...    # 本物の engine（Vendor/effetune + Patches）につないだ試験も足す
#
# プリセットは CMakePresets.json。サニタイザは CMAKE_C_FLAGS で渡す。
# 試験の件は各ソースの表の ET_ENTRY(名前) から拾い、1 件ずつ ctest に登録する（et_test.h）。
# 下のフォルダ（link/ や driver/）に CMakeLists.txt があれば自動で読む。
cmake_minimum_required(VERSION 3.24)
project(effectdeck_host_tests LANGUAGES C)
enable_testing()

get_filename_component(ET_REPO "${CMAKE_CURRENT_SOURCE_DIR}/../.." REALPATH)
set(ET_SHARED "${ET_REPO}/Sources/Shared")

option(ET_NATIVE_WERROR "Treat warnings in the test targets as errors" OFF)
option(ET_NATIVE_WITH_ENGINE
       "Also build pipeline_engine against the pinned, patched Vendor/effetune" OFF)

# et_native_test(<target> SOURCES <files...> [DEFINES ...] [LIBS ...] [LABELS ...]
#                [EXCLUDE_PREFIXES ...] [CASES_FROM <file>])
# 実行ファイルを 1 つ作り、CASES_FROM（既定は SOURCES の先頭）の表の ET_ENTRY(名前) を
# <target>.<名前> として ctest に登録する。EXCLUDE_PREFIXES で始まる名前は登録しない。
function(et_native_test target)
  cmake_parse_arguments(T "" "CASES_FROM" "SOURCES;DEFINES;LIBS;LABELS;EXCLUDE_PREFIXES" ${ARGN})
  add_executable(${target} ${T_SOURCES})
  set_target_properties(${target} PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON)
  target_include_directories(${target} PRIVATE "${ET_NATIVE_DIR}" "${ET_SHARED}")
  target_compile_definitions(${target} PRIVATE ${T_DEFINES})
  if(MSVC)
    target_compile_options(${target} PRIVATE /experimental:c11atomics /utf-8 /UNDEBUG /W3)
    if(ET_NATIVE_WERROR)
      target_compile_options(${target} PRIVATE /WX)
    endif()
  else()
    # assert を Release でも生かす（-UNDEBUG）。試験は ET_CHECK を使うが、元のソースの assert も効かせる。
    target_compile_options(${target} PRIVATE -UNDEBUG -Wall -Wextra)
    if(ET_NATIVE_WERROR)
      target_compile_options(${target} PRIVATE -Werror)
    endif()
    target_link_libraries(${target} PRIVATE m)
  endif()
  target_link_libraries(${target} PRIVATE ${T_LIBS})

  if(NOT T_CASES_FROM)
    list(GET T_SOURCES 0 T_CASES_FROM)
  endif()
  get_filename_component(T_CASES_FROM "${T_CASES_FROM}" ABSOLUTE)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${T_CASES_FROM}")
  file(STRINGS "${T_CASES_FROM}" entries REGEX "ET_ENTRY\\([A-Za-z0-9_]+\\)")
  set(registered 0)
  foreach(line IN LISTS entries)
    string(REGEX REPLACE ".*ET_ENTRY\\(([A-Za-z0-9_]+)\\).*" "\\1" name "${line}")
    set(skip FALSE)
    foreach(prefix IN LISTS T_EXCLUDE_PREFIXES)
      string(FIND "${name}" "${prefix}" at)
      if(at EQUAL 0)
        set(skip TRUE)
      endif()
    endforeach()
    if(NOT skip)
      add_test(NAME ${target}.${name} COMMAND ${target} ${name})
      set_tests_properties(${target}.${name} PROPERTIES LABELS "native;${T_LABELS}" TIMEOUT 300)
      math(EXPR registered "${registered} + 1")
    endif()
  endforeach()
  if(registered EQUAL 0)
    message(FATAL_ERROR "${target}: no ET_ENTRY(...) found in ${T_CASES_FROM}")
  endif()
endfunction()
set(ET_NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")

# ---- どこでも建つもの（MSVC を含む） ----------------------------------------
et_native_test(resample SOURCES resample.c "${ET_SHARED}/ETResample.c")
et_native_test(preview_tone SOURCES preview_tone.c "${ET_SHARED}/ETPreviewTone.c")
et_native_test(external_processor
  SOURCES external_processor.c "${ET_SHARED}/ETExternalProcessor.c")

# ---- ETPipeline（POSIX のスレッドと、上流の abi.h が要る） -------------------
if(NOT MSVC)
  # 作り物の engine は abi.h の型と値だけ使う。HEAD が指している Vendor/effetune の物を読む
  # （パッチが当たっていてもいなくてもよい）。submodule が無ければ場所を渡す。
  set(ET_NATIVE_ABI_INCLUDE "${ET_REPO}/Vendor/effetune/dsp/include"
      CACHE PATH "Directory that holds effetune/abi.h for the fake-engine tests")
  if(NOT EXISTS "${ET_NATIVE_ABI_INCLUDE}/effetune/abi.h")
    message(FATAL_ERROR
      "effetune/abi.h not found under ${ET_NATIVE_ABI_INCLUDE}. Run "
      "'git submodule update --init --filter=blob:none Vendor/effetune' or pass "
      "-DET_NATIVE_ABI_INCLUDE=<dir>.")
  endif()
  set(THREADS_PREFER_PTHREAD_FLAG ON)
  find_package(Threads REQUIRED)
  set(ET_PIPELINE_SOURCES fake_engine.c "${ET_SHARED}/ETPipeline.c"
      "${ET_SHARED}/ETExternalProcessor.c")

  # パッチの当たった engine（外部ノードを descriptor の位置で呼ぶ）。
  et_native_test(pipeline_cb SOURCES pipeline.c ${ET_PIPELINE_SOURCES}
    DEFINES ET_FAKE_EXTERNAL_CALLBACK=1 LIBS Threads::Threads EXCLUDE_PREFIXES legacy_)
  # 旧来の engine（et_pipeline_set_external_callback が無く、弱い参照が NULL になる）。
  et_native_test(pipeline_legacy SOURCES pipeline.c ${ET_PIPELINE_SOURCES}
    DEFINES ET_FAKE_EXTERNAL_CALLBACK=0 LIBS Threads::Threads EXCLUDE_PREFIXES cb_)
  if(APPLE)
    # ld64 は定義の無い weak_import も未解決として止めるので、実行時に探すと伝える。
    # （ここでは試していない。Linux の ELF weak は何もしなくても NULL に解ける）
    target_link_options(pipeline_legacy PRIVATE "LINKER:-U,_et_pipeline_set_external_callback")
  endif()
  # UI と音のスレッドのすれ違い。tsan プリセットはこのラベルだけ走らせる。
  et_native_test(pipeline_threads SOURCES pipeline_threads.c ${ET_PIPELINE_SOURCES}
    DEFINES ET_FAKE_EXTERNAL_CALLBACK=1 LIBS Threads::Threads LABELS tsan)
  foreach(t pipeline_cb pipeline_legacy pipeline_threads)
    target_include_directories(${t} PRIVATE "${ET_NATIVE_ABI_INCLUDE}")
  endforeach()
endif()

# ---- 本物の engine（任意。-DET_NATIVE_WITH_ENGINE=ON） -----------------------
# HEAD の gitlink が指す版を Tools/golden/extract_pin.sh で取り出し、setup.sh と同じ 4 本の
# パッチを build の下の写しに当てて建てる。作業ツリーの Vendor/effetune には触らない。
# ET_NATIVE_EFFETUNE_ROOT に展開済みの場所（dsp/ を含む）を渡せば取り出しは省く。
if(ET_NATIVE_WITH_ENGINE)
  if(MSVC)
    message(FATAL_ERROR "ET_NATIVE_WITH_ENGINE is POSIX-only")
  endif()
  enable_language(CXX)
  set(ET_NATIVE_EFFETUNE_ROOT "" CACHE PATH "Pinned upstream extract (contains dsp/)")
  set(root "${ET_NATIVE_EFFETUNE_ROOT}")
  if(NOT root)
    find_program(ET_BASH bash REQUIRED)
    execute_process(
      COMMAND "${ET_BASH}" "${ET_REPO}/Tools/golden/extract_pin.sh" "${CMAKE_BINARY_DIR}/pin"
      OUTPUT_VARIABLE root ERROR_VARIABLE err RESULT_VARIABLE rc
      OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(NOT rc EQUAL 0)
      message(FATAL_ERROR "extract_pin.sh failed (${rc}): ${err}")
    endif()
  endif()
  if(NOT EXISTS "${root}/dsp/CMakeLists.txt")
    message(FATAL_ERROR "no dsp/CMakeLists.txt under ${root}")
  endif()

  set(patches abi-begin-ptr effetune-external-node effetune-external-latency
      effetune-external-routing)
  set(stamp "${root}")
  if(EXISTS "${root}/.pin")
    file(READ "${root}/.pin" pin)
    string(APPEND stamp " pin=${pin}")
  endif()
  foreach(p IN LISTS patches)
    file(SHA256 "${ET_REPO}/Patches/${p}.diff" hash)
    string(APPEND stamp " ${p}=${hash}")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${ET_REPO}/Patches/${p}.diff")
  endforeach()
  set(patched "${CMAKE_BINARY_DIR}/effetune-patched")
  set(old "")
  if(EXISTS "${patched}/.stamp")
    file(READ "${patched}/.stamp" old)
  endif()
  if(NOT old STREQUAL stamp)
    find_package(Git REQUIRED)
    file(REMOVE_RECURSE "${patched}")
    file(MAKE_DIRECTORY "${patched}")
    file(COPY "${root}/dsp" DESTINATION "${patched}")
    foreach(p IN LISTS patches)
      # build が作業ツリーの中にあっても、外側のリポジトリを見に行かせない
      # （見つけると差分の道をリポジトリの根から読んでしまう）。
      execute_process(
        COMMAND "${CMAKE_COMMAND}" -E env "GIT_CEILING_DIRECTORIES=${CMAKE_BINARY_DIR}"
                "${GIT_EXECUTABLE}" apply --ignore-space-change --ignore-whitespace
                "${ET_REPO}/Patches/${p}.diff"
        WORKING_DIRECTORY "${patched}" RESULT_VARIABLE rc ERROR_VARIABLE err)
      if(NOT rc EQUAL 0)
        message(FATAL_ERROR "Patches/${p}.diff does not apply to ${root}: ${err}")
      endif()
    endforeach()
    file(WRITE "${patched}/.stamp" "${stamp}")
  endif()

  set(BUILD_TESTING OFF)   # 上流の試験は建てない（dsp.yml の仕事）
  add_subdirectory("${patched}/dsp" "${CMAKE_BINARY_DIR}/effetune-dsp" EXCLUDE_FROM_ALL)
  # 本物の abi.h（パッチ済み）は effetune_dsp_core の PUBLIC include から来る。
  # Debug では上流の -Wl,--wrap=malloc（音のスレッドで確保したら止める）も付いてくる。
  et_native_test(pipeline_engine
    SOURCES pipeline_engine.c "${ET_SHARED}/ETPipeline.c" "${ET_SHARED}/ETExternalProcessor.c"
    LIBS effetune_dsp_core LABELS engine)
  set_target_properties(pipeline_engine PROPERTIES LINKER_LANGUAGE CXX)
endif()

# ---- 下のフォルダ（別の包みが持つ link/ driver/ など） -----------------------
file(GLOB ET_NATIVE_SUBDIRS CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*/CMakeLists.txt")
foreach(f IN LISTS ET_NATIVE_SUBDIRS)
  get_filename_component(d "${f}" DIRECTORY)
  add_subdirectory("${d}")
endforeach()
