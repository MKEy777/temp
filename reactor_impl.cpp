#include "reactor_impl.h"
#include "reactor.h"
#include <iostream>

// ReactorImplementation 成员函数的实现
ReactorImplementation::ReactorImplementation() : demux(new EpollDemultiplexer()) {}

ReactorImplementation::~ReactorImplementation() {
    delete demux;
}

void ReactorImplementation::regist(EventHandler* handler, Event evt) {
    std::lock_guard<std::mutex> lock(handlers_mutex);
    Handle fd = handler->get_handle();
    handlers[fd] = handler;
    demux->regist(fd, evt);
}

void ReactorImplementation::remove(Handle fd) {
    std::lock_guard<std::mutex> lock(handlers_mutex);
    demux->remove(fd);
    auto it = handlers.find(fd);
    if (it != handlers.end()) {
        it->second->handle_close();
        delete it->second;
    }
    handlers.erase(fd);
}

void ReactorImplementation::modify(Handle fd, Event evt) {
    std::lock_guard<std::mutex> lock(handlers_mutex);
    demux->modify(fd, evt);
}

void ReactorImplementation::event_loop(int timeout) {
    while (true) {
        demux->wait_event(handlers, timeout);
    }
}

Reactor::Reactor() {
    impl = new ReactorImplementation();
}

Reactor::~Reactor() {
    delete impl;
}

void Reactor::regist(EventHandler* handler, Event evt) {
    impl->regist(handler, evt);
}

void Reactor::remove(Handle fd) {
    impl->remove(fd);
}

void Reactor::modify(Handle fd, Event evt) {
    impl->modify(fd, evt);
}

void Reactor::event_loop(int timeout) {
    impl->event_loop(timeout);
}