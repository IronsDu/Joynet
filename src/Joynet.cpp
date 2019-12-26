#include <functional>
#include <iostream>
#include <vector>
#include <string>
#include <unordered_map>
#include <cassert>
#include <chrono>
#include <thread>

#include <brynet/net/SocketLibFunction.hpp>

#include <brynet/net/EventLoop.hpp>
#include <brynet/net/TcpConnection.hpp>
#include <brynet/net/TcpService.hpp>
#include <brynet/net/ListenThread.hpp>
#include <brynet/net/AsyncConnector.hpp>
#include <brynet/base/Timer.hpp>

#include <brynet/base/NonCopyable.hpp>
#include <brynet/base/crypto/SHA1.hpp>
#include <brynet/base/crypto/Base64.hpp>
#include <brynet/net/http/WebSocketFormat.hpp>
#include <brynet/net/SSLHelper.hpp>
#include <brynet/base/Any.hpp>

#include "lua_tinker.h"
#include "utils.h"

using namespace brynet;
using namespace brynet::net;

static lua_State* L = nullptr;

typedef int64_t SocketIDType;
typedef int64_t TimerIDType;
typedef int64_t AsyncConnectorUidType;

class LuaTcpService final
{
public:
    typedef std::shared_ptr<LuaTcpService> PTR;

    LuaTcpService(int serviceID)
        :
        mServiceID(serviceID),
        mTcpService(TcpService::Create())
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

    void    setListenThread(ListenThread::Ptr listenThread)
    {
        mListenThread = listenThread;
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
    ListenThread::Ptr                                   mListenThread;

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

class CoreDD final : public brynet::base::NonCopyable
{
public:
    CoreDD()
    {
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
            const auto& service = v.second;
            service->getTcpService()->stopWorkerThread();
            if (service->getListenThread())
            {
                service->getListenThread()->stopListen();
            }
        }
        mServiceList.clear();

        mAsyncConnector->stopWorkerThread();

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
        auto timer = mLogicLoop.runAfter(std::chrono::milliseconds(delayMs), [=](){
            mTimerList.erase(id);
            lua_tinker::call<void>(L, callback.c_str(), id);
        });

        mTimerList[id] = timer;

        return id;
    }

    TimerIDType startLuaTimer(int delayMs, lua_tinker::luaValueRef callback)
    {
        auto id = mTimerIDCreator.claim();

        auto timer = mLogicLoop.runAfter(std::chrono::milliseconds(delayMs), [=](){

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

    AsyncConnectorUidType asyncConnect(int serviceID, 
        const char* ip, 
        int port, 
        int timeoutMs, 
        bool useSSL)
    {
        static_assert(std::is_same<AsyncConnectorUidType, decltype(mAsyncConnectIDCreator.claim())>::value);

        const auto uid = mAsyncConnectIDCreator.claim();
        mAsyncConnector->asyncConnect({
                ConnectOption::WithAddr(ip, port),
                ConnectOption::WithTimeout(std::chrono::milliseconds(timeoutMs)),
                ConnectOption::WithCompletedCallback([=](TcpSocket::Ptr socket) {
                    addSessionToService(serviceID, std::move(socket), uid, useSSL, false);
                }),
                ConnectOption::WithFailedCallback([=]() {
                    mLogicLoop.runAsyncFunctor([serviceID, uid]() {
                        lua_tinker::call<void>(L, "__on_connected__", serviceID, -1, uid, false);
                    });
                }),
            });
        return uid;
    }

    void    loop()
    {
        mLogicLoop.loopCompareNearTimer(100);
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
                mLogicLoop.runAsyncFunctor([=]() {
                    auto socketID = brynet::base::cast<SocketIDType>(tcpConnection->getUD());
                    lua_tinker::call<void>(L, 
                        "__on_enter__", 
                        service->getServiceID(),
                        *socketID);
                });
            };

            helpAddFD(service, std::move(socket), enterHandle, useSSL, true);
        };

        auto listenThread = brynet::net::ListenThread::Create(false, ip, port, initHandle);
        listenThread->startListen();
        service->setListenThread(listenThread);
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
            mLogicLoop.runAsyncFunctor([=]() {
                auto socketID = brynet::base::cast<SocketIDType>(tcpConnection->getUD());
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
            mLogicLoop.runAsyncFunctor([=]() {
                auto socketID = luaTcpService->makeNextSocketID();
                luaTcpService->addTcpConnection(socketID, tcpConnection);
                tcpConnection->setUD(socketID);
            });

            callback(tcpConnection);

            auto disConnectHanale = [=](const TcpConnection::Ptr tcpConnection) {
                mLogicLoop.runAsyncFunctor([=]() {
                    auto socketID = brynet::base::cast<SocketIDType>(tcpConnection->getUD());
                    luaTcpService->removeTcpConnection(*socketID);
                    lua_tinker::call<void>(L, 
                        "__on_close__", 
                        luaTcpService->getServiceID(),
                        *socketID);
                });
            };

            auto datahandle = [=](const char* buffer, size_t len) {
                auto data = std::string(buffer, len);
                mLogicLoop.runAsyncFunctor([=]() {
                    auto socketID = brynet::base::cast<SocketIDType>(tcpConnection->getUD());
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

#ifdef BRYNET_USE_OPENSSL
        detail::AddSocketOptionFunc sslOption;
        if (useSSL)
        {
            if (isServerSideSocket)
            {
                if (luaTcpService->getSSLHelper() != nullptr)
                {
                    sslOption = AddSocketOption::WithServerSideSSL(luaTcpService->getSSLHelper());
                }
            }
            else
            {
                sslOption = AddSocketOption::WithClientSideSSL();
            }
        }
        return luaTcpService->getTcpService()->addTcpConnection(
            std::move(socket),
            sslOption,
            AddSocketOption::AddEnterCallback(wrapperEnterCallback),
            AddSocketOption::WithMaxRecvBufferSize(1024 * 1024));
#else

        return luaTcpService->getTcpService()->addTcpConnection(
            std::move(socket),
            AddSocketOption::AddEnterCallback(wrapperEnterCallback),
            AddSocketOption::WithMaxRecvBufferSize(1024 * 1024));
#endif
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
    std::unordered_map<TimerIDType, brynet::base::Timer::WeakPtr> mTimerList;

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

        lua_tinker::def(L, "GetIPOfHost", Joynet::GetIPOfHost);
        lua_tinker::def(L, "UtilsWsHandshakeResponse", Joynet::UtilsWsHandshakeResponse);
    #ifdef USE_ZLIB
        lua_tinker::def(L, "ZipUnCompress", Joynet::ZipUnCompress);
    #endif

        return 1;
    }
}
