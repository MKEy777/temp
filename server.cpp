#include "reactor.h"
#include "listen_handler.h"
#include "thread_pool.h"
#include <thread>
#include <iostream>

ThreadPool* thread_pool = nullptr;

// server.cpp
int run_server() {
    thread_pool = new ThreadPool(4);

    Reactor* sub_reactor = new Reactor();
    std::thread sub_thread([sub_reactor]() {
        sub_reactor->event_loop(100);
        });

    Reactor* main_reactor = new Reactor();
    ListenHandler* acceptor = new ListenHandler(9527, sub_reactor);
    main_reactor->regist(acceptor, READ);
    main_reactor->event_loop(); // main_reactor 可以继续阻塞等待新连接，无需超时

    sub_thread.join();
    delete main_reactor;
    delete sub_reactor;
    delete thread_pool;

    return 0;
}