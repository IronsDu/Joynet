# Joynet
Windows : [![Build status](https://ci.appveyor.com/api/projects/status/yyqufbynahl326pe/branch/master?svg=true)](https://ci.appveyor.com/project/IronsDu/joynet/branch/master) Linux : [![Build Status](https://travis-ci.org/IronsDu/Joynet.svg?branch=master)](https://travis-ci.org/IronsDu/Joynet)


## 介绍

high performance  network library for lua, based on https://github.com/IronsDu/accumulation-dev and `lua coroutine`.
Joynet 的网络底层使用多线程，但Lua (层面)是运行在单线程上。借助协程提供同步形式的API。

[src](https://github.com/IronsDu/Joynet/tree/master/src) 目录是此项目源代码

[libs](https://github.com/IronsDu/Joynet/tree/master/libs) 目录为基于此Lua协程网络库开发的一些库(譬如`Redis`、`Mysql`、`WebSocket`、`Postgres`、`HTTP Client`)

## 构建
使用 `git clone`迁出项目并进入项目根目录，并依次使用 `git submodule init`和`git submodule update` 下载依赖项.

然后使用cmake进行构建Joynet动态库

## 使用
[`examples`](https://github.com/IronsDu/Joynet/tree/master/examples) 目录包含测试代码。
譬如我们要在Windows下运行PingPong测试：

先在项目根目录执行  `lua examples\PingpongServer.lua`，然后执行 `lua examples\PingpongClient.lua` 即可

使用此库也很简单,在你的Lua代码里使用`require("Joynet")`加载网络库,然后使用`CoreDD`对象的相关接口即可(具体参考[`examples`](https://github.com/IronsDu/Joynet/tree/master/examples)目录的各示例代码)

当然，你必须先安装有Lua环境

Windows下可以[下载](http://luabinaries.sourceforge.net/)二进制包,仅Windows下的Joynet需要链接3rdparty/lualib目录,当前版本是lua5.3,如果你使用的Lua虚拟机是lua5.1,那么你需要用Lua5.1的include和lib/dll替换luasrc目录的内容,然后再构建Joynet

linux下可以[下载](http://www.lua.org/ftp/)Lua源码(然后使用make linus;make install安装即可)

## 关于协程
协程是轻量级线程，所以多线程有的问题它也有，只是影响程度不同。
在协程中使用同步API会阻塞当前协程，所以当你的应用程序只有一个协程从外部收取网络消息时，且在消息处理中使用同步API
操作Redis或者Http的话，效率会很低。 这时有两个方案可解决：1 、再提供回调形式的异步API， 但这样会使开发概念混乱 ；
2、 在前面说到的情景的消息处理中再开新协程，并在其中操作HTTP/Redis。
（当然，协程的创建和切换必然有一定开销 ^-^ )
