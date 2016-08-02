#include <functional>
#include <iostream>
#include <vector>
#include <string>

#include "systemlib.h"
#include "SocketLibFunction.h"
#include "ox_file.h"

#include "EventLoop.h"
#include "DataSocket.h"
#include "TCPService.h"
#include "msgqueue.h"
#include "connector.h"

#include "lua_tinker.h"
#include "NonCopyable.h"
#include "md5calc.h"
#include "SHA1.h"
#include "base64.h"
#include "http/WebSocketFormat.h"

#ifdef USE_ZLIB
#include "zlib.h"
#endif

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
    int     mIncID;
};

struct AsyncConnectResult
{
    sock fd;
    int64_t uid;
};

enum NetMsgType
{
    NMT_ENTER,      /*链接进入*/
    NMT_CLOSE,      /*链接断开*/
    NMT_RECV_DATA,  /*收到消息*/
    NMT_CONNECTED,  /*向外建立的链接*/
};

struct NetMsg
{
    NetMsg(int serviceID, NetMsgType t, int64_t id) : mServiceID(serviceID), mType(t), mID(id)
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

struct lua_State* L = nullptr;

struct LuaTcpSession
{
    typedef std::shared_ptr<LuaTcpSession> PTR;

    int64_t mID;
    std::string recvData;
};

struct LuaTcpService
{
    typedef std::shared_ptr<LuaTcpService> PTR;

    LuaTcpService()
    {
        mTcpService = std::make_shared<TcpService>();
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
        mAsyncConnector = std::make_shared<ThreadConnector>([this](sock fd, int64_t uid){
            AsyncConnectResult tmp = { fd, uid };
            mAsyncConnectResultList.Push(tmp);
            mAsyncConnectResultList.ForceSyncWrite();
            mLogicLoop.wakeup();
        });

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

        mTimerMgr->Clear();
        mTimerList.clear();
    }

    void    createAsyncConnectorThread()
    {
        mAsyncConnector->startThread();
    }

    void    startMonitor()
    {
        monitorTime = ox_getnowtime();
    }

    int64_t getNowUnixTime()
    {
        return ox_getnowtime();
    }

    int64_t startTimer(int delayMs, const char* callback)
    {
        int64_t id = mTimerIDCreator.claim();

        std::string cb = callback;
        Timer::WeakPtr timer = mTimerMgr->AddTimer(delayMs, [=](){
            mTimerList.erase(id);
            lua_tinker::call<void>(L, cb.c_str(), id);
        });

        mTimerList[id] = timer;

        return id;
    }

    void    removeTimer(int64_t id)
    {
        auto it = mTimerList.find(id);
        if (it != mTimerList.end())
        {
            (*it).second.lock()->Cancel();
            mTimerList.erase(it);
        }
    }

    void    closeTcpSession(int serviceID, int64_t socketID)
    {
        auto it = mServiceList.find(serviceID);
        if (it != mServiceList.end())
        {
            auto service = (*it).second;
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
            auto service = (*it).second;
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
            auto service = (*it).second;
            auto sessionIT = service->mSessions.find(socketID);
            if (sessionIT != service->mSessions.end())
            {
                service->mTcpService->send(socketID, DataSocket::makePacket(data, len), nullptr);
            }
        }
    }

    bool    addSessionToService(int serviceID, sock fd, int64_t uid, bool useSSL)
    {
        bool ret = false;

        auto it = mServiceList.find(serviceID);
        if (it != mServiceList.end())
        {
            ox_socket_nodelay(fd);
            LuaTcpService::PTR t = (*it).second;
            auto service = (*it).second->mTcpService;
            ret = service->addDataSocket(fd, [=](int64_t id, std::string ip){
                NetMsg* msg = new NetMsg(t->mServiceID, NMT_CONNECTED, id);
                std::string uidStr = std::to_string(uid);
                msg->setData(uidStr.c_str(), uidStr.size());
                lockMsgList();
                mNetMsgList.Push(msg);
                unlockMsgList();

                mLogicLoop.wakeup();
            }, service->getDisconnectCallback(), service->getDataCallback(), useSSL, 1024 * 1024, false);
        }

        return ret;
    }

    int64_t asyncConnect(const char* ip, int port, int timeout)
    {
        int64_t id = mAsyncConnectIDCreator.claim();
        mAsyncConnector->asyncConnect(ip, port, timeout, id);
        return id;
    }

    void    loop()
    {
        mLogicLoop.loop(mTimerMgr->IsEmpty() ? 100 : mTimerMgr->NearEndMs());

        processNetMsg();
        processAsyncConnectResult();

        mTimerMgr->Schedule();
    }

    int     createTCPService()
    {
        mNextServiceID++;
        LuaTcpService::PTR luaTcpService = std::make_shared<LuaTcpService>();
        luaTcpService->mServiceID = mNextServiceID;
        mServiceList[luaTcpService->mServiceID] = luaTcpService;

        luaTcpService->mTcpService->startWorkerThread(ox_getcpunum(), [=](EventLoop& l){
            /*每帧回调函数里强制同步rwlist*/
            lockMsgList();
            mNetMsgList.ForceSyncWrite();
            unlockMsgList();

            if (mNetMsgList.SharedListSize() > 0)
            {
                mLogicLoop.wakeup();
            }
        });

        luaTcpService->mTcpService->setEnterCallback([=](int64_t id, std::string ip){
            NetMsg* msg = new NetMsg(luaTcpService->mServiceID, NMT_ENTER, id);
            lockMsgList();
            mNetMsgList.Push(msg);
            unlockMsgList();

            mLogicLoop.wakeup();
        });

        luaTcpService->mTcpService->setDisconnectCallback([=](int64_t id){
            NetMsg* msg = new NetMsg(luaTcpService->mServiceID, NMT_CLOSE, id);
            lockMsgList();
            mNetMsgList.Push(msg);
            unlockMsgList();

            mLogicLoop.wakeup();
        });

        luaTcpService->mTcpService->setDataCallback([=](int64_t id, const char* buffer, size_t len){
            NetMsg* msg = new NetMsg(luaTcpService->mServiceID, NMT_RECV_DATA, id);
            msg->setData(buffer, len);
            lockMsgList();
            mNetMsgList.Push(msg);
            unlockMsgList();

            return len;
        });

        return luaTcpService->mServiceID;
    }

