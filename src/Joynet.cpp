#include <functional>
#include <iostream>
#include <vector>
#include <string>
#include <unordered_map>
#include <cassert>

#include "systemlib.h"
#include "SocketLibFunction.h"
#include "ox_file.h"

#include "EventLoop.h"
#include "DataSocket.h"
#include "TCPService.h"
#include "MsgQueue.h"
#include "Connector.h"

#include "lua_tinker.h"
#include "NonCopyable.h"
#include "md5calc.h"
#include "SHA1.h"
#include "base64.h"
#include "http/WebSocketFormat.h"
#include "utils.h"

using namespace brynet;
using namespace brynet::net;

static lua_State* L = nullptr;

struct LuaTcpService
{
    typedef std::shared_ptr<LuaTcpService> PTR;

    LuaTcpService()
    {
        mTcpService = TcpService::Create();
    }

    int                                             mServiceID;
    TcpService::PTR                                 mTcpService;
};

static int64_t monitorTime = ox_getnowtime();
static void luaRuntimeCheck(lua_State *L, lua_Debug *ar)
{
    int64_t nowTime = ox_getnowtime();
    if ((nowTime - monitorTime) >= 5000)
    {
        /*TODO::callstack*/
        luaL_error(L, "%s", "while dead loop \n");
    }
}

class CoreDD : public NonCopyable
{
public:
    CoreDD()
    {
        mTimerMgr = std::make_shared<TimerMgr>();
        mNextServiceID = 0;
        mAsyncConnector = AsyncConnector::Create();

        createAsyncConnectorThread();
    }

    ~CoreDD()
    {
        destroy();
    }

    void    destroy()
    {
        for (auto& v : mServiceList)
        {
            v.second->mTcpService->closeService();
        }
        mServiceList.clear();

        mAsyncConnector->destroy();

        mTimerMgr->clear();
        mTimerList.clear();
    }

    void    createAsyncConnectorThread()
    {
        mAsyncConnector->startThread([this](sock fd, const std::any& uid){
            pushAsyncConnectorResult(fd, uid);
        }, [this](const std::any& uid) {
            pushAsyncConnectorResult(-1, uid);
        });
    }

    void    pushAsyncConnectorResult(sock fd, const std::any& uid)
    {
        auto puid = std::any_cast<int64_t>(&uid);
        assert(puid != nullptr);
        if (puid != nullptr)
        {
            mLogicLoop.pushAsyncProc([fd, uid = *puid]() {
                lua_tinker::call<void>(L, "__on_async_connectd__", fd, uid);
            });
        }
    }

    void    startMonitor()
    {
        monitorTime = ox_getnowtime();
    }

    int64_t getNowUnixTime()
    {
        return ox_getnowtime();
    }

    int64_t startTimer(int delayMs, const std::string& callback)
    {
        auto id = mTimerIDCreator.claim();

        auto timer = mTimerMgr->addTimer(delayMs, [=](){
            mTimerList.erase(id);
            lua_tinker::call<void>(L, callback.c_str(), id);
        });

        mTimerList[id] = timer;

        return id;
    }

    int64_t startLuaTimer(int delayMs, lua_tinker::luaValueRef callback)
    {
        auto id = mTimerIDCreator.claim();

        auto timer = mTimerMgr->addTimer(delayMs, [=](){

            mTimerList.erase(id);

            lua_State *__L = callback.L;
            if (__L == nullptr)
            {
                __L = L;
            }

            int __oldtop = lua_gettop(__L); 
            lua_pushcclosure(__L, lua_tinker::on_error, 0);
            int errfunc = lua_gettop(__L);
            lua_rawgeti(__L, LUA_REGISTRYINDEX, callback.rindex);
            if (lua_isfunction(__L, -1))
            {
                lua_pcall(__L, 0, 0, errfunc);
            }
            lua_remove(__L, errfunc);

            lua_settop(__L,__oldtop);
            lua_tinker::releaseLuaValueRef(callback);
        });

        mTimerList[id] = timer;

        return id;
    }

    void    removeTimer(int64_t id)
    {
        auto it = mTimerList.find(id);
        if (it != mTimerList.end())
        {
            (*it).second.lock()->cancel();
            mTimerList.erase(it);
        }
    }

    void    closeTcpSession(int serviceID, int64_t socketID)
    {
        auto it = mServiceList.find(serviceID);
        if (it != mServiceList.end())
        {
            auto& service = (*it).second;
            service->mTcpService->disConnect(socketID);
        }
    }

    void    shutdownTcpSession(int serviceID, int64_t socketID)
    {
        auto it = mServiceList.find(serviceID);
        if (it != mServiceList.end())
        {
            (*it).second->mTcpService->shutdown(socketID);
        }
    }

    void    sendToTcpSession(int serviceID, int64_t socketID, const char* data, int len)
    {
        auto it = mServiceList.find(serviceID);
        if (it != mServiceList.end())
        {
            (*it).second->mTcpService->send(socketID, DataSocket::makePacket(data, len), nullptr);
        }
    }

    bool    addSessionToService(int serviceID, sock fd, int64_t uid, bool useSSL)
    {
        auto ret = false;

        auto it = mServiceList.find(serviceID);
        if (it != mServiceList.end())
        {
            ox_socket_nodelay(fd);
            auto serviceID = (*it).second->mServiceID;
            auto& service = (*it).second->mTcpService;
            ret = service->addDataSocket(fd, [=](int64_t id, const std::string& ip){
                mLogicLoop.pushAsyncProc([this, serviceID, id, uid]() {
                    lua_tinker::call<void>(L, "__on_connected__", serviceID, id, uid);
                });

            }, service->getDisconnectCallback(), service->getDataCallback(), useSSL, 1024 * 1024, false);
        }

        return ret;
    }

