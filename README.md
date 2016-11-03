# Joynet
## 介绍

high performance  network library for lua, based on https://github.com/IronsDu/accumulation-dev and lua coroutine.
Joynet 的网络底层使用多线程，但Lua (层面)是运行在单线程上。借助协程提供同步形式的API。

[src](https://github.com/IronsDu/Joynet/tree/master/src) 目录是此项目源代码

[libs](https://github.com/IronsDu/Joynet/tree/master/libs) 目录为基于此Lua协程网络库开发的一些库(譬如`Redis`、`Mysql`、`WebSocket`、`Postgres`、`HTTP Client`)

## 构建
使用 `git clone`迁出项目并进入项目根目录，并依次使用 `git submodule init`和`git submodule update` 下载依赖项.

* Windows : 在项目根目录中打开 Joynet.sln, 编译即可在当前目录产生可执行文件 Joynet
* Linux : 在项目根本执行 `make` 即可生成可执行文件 Joynet

## 使用
examples 包含测试代码。
譬如我们要在`Windows`下运行PingPong测试：
先在项目根目录执行  `Joynet examples\PingpongServer.lua`，然后执行 `Joynet examples\PingpongClient.lua`

当前Joynet是作为一个宿主程序，由其运行业务Lua文件。
不过我们能轻松的把它作为动态库集成到已有的应用系统里。

## 关于协程
协程是轻量级线程，所以多线程有的问题它也有，只是影响程度不同。
在协程中使用同步API会阻塞当前协程，所以当你的应用程序只有一个协程从外部收取网络消息时，且在消息处理中使用同步API
操作Redis或者Http的话，效率会很低。 这时有两个方案可解决：1 、再提供回调形式的异步API， 但这样会使开发概念混乱 ；
2、 在前面说到的情景的消息处理中再开新协程，并在其中操作HTTP/Redis。
（当然，协程的创建和切换必然有一定开销 ^-^ )