    void    listen(int serviceID, const char* ip, int port)
    {
        auto it = mServiceList.find(serviceID);
        if (it != mServiceList.end())
        {
            auto service = (*it).second;
            service->mTcpService->startListen(false, ip, port, 1024 * 1024, nullptr, nullptr);
        }
    }

private:
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
        mNetMsgList.SyncRead(0);
        NetMsg* msg = nullptr;
        while (mNetMsgList.PopFront(&msg))
        {
            if (msg->mType == NMT_ENTER)
            {
                LuaTcpSession::PTR luaSocket = std::make_shared<LuaTcpSession>();
                mServiceList[msg->mServiceID]->mSessions[msg->mID] = luaSocket;

                lua_tinker::call<void>(L, "__on_enter__", msg->mServiceID, msg->mID);
            }
            else if (msg->mType == NMT_CLOSE)
            {
                mServiceList[msg->mServiceID]->mSessions.erase(msg->mID);
                lua_tinker::call<void>(L, "__on_close__", msg->mServiceID, msg->mID);
            }
            else if (msg->mType == NMT_RECV_DATA)
            {
                bool isFind = false;

                auto serviceIT = mServiceList.find(msg->mServiceID);
                if (serviceIT != mServiceList.end())
                {
                    auto it = (*serviceIT).second->mSessions.find(msg->mID);
                    if (it != (*serviceIT).second->mSessions.end())
                    {
                        isFind = true;

                        auto client = (*it).second;
                        client->recvData += msg->mData;

                        int consumeLen = lua_tinker::call<int>(L, "__on_data__", msg->mServiceID, msg->mID, client->recvData, client->recvData.size());
                        client->recvData.erase(0, consumeLen);
                    }
                }

                assert(isFind);
                if (!isFind)
                {
                    std::cout << "not found session id" << msg->mID << std::endl;
                }
            }
            else if (msg->mType == NMT_CONNECTED)
            {
                LuaTcpSession::PTR luaSocket = std::make_shared<LuaTcpSession>();
                mServiceList[msg->mServiceID]->mSessions[msg->mID] = luaSocket;
                int64_t uid = strtoll(msg->mData.c_str(), NULL, 10);
                lua_tinker::call<void>(L, "__on_connected__", msg->mServiceID, msg->mID, uid);
            }
            else
            {
                assert(false);
            }

            delete msg;
            msg = nullptr;
        }
    }

    void    processAsyncConnectResult()
    {
        mAsyncConnectResultList.SyncRead(0);
        AsyncConnectResult result;
        while (mAsyncConnectResultList.PopFront(&result))
        {
            lua_tinker::call<void>(L, "__on_async_connectd__", (int)result.fd, result.uid);
        }
    }
private:

    std::mutex                                  mNetMsgMutex;
    MsgQueue<NetMsg*>                           mNetMsgList;

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

static std::string luaSha1(std::string str)
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

static std::string luaBase64(std::string str)
{
    return base64_encode((const unsigned char *)str.c_str(), str.size());
}

static std::string GetIPOfHost(const char* host)
{
    std::string ret;

    struct hostent *hptr = gethostbyname(host);
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

static std::string UtilsWsHandshakeResponse(std::string sec)
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

int main(int argc, char** argv)
{
    if (argc != 2)
    {
        std::cout << "Usage : luafile" << std::endl;
        exit(-1);
    }

    ox_socket_init();
#ifdef USE_OPENSSL
    SSL_library_init();
    OpenSSL_add_all_algorithms();
    SSL_load_error_strings();
#endif

    L = luaL_newstate();
    luaopen_base(L);
    luaopen_utf8(L);
    luaopen_string(L);
    luaopen_table(L);
    luaL_openlibs(L);
    lua_tinker::init(L);

    /*lua_sethook(L, luaRuntimeCheck, LUA_MASKLINE, 0);*/

    lua_tinker::class_add<CoreDD>(L, "CoreDD");

    lua_tinker::class_def<CoreDD>(L, "startMonitor", &CoreDD::startMonitor);
    lua_tinker::class_def<CoreDD>(L, "getNowUnixTime", &CoreDD::getNowUnixTime);

    lua_tinker::class_def<CoreDD>(L, "loop", &CoreDD::loop);

    lua_tinker::class_def<CoreDD>(L, "createTCPService", &CoreDD::createTCPService);
    lua_tinker::class_def<CoreDD>(L, "listen", &CoreDD::listen);


    lua_tinker::class_def<CoreDD>(L, "startTimer", &CoreDD::startTimer);
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

    CoreDD coreDD;
    lua_tinker::set(L, "CoreDD", &coreDD);

    lua_tinker::dofile(L, argv[1]);

    lua_close(L);
    L = nullptr;

    coreDD.destroy();

    return 0;
}
