#ifndef _JOYNET_UTILS_H
#define _JOYNET_UTILS_H

#include "NonCopyable.h"
#include "WebSocketFormat.h"

#ifdef USE_ZLIB
#include "zlib.h"
#endif

namespace Joynet
{
    using namespace brynet;
    using namespace brynet::net;

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
}

#endif