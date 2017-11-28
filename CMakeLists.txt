cmake_minimum_required (VERSION 2.6)
project(Joynet)

if(WIN32)
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /std:c++latest")
endif()

set(net_src_list
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/net/EventLoop.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/net/CurrentThread.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/net/DataSocket.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/net/ListenThread.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/net/SocketLibFunction.c
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/net/TCPService.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/net/WrapTCPService.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/net/Connector.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/net/fdset.c
)

set(timer_src_list
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/timer/Timer.cpp
)

set(base_src_list
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/utils/array.c
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/utils/buffer.c
)

set(utils_src_list
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/utils/base64.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/utils/md5calc.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/utils/SHA1.cpp
	${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/brynet/utils/ox_file.cpp
)

include_directories("${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/")
include_directories("${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/")
include_directories("${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/")
include_directories("${PROJECT_SOURCE_DIR}/3rdparty/brynet/src/")


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