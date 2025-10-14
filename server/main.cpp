#include "reactor.h"
#include "reactor_impl.h"
#include "listen_handler.h"
#include "thread_pool.h"
#include "chat_server.h" 
#include <thread>
#include <iostream>

// 全局变量
ThreadPool* thread_pool = nullptr;
ChatServer* chat_service = nullptr;

int run_server() {
    thread_pool = new ThreadPool(4);

    // --- 核心修改在这里 ---
    // 1. 先创建 sub_reactor
    Reactor* sub_reactor = new Reactor();

    // 2. 将 sub_reactor 的指针传给 ChatServer 的构造函数
    chat_service = new ChatServer(sub_reactor);

    // sub_reactor 运行在独立的线程中
    std::thread sub_thread([sub_reactor]() {
        sub_reactor->event_loop();
        });

    // main_reactor 负责 listen
    Reactor* main_reactor = new Reactor();
    ListenHandler* acceptor = new ListenHandler(9527, sub_reactor, chat_service);
    main_reactor->regist(acceptor, READ);

    std::cout << "Server starting main event loop..." << std::endl;
    main_reactor->event_loop();

    sub_thread.join();

    delete main_reactor;
    delete sub_reactor;
    delete thread_pool;
    delete chat_service;
    return 0;
}

int main(int argc, char* argv[]) {
    run_server();
    return 0;
}