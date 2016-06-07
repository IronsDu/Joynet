source = src/Joynet.cpp\
		3rdparty/accumulation-dev/src/net/CurrentThread.cpp\
		3rdparty/accumulation-dev/src/net/DataSocket.cpp\
		3rdparty/accumulation-dev/src/net/EventLoop.cpp\
		3rdparty/accumulation-dev/src/net/SocketLibFunction.c\
		3rdparty/accumulation-dev/src/net/TCPService.cpp\
		3rdparty/accumulation-dev/src/utils/buffer.c\
		3rdparty/accumulation-dev/src/utils/connector.cpp\
		3rdparty/accumulation-dev/src/utils/fdset.c\
		3rdparty/accumulation-dev/src/utils/array.c\
		3rdparty/accumulation-dev/src/utils/systemlib.c\
		3rdparty/accumulation-dev/src/utils/md5calc.cpp\
		3rdparty/accumulation-dev/src/timer/timer.cpp\
		3rdparty/lua_tinker/lua_tinker.cpp\

Joynet:
	cd ./3rdparty/luasrc/;make generic;cp liblua.a ../../
	g++ $(source) -I./3rdparty/luasrc/ -I./3rdparty/lua_tinker/ -I./3rdparty/accumulation-dev/src/net -I./3rdparty/accumulation-dev/src/timer -I./3rdparty/accumulation-dev/src/utils -O3 -std=c++11 ./liblua.a -lpthread -lrt -o Joynet
clean : 
	find ./ -name "*.o"  | xargs rm -f
	rm -f ./Joynet
