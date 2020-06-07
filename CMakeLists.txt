cmake_minimum_required (VERSION 2.6)
project(Joynet)

if(WIN32)
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /std:c++latest")
endif()

set(lua_tinker_src_list
	${PROJECT_SOURCE_DIR}/3rdparty/lua_tinker/lua_tinker.cpp
)

include_directories("${PROJECT_SOURCE_DIR}/3rdparty/lua_tinker")
add_library(Joynet SHARED ${lua_tinker_src_list} ${PROJECT_SOURCE_DIR}/src/Joynet.cpp)

set_target_properties(Joynet PROPERTIES PREFIX "")
if(WIN32)
  target_link_libraries(Joynet ws2_32 lua)
elseif(UNIX)
  find_package(Threads REQUIRED)
  target_link_libraries(Joynet lua Threads::Threads)
endif()

set_target_properties(Joynet PROPERTIES LINKER_LANGUAGE CXX)