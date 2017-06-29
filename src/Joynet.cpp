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

#ifdef USE_ZLIB
#include "zlib.h"
#endif

using namespace brynet;
using namespace brynet::net;

static lua_State* L = nullptr;

class IdCreator : public NonCopyable
{
public:
    IdCreator()
    {
        mIncID = 0;
    }

    int64_t claim()
    {
        int64_t id = 0;
        id |= (ox_getnowtime() / 1000 << 32);
        id |= (mIncID++);

        return id;
    }

private:
    int32_t     mIncID;
};

struct AsyncConnectResult
{
    sock fd;
    int64_t uid;
};

enum class NetMsgType
{
    NMT_ENTER,      /*链接进入*/
    NMT_CLOSE,      /*链接断开*/
    NMT_RECV_DATA,  /*收到消息*/
    NMT_CONNECTED,  /*向外建立的链接*/
};

struct NetMsg
{
    NetMsg(int serviceID, NetMsgType type, int64_t id) : mServiceID(serviceID), mType(type), mID(id)
    {
    }

    void        setData(const char* data, size_t len)
    {
        mData = std::string(data, len);
    }

    int         mServiceID;
    NetMsgType  mType;
    int64_t     mID;
    std::string mData;
};

struct LuaTcpSession
{
    typedef std::shared_ptr<LuaTcpSession> PTR;

    int64_t         mID;
    std::string     mRecvData;
};

struct LuaTcpService
{
    typedef std::shared_ptr<LuaTcpService> PTR;

    LuaTcpService()
    {
        mTcpService = TcpService::Create();
    }

