#include "reactor.h"
#include "listen_handler.h"
#include "thread_pool.h"
#include <thread>
#include <iostream>

ThreadPool* thread_pool = nullptr;

// 将原来的 main 函数改名为 run_server
int run_server() {
    thread_pool = new ThreadPool(4);

    Reactor* sub_reactor = new Reactor();
    std::thread sub_thread([sub_reactor]() {
        sub_reactor->event_loop();
        });

    Reactor* main_reactor = new Reactor();
    ListenHandler* acceptor = new ListenHandler(8080, sub_reactor);
    main_reactor->regist(acceptor, READ);
    main_reactor->event_loop();

    sub_thread.join();
    delete main_reactor;
    delete sub_reactor;
    delete thread_pool;

    return 0;
}