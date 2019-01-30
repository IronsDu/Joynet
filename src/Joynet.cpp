#include <functional>
#include <iostream>
#include <vector>
#include <string>
#include <unordered_map>
#include <cassert>
#include <chrono>
#include <thread>

#include <brynet/net/SocketLibFunction.h>
#include <brynet/utils/ox_file.h>

#include <brynet/net/EventLoop.h>
#include <brynet/net/TcpConnection.h>
#include <brynet/net/TCPService.h>
#include <brynet/net/ListenThread.h>
#include <brynet/net/Connector.h>
#include <brynet/timer/Timer.h>

#include <brynet/utils/NonCopyable.h>
#include <brynet/utils/md5calc.h>
#include <brynet/utils/SHA1.h>
#include <brynet/utils/base64.h>
#include <brynet/net/http/WebSocketFormat.h>
#include <brynet/net/SSLHelper.h>
#include <brynet/net/Any.h>

#include "lua_tinker.h"
#include "utils.h"

using namespace brynet;
using namespace brynet::net;

static lua_State* L = nullptr;

typedef int64_t SocketIDType;
typedef int64_t TimerIDType;
typedef int64_t AsyncConnectorUidType;

class LuaTcpService
{
public:
    typedef std::shared_ptr<LuaTcpService> PTR;

    LuaTcpService(int serviceID)
        :
        mServiceID(serviceID),
        mTcpService(TcpService::Create()),
        mListenThread(ListenThread::Create())
    {
    }

    TcpConnection::Ptr findTcpConnection(SocketIDType socketID)
    {
        auto it = mSockets.find(socketID);
        if (it == mSockets.end())
        {
            return nullptr;
        }
        return (*it).second;
    }

    void            addTcpConnection(SocketIDType socketID, TcpConnection::Ptr tcpConnection)
    {
        auto it = mSockets.find(socketID);
        assert(it == mSockets.end());
        mSockets[socketID] = tcpConnection;
    }

    void            removeTcpConnection(SocketIDType socketID)
    {
        auto it = mSockets.find(socketID);
        assert(it != mSockets.end());
        mSockets.erase(socketID);
    }

    SocketIDType    makeNextSocketID()
    {
        static_assert(std::is_same<SocketIDType, decltype(mSocketIDCreator.claim())>::value);
        return mSocketIDCreator.claim();
    }

    TcpService::Ptr getTcpService() const
    {
        return mTcpService;
    }

    ListenThread::Ptr   getListenThread() const
    {
        return mListenThread;
    }

    int                 getServiceID() const
    {
        return mServiceID;
    }

    SSLHelper::Ptr      getSSLHelper() const
    {
        return mSSLHelper;
    }

    void                setSSLHelper(SSLHelper::Ptr sslHelper)
    {
        mSSLHelper = sslHelper;
    }

private:
    const int                                           mServiceID;
    const TcpService::Ptr                               mTcpService;
    const ListenThread::Ptr                             mListenThread;

    SSLHelper::Ptr                                      mSSLHelper;
    Joynet::IdCreator                                   mSocketIDCreator;
    std::unordered_map<SocketIDType, TcpConnection::Ptr>   mSockets;
};

static auto monitorTime = std::chrono::system_clock::now();
static void luaRuntimeCheck(lua_State *L, lua_Debug *ar)
{
    auto nowTime = std::chrono::system_clock::now();
    if ((nowTime - monitorTime) >= std::chrono::milliseconds(10000))
    {
        /*TODO::callstack*/
        luaL_error(L, "%s", "while dead loop \n");
    }
}

class CoreDD : public brynet::utils::NonCopyable
{
public:
    CoreDD()
    {
        mTimerMgr = std::make_shared<brynet::timer::TimerMgr>();
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
            v.second->getTcpService()->stopWorkerThread();
            v.second->getListenThread()->stopListen();
        }
        mServiceList.clear();

        mAsyncConnector->stopWorkerThread();