    int                                             mServiceID;
    TcpService::PTR                                 mTcpService;
    std::unordered_map<int64_t, LuaTcpSession::PTR> mSessions;
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
        mAsyncConnector = ThreadConnector::Create();

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
            v.second->mSessions.clear();
        }
        mServiceList.clear();

        mAsyncConnector->destroy();

        mAsyncConnectResultList.clear();
        mNetMsgList.clear();

        mTimerMgr->clear();
        mTimerList.clear();
    }

    void    createAsyncConnectorThread()
    {
        mAsyncConnector->startThread([this](sock fd, const std::any& uid){
            auto puid = std::any_cast<int64_t>(&uid);
            assert(puid != nullptr);
            if (puid != nullptr)
            {
                mAsyncConnectResultList.push(AsyncConnectResult{ fd, *puid });
                mAsyncConnectResultList.forceSyncWrite();
                mLogicLoop.wakeup();
            }
        });
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
            auto sessionIT = service->mSessions.find(socketID);
            if (sessionIT != service->mSessions.end())
            {
                service->mTcpService->disConnect(socketID);
                service->mSessions.erase(sessionIT);
            }
        }
    }

    void    shutdownTcpSession(int serviceID, int64_t socketID)
    {
        auto it = mServiceList.find(serviceID);
        if (it != mServiceList.end())
        {
            auto& service = (*it).second;
            auto sessionIT = service->mSessions.find(socketID);
            if (sessionIT != service->mSessions.end())
            {
                service->mTcpService->shutdown(socketID);
            }
        }
    }

    void    sendToTcpSession(int serviceID, int64_t socketID, const char* data, int len)
    {
        auto it = mServiceList.find(serviceID);
        if (it != mServiceList.end())
        {
            auto& service = (*it).second;
            auto sessionIT = service->mSessions.find(socketID);
            if (sessionIT != service->mSessions.end())
            {
                service->mTcpService->send(socketID, DataSocket::makePacket(data, len), nullptr);
            }
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
            ret = service->addDataSocket(fd, [=](int64_t id, std::string ip){
                auto uidStr = std::to_string(uid);
                pushMsg(serviceID, NetMsgType::NMT_CONNECTED, id, uidStr.c_str(), uidStr.size());

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

        processNetMsg();
        processAsyncConnectResult();

        mTimerMgr->schedule();
    }

    int     createTCPService()
    {
        mNextServiceID++;

        auto luaTcpService = std::make_shared<LuaTcpService>();
        luaTcpService->mServiceID = mNextServiceID;
        mServiceList[luaTcpService->mServiceID] = luaTcpService;

        luaTcpService->mTcpService->startWorkerThread(ox_getcpunum(), [=](EventLoop::PTR eventLoop){
            /*每帧回调函数里强制同步rwlist*/
            lockMsgList();
            mNetMsgList.forceSyncWrite();
            unlockMsgList();

            if (mNetMsgList.sharedListSize() > 0)
            {
                mLogicLoop.wakeup();
            }
        });

        luaTcpService->mTcpService->setEnterCallback([=](int64_t id, std::string ip){
            pushMsg(luaTcpService->mServiceID, NetMsgType::NMT_ENTER, id);
        });

        luaTcpService->mTcpService->setDisconnectCallback([=](int64_t id){
            pushMsg(luaTcpService->mServiceID, NetMsgType::NMT_CLOSE, id);
        });

        luaTcpService->mTcpService->setDataCallback([=](int64_t id, const char* buffer, size_t len){
            pushMsg(luaTcpService->mServiceID, NetMsgType::NMT_RECV_DATA, id, buffer, len);
            return len;
        });

        return luaTcpService->mServiceID;
    }

    void    listen(int serviceID, const char* ip, int port)
    {
        auto it = mServiceList.find(serviceID);
        if (it != mServiceList.end())
        {
            auto& service = (*it).second;
            service->mTcpService->startListen(false, ip, port, 1024 * 1024, nullptr, nullptr);
        }
    }

private:
    void    pushMsg(int serviceID, NetMsgType type, int64_t id, const char* data = nullptr, size_t dataLen = 0)
    {
        auto msg = std::make_shared<NetMsg>(serviceID, type, id);
        if (data != nullptr)
        {
            msg->setData(data, dataLen);
        }

        lockMsgList();
        mNetMsgList.push(std::move(msg));
        unlockMsgList();

        mLogicLoop.wakeup();
    }

    void    lockMsgList()
    {
        mNetMsgMutex.lock();
    }

    void    unlockMsgList()
    {
        mNetMsgMutex.unlock();
    }

    void    processNetMsg()
    {
        mNetMsgList.syncRead(0);

        std::shared_ptr<NetMsg> msg = nullptr;
        while (mNetMsgList.popFront(msg))
        {
            if (msg->mType == NetMsgType::NMT_ENTER)
            {
                auto luaSocket = std::make_shared<LuaTcpSession>();
                mServiceList[msg->mServiceID]->mSessions[msg->mID] = luaSocket;

                lua_tinker::call<void>(L, "__on_enter__", msg->mServiceID, msg->mID);
            }
            else if (msg->mType == NetMsgType::NMT_CLOSE)
            {
                mServiceList[msg->mServiceID]->mSessions.erase(msg->mID);
                lua_tinker::call<void>(L, "__on_close__", msg->mServiceID, msg->mID);
            }
            else if (msg->mType == NetMsgType::NMT_RECV_DATA)
            {
                bool isFind = false;

                auto serviceIT = mServiceList.find(msg->mServiceID);
                if (serviceIT != mServiceList.end())
                {
                    auto it = (*serviceIT).second->mSessions.find(msg->mID);
                    if (it != (*serviceIT).second->mSessions.end())
                    {
                        isFind = true;

                        auto& client = (*it).second;
                        client->mRecvData += msg->mData;

                        int consumeLen = lua_tinker::call<int>(L, "__on_data__", msg->mServiceID, msg->mID, client->mRecvData, client->mRecvData.size());
                        assert(consumeLen >= 0);
                        if (consumeLen == client->mRecvData.size())
                        {
                            client->mRecvData.clear();
                        }
                        else
                        {
                            client->mRecvData.erase(0, consumeLen);
                        }
                    }
                }

                assert(isFind);
                if (!isFind)
                {
                    std::cout << "not found session id" << msg->mID << std::endl;
                }
            }
            else if (msg->mType == NetMsgType::NMT_CONNECTED)
            {
                auto luaSocket = std::make_shared<LuaTcpSession>();
                mServiceList[msg->mServiceID]->mSessions[msg->mID] = luaSocket;
                int64_t uid = strtoll(msg->mData.c_str(), NULL, 10);
                lua_tinker::call<void>(L, "__on_connected__", msg->mServiceID, msg->mID, uid);
            }
            else
            {
                assert(false);
            }
        }
    }

    void    processAsyncConnectResult()
    {
        mAsyncConnectResultList.syncRead(0);

        AsyncConnectResult result;
        while (mAsyncConnectResultList.popFront(result))
        {
            lua_tinker::call<void>(L, "__on_async_connectd__", (int)result.fd, result.uid);
        }
    }

private:
    std::mutex                                  mNetMsgMutex;
    MsgQueue<std::shared_ptr<NetMsg>>           mNetMsgList;

    EventLoop                                   mLogicLoop;

    IdCreator                                   mTimerIDCreator;
    TimerMgr::PTR                               mTimerMgr;
    std::unordered_map<int64_t, Timer::WeakPtr> mTimerList;

    IdCreator                                   mAsyncConnectIDCreator;
    ThreadConnector::PTR                        mAsyncConnector;
    MsgQueue<AsyncConnectResult>                mAsyncConnectResultList;

    std::unordered_map<int, LuaTcpService::PTR> mServiceList;
    int                                         mNextServiceID;
};

static std::string luaSha1(const std::string& str)
{
    CSHA1 sha1;
    sha1.Update((unsigned char*)str.c_str(), str.size());
    sha1.Final();
    return std::string((char*)sha1.m_digest, sizeof(sha1.m_digest));
}

static std::string luaMd5(const char* str)
{
    char digest[1024];
    memset(digest, 0, sizeof(digest));
    MD5_String(str, digest);
    return std::string((const char*)digest, 32);
}

static std::string luaBase64(const std::string& str)
{
    return base64_encode((const unsigned char *)str.c_str(), str.size());
}

static std::string GetIPOfHost(const std::string& host)
{
    std::string ret;

    struct hostent *hptr = gethostbyname(host.c_str());
    if (hptr != NULL)
    {
        if (hptr->h_addrtype == AF_INET)
        {
            char* lll = *(hptr->h_addr_list);
            char tmp[1024];
            sprintf(tmp, "%d.%d.%d.%d", lll[0] & 0x00ff, lll[1] & 0x00ff, lll[2] & 0x00ff, lll[3] & 0x00ff);
            ret = tmp;
        }
    }

    return ret;
}

static std::string UtilsWsHandshakeResponse(const std::string& sec)
{
    return WebSocketFormat::wsHandshake(sec);
}

#ifdef USE_ZLIB
static std::string ZipUnCompress(const char* src, size_t len)
{
    static const size_t tmpLen = 64 * 1204 * 1024;
    static char* tmp = new char[tmpLen];

    int err = 0;
    z_stream d_stream = { 0 }; /* decompression stream */
    static char dummy_head[2] = {
        0x8 + 0x7 * 0x10,
        (((0x8 + 0x7 * 0x10) * 0x100 + 30) / 31 * 31) & 0xFF,
    };
    d_stream.zalloc = NULL;
    d_stream.zfree = NULL;
    d_stream.opaque = NULL;
    d_stream.next_in = (Bytef*)src;
    d_stream.avail_in = 0;
    d_stream.next_out = (Bytef*)tmp;

    if (inflateInit2(&d_stream, MAX_WBITS + 16) != Z_OK) return std::string();

    size_t ndata = tmpLen;
    while (d_stream.total_out < ndata && d_stream.total_in < len) {
        d_stream.avail_in = d_stream.avail_out = 1; /* force small buffers */
        if ((err = inflate(&d_stream, Z_NO_FLUSH)) == Z_STREAM_END) break;
        if (err != Z_OK) {
            if (err == Z_DATA_ERROR) {
                d_stream.next_in = (Bytef*)dummy_head;
                d_stream.avail_in = sizeof(dummy_head);
                if ((err = inflate(&d_stream, Z_NO_FLUSH)) != Z_OK) {
                    return std::string();
                }
            }
            else return std::string();
        }
    }
    if (inflateEnd(&d_stream) != Z_OK) return std::string();
    ndata = d_stream.total_out;

    return std::string(tmp, ndata);
}

#endif

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

        lua_tinker::def(L, "UtilsSha1", luaSha1);
        lua_tinker::def(L, "UtilsMd5", luaMd5);
        lua_tinker::def(L, "GetIPOfHost", GetIPOfHost);
        lua_tinker::def(L, "UtilsCreateDir", ox_dir_create);
        lua_tinker::def(L, "UtilsWsHandshakeResponse", UtilsWsHandshakeResponse);
    #ifdef USE_ZLIB
        lua_tinker::def(L, "ZipUnCompress", ZipUnCompress);
    #endif

        lua_tinker::set(L, "CoreDD", new CoreDD());

        return 1;
    }
}
