#include "reactor.h"
#include "listen_handler.h"
#include "thread_pool.h"
#include <thread>

ThreadPool* thread_pool = nullptr;

int main() {
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
    WSACleanup();
    return 0;
}