    int64_t asyncConnect(const char* ip, int port, int timeout)
    {
        auto id = mAsyncConnectIDCreator.claim();
        mAsyncConnector->asyncConnect(ip, port, timeout, id);
        return id;
    }

    void    loop()
    {
        mLogicLoop.loop(mTimerMgr->isEmpty() ? 100 : mTimerMgr->nearEndMs());
        mTimerMgr->schedule();
    }

    int     createTCPService()
    {
        mNextServiceID++;

        auto luaTcpService = std::make_shared<LuaTcpService>();
        luaTcpService->mServiceID = mNextServiceID;
        mServiceList[luaTcpService->mServiceID] = luaTcpService;

        luaTcpService->mTcpService->startWorkerThread(ox_getcpunum());

        luaTcpService->mTcpService->setEnterCallback([=](int64_t id, const std::string& ip){
            mLogicLoop.pushAsyncProc([serviceID = luaTcpService->mServiceID, id, this]() {
                lua_tinker::call<void>(L, "__on_enter__", serviceID, id);
            });
        });

        luaTcpService->mTcpService->setDisconnectCallback([=](int64_t id){
            mLogicLoop.pushAsyncProc([serviceID = luaTcpService->mServiceID, id, this]() {
                lua_tinker::call<void>(L, "__on_close__", serviceID, id);
            });
        });

        luaTcpService->mTcpService->setDataCallback([=](int64_t id, const char* buffer, size_t len){
            mLogicLoop.pushAsyncProc([serviceID = luaTcpService->mServiceID, id, this, data = std::string(buffer, len)]() {
                int consumeLen = lua_tinker::call<int>(L, "__on_data__", serviceID, id, data, data.size());
                assert(consumeLen >= 0);
            });
            return len;
        });

        return luaTcpService->mServiceID;
    }

    void    listen(int serviceID, const char* ip, int port)
    {
        auto it = mServiceList.find(serviceID);
        if (it != mServiceList.end())
        {
            (*it).second->mTcpService->startListen(false, ip, port, 1024 * 1024, nullptr, nullptr);
        }
    }

private:
    EventLoop                                   mLogicLoop;

    Joynet::IdCreator                           mTimerIDCreator;
    TimerMgr::PTR                               mTimerMgr;
    std::unordered_map<int64_t, Timer::WeakPtr> mTimerList;

    Joynet::IdCreator                           mAsyncConnectIDCreator;
    AsyncConnector::PTR                         mAsyncConnector;

    std::unordered_map<int, LuaTcpService::PTR> mServiceList;
    int                                         mNextServiceID;
};

extern "C"
{

#ifndef _MSC_VER
#else
__declspec(dllexport)
#endif

    int luaopen_Joynet(lua_State *L)
    {
        ::L = L;
        ox_socket_init();
    #ifdef USE_OPENSSL
        SSL_library_init();
        OpenSSL_add_all_algorithms();
        SSL_load_error_strings();
    #endif

        lua_tinker::init(L);

        /*lua_sethook(L, luaRuntimeCheck, LUA_MASKLINE, 0);*/

        lua_tinker::class_add<CoreDD>(L, "JoynetCore");
        lua_tinker::class_con<CoreDD>(L, lua_tinker::constructor<CoreDD>);

        lua_tinker::class_def<CoreDD>(L, "startMonitor", &CoreDD::startMonitor);
        lua_tinker::class_def<CoreDD>(L, "getNowUnixTime", &CoreDD::getNowUnixTime);

        lua_tinker::class_def<CoreDD>(L, "loop", &CoreDD::loop);

        lua_tinker::class_def<CoreDD>(L, "createTCPService", &CoreDD::createTCPService);
        lua_tinker::class_def<CoreDD>(L, "listen", &CoreDD::listen);


        lua_tinker::class_def<CoreDD>(L, "startTimer", &CoreDD::startTimer);
        lua_tinker::class_def<CoreDD>(L, "startLuaTimer", &CoreDD::startLuaTimer);
        lua_tinker::class_def<CoreDD>(L, "removeTimer", &CoreDD::removeTimer);

        lua_tinker::class_def<CoreDD>(L, "shutdownTcpSession", &CoreDD::shutdownTcpSession);
        lua_tinker::class_def<CoreDD>(L, "closeTcpSession", &CoreDD::closeTcpSession);
        lua_tinker::class_def<CoreDD>(L, "sendToTcpSession", &CoreDD::sendToTcpSession);

        lua_tinker::class_def<CoreDD>(L, "addSessionToService", &CoreDD::addSessionToService);
        lua_tinker::class_def<CoreDD>(L, "asyncConnect", &CoreDD::asyncConnect);

        lua_tinker::def(L, "UtilsSha1", Joynet::luaSha1);
        lua_tinker::def(L, "UtilsMd5", Joynet::luaMd5);
        lua_tinker::def(L, "GetIPOfHost", Joynet::GetIPOfHost);
        lua_tinker::def(L, "UtilsCreateDir", ox_dir_create);
        lua_tinker::def(L, "UtilsWsHandshakeResponse", Joynet::UtilsWsHandshakeResponse);
    #ifdef USE_ZLIB
        lua_tinker::def(L, "ZipUnCompress", Joynet::ZipUnCompress);
    #endif

        return 1;
    }
}
