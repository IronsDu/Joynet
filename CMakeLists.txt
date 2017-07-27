cmake_minimum_required (VERSION 2.6)
project(Joynet)

if(WIN32)
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /std:c++latest")
elseif(UNIX)
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++17")
endif()

set(net_src_list
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/net/EventLoop.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/net/CurrentThread.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/net/DataSocket.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/net/SocketLibFunction.c
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/net/TCPService.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/net/WrapTCPService.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/net/Connector.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/net/fdset.c
)

set(timer_src_list
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/timer/Timer.cpp
)

set(base_src_list
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/utils/array.c
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/utils/buffer.c
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/utils/systemlib.c
)

set(utils_src_list
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/utils/base64.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/utils/md5calc.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/utils/SHA1.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/utils/ox_file.cpp
)

include_directories("${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/net")
include_directories("${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/timer")
include_directories("${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/utils")
include_directories("${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/net/http")


set(lua_tinker_src_list
	${PROJECT_SOURCE_DIR}/3rdparty/lua_tinker/lua_tinker.cpp
)

include_directories("${PROJECT_SOURCE_DIR}/3rdparty/lua_tinker")
include_directories("${PROJECT_SOURCE_DIR}/3rdparty/zlib")
include_directories("${PROJECT_SOURCE_DIR}/3rdparty/lualib")

link_directories("${PROJECT_SOURCE_DIR}/3rdparty/lualib")
link_directories("${PROJECT_SOURCE_DIR}/3rdparty/zlib")

add_library(Joynet SHARED ${net_src_list} ${timer_src_list} ${base_src_list} ${lua_tinker_src_list} ${utils_src_list} ${PROJECT_SOURCE_DIR}/src/Joynet.cpp)

set_target_properties(Joynet PROPERTIES PREFIX "")
if(WIN32)
  target_link_libraries(Joynet ws2_32 libz.lib lua53.lib)
elseif(UNIX)
  find_package(Threads REQUIRED)
  target_link_libraries(Joynet Threads::Threads)
endif()

set_target_properties(Joynet PROPERTIES LINKER_LANGUAGE CXX)