        mTimerMgr->clear();
        mTimerList.clear();
    }

    void    createAsyncConnectorThread()
    {
        mAsyncConnector->startWorkerThread();
    }

    void    startMonitor()
    {
        monitorTime = std::chrono::system_clock::now();
    }

    int64_t getNowUnixTime()
    {
        auto now = std::chrono::system_clock::now();
        return std::chrono::system_clock::to_time_t(now);
    }

    TimerIDType startTimer(int delayMs, const std::string& callback)
    {
        static_assert(std::is_same<TimerIDType, decltype(mTimerIDCreator.claim())>::value);

        auto id = mTimerIDCreator.claim();
        auto timer = mTimerMgr->addTimer(std::chrono::milliseconds(delayMs), [=](){
            mTimerList.erase(id);
            lua_tinker::call<void>(L, callback.c_str(), id);
        });

        mTimerList[id] = timer;

        return id;
    }

    TimerIDType startLuaTimer(int delayMs, lua_tinker::luaValueRef callback)
    {
        auto id = mTimerIDCreator.claim();

        auto timer = mTimerMgr->addTimer(std::chrono::milliseconds(delayMs), [=](){

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

    void    removeTimer(TimerIDType id)
    {
        auto it = mTimerList.find(id);
        if (it != mTimerList.end())
        {
            (*it).second.lock()->cancel();
            mTimerList.erase(it);
        }
    }

    void    closeTcpSession(int serviceID, SocketIDType socketID)
    {
        auto service = findService(serviceID);
        if (service == nullptr)
        {
            return;
        }
        auto tcpConnection = service->findTcpConnection(socketID);
        if (tcpConnection != nullptr)
        {
            tcpConnection->postDisConnect();
        }
    }

    void    shutdownTcpSession(int serviceID, SocketIDType socketID)
    {
        auto service = findService(serviceID);
        if (service == nullptr)
        {
            return;
        }
        auto tcpConnection = service->findTcpConnection(socketID);
        if (tcpConnection != nullptr)
        {
            tcpConnection->postShutdown();
        }
    }

    void    sendToTcpSession(int serviceID, SocketIDType socketID, const char* data, int len)
    {
        auto service = findService(serviceID);
        if (service == nullptr)
        {
            return;
        }
        auto tcpConnection = service->findTcpConnection(socketID);
        if (tcpConnection != nullptr)
        {
            tcpConnection->send(TcpConnection::makePacket(data, len), nullptr);
        }
    }

    AsyncConnectorUidType asyncConnect(int serviceID, const char* ip, int port, int timeoutMs, bool useSSL)
    {
        static_assert(std::is_same<AsyncConnectorUidType, decltype(mAsyncConnectIDCreator.claim())>::value);

        const auto uid = mAsyncConnectIDCreator.claim();
        mAsyncConnector->asyncConnect(ip, 
            port, 
            std::chrono::milliseconds(timeoutMs), 
            [=](TcpSocket::Ptr socket) {
                addSessionToService(serviceID, std::move(socket), uid, useSSL, false);
            }, 
            [=]() {
                mLogicLoop.pushAsyncFunctor([serviceID, uid]() {
                    lua_tinker::call<void>(L, "__on_connected__", serviceID, -1, uid, false);
                });
            });
        return uid;
    }

    void    loop()
    {
        auto mill = std::chrono::duration_cast<std::chrono::milliseconds>(mTimerMgr->nearLeftTime());
        mLogicLoop.loop(mTimerMgr->isEmpty() ? 100 : mill.count());
        mTimerMgr->schedule();
    }

    int     createTCPService()
    {
        mNextServiceID++;

        auto luaTcpService = std::make_shared<LuaTcpService>(mNextServiceID);
        mServiceList[luaTcpService->getServiceID()] = luaTcpService;

        luaTcpService->getTcpService()->startWorkerThread(std::thread::hardware_concurrency());

        return luaTcpService->getServiceID();
    }

    bool    setupSSL(int serviceID,
        const std::string& certificate,
        const std::string& privatekey)
    {
        auto service = findService(serviceID);
        if (service == nullptr)
        {
            return false;
        }

#ifndef USE_OPENSSL
        return false;
#else
        if (service->getSSLHelper() != nullptr)
        {
            return false;
        }

        auto sslHelper = SSLHelper::Create();
        if (!sslHelper->initSSL(certificate, privatekey))
        {
            return false;
        }

        service->setSSLHelper(sslHelper);
        return true;
#endif
    }

    void    listen(int serviceID, const char* ip, int port, bool useSSL)
    {
        auto service = findService(serviceID);
        if (service == nullptr)
        {
            return;
        }

        auto initHandle = [=](TcpSocket::Ptr socket) {
            auto enterHandle = [=](const TcpConnection::Ptr& tcpConnection) {
                mLogicLoop.pushAsyncFunctor([=]() {
                    auto socketID = brynet::net::cast<SocketIDType>(tcpConnection->getUD());
                    lua_tinker::call<void>(L, 
                        "__on_enter__", 
                        service->getServiceID(),
                        *socketID);
                });
            };

            helpAddFD(service, std::move(socket), enterHandle, useSSL, true);
        };

        service->getListenThread()->startListen(false,
            ip,
            port,
            initHandle);
    }

private:
    bool    addSessionToService(int serviceID,
        TcpSocket::Ptr socket,
        AsyncConnectorUidType uid,
        bool useSSL,
        bool isServerSideSocket)
    {
        auto service = findService(serviceID);
        if (service == nullptr)
        {
            return false;
        }

        auto connectedCallback = [=](const TcpConnection::Ptr& tcpConnection) {
            mLogicLoop.pushAsyncFunctor([=]() {
                auto socketID = brynet::net::cast<SocketIDType>(tcpConnection->getUD());
                lua_tinker::call<void>(L, 
                    "__on_connected__", 
                    serviceID, 
                    *socketID, 
                    uid, 
                    true);
            });
        };

        return helpAddFD(service, std::move(socket), connectedCallback, useSSL, isServerSideSocket);
    }

    bool    helpAddFD(const LuaTcpService::PTR& luaTcpService, 
        TcpSocket::Ptr socket,
        std::function<void (const TcpConnection::Ptr)> callback,
        bool useSSL,
        bool isServerSideSocket)
    {
        socket->setNodelay();

        auto wrapperEnterCallback = [=](const TcpConnection::Ptr tcpConnection) {
            mLogicLoop.pushAsyncFunctor([=]() {
                auto socketID = luaTcpService->makeNextSocketID();
                luaTcpService->addTcpConnection(socketID, tcpConnection);
                tcpConnection->setUD(socketID);
            });

            callback(tcpConnection);

            auto disConnectHanale = [=](const TcpConnection::Ptr tcpConnection) {
                mLogicLoop.pushAsyncFunctor([=]() {
                    auto socketID = brynet::net::cast<SocketIDType>(tcpConnection->getUD());
                    luaTcpService->removeTcpConnection(*socketID);
                    lua_tinker::call<void>(L, 
                        "__on_close__", 
                        luaTcpService->getServiceID(),
                        *socketID);
                });
            };

            auto datahandle = [=](const char* buffer, size_t len) {
                auto data = std::string(buffer, len);
                mLogicLoop.pushAsyncFunctor([=]() {
                    auto socketID = brynet::net::cast<SocketIDType>(tcpConnection->getUD());
                    int consumeLen = lua_tinker::call<int>(L,
                        "__on_data__",
                        luaTcpService->getServiceID(),
                        *socketID,
                        data,
                        data.size());
                    assert(consumeLen >= 0);
                });

                return len;
            };
            tcpConnection->setDisConnectCallback(disConnectHanale);
            tcpConnection->setDataCallback(datahandle);
        };

        TcpService::AddSocketOption::AddSocketOptionFunc sslOption;
        if (useSSL)
        {
            if (isServerSideSocket)
            {
                if (luaTcpService->getSSLHelper() != nullptr)
                {
                    sslOption = TcpService::AddSocketOption::WithServerSideSSL(luaTcpService->getSSLHelper());
                }
            }
            else
            {
                sslOption = TcpService::AddSocketOption::WithClientSideSSL();
            }
        }
        return luaTcpService->getTcpService()->addTcpConnection(
            std::move(socket),
            sslOption,
            TcpService::AddSocketOption::WithEnterCallback(wrapperEnterCallback),
            TcpService::AddSocketOption::WithMaxRecvBufferSize(1024 * 1024));
    }

    LuaTcpService::PTR  findService(int serviceID)
    {
        auto it = mServiceList.find(serviceID);
        if (it == mServiceList.end())
        {
            return nullptr;
        }
        return (*it).second;
    }

private:
    EventLoop                                   mLogicLoop;

    Joynet::IdCreator                           mTimerIDCreator;
    brynet::timer::TimerMgr::Ptr                mTimerMgr;
    std::unordered_map<TimerIDType, brynet::timer::Timer::WeakPtr> mTimerList;

    AsyncConnector::Ptr                         mAsyncConnector;
    Joynet::IdCreator                           mAsyncConnectIDCreator;

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
        brynet::net::base::InitSocket();
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

        lua_tinker::class_def<CoreDD>(L, "asyncConnect", &CoreDD::asyncConnect);
        lua_tinker::class_def<CoreDD>(L, "setupSSL", &CoreDD::setupSSL);

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
