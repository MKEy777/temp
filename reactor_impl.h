#pragma once
#include "reactor.h"
#include "event_demultiplexer.h"
#include "event_handler.h"
#include <mutex>

class ReactorImplementation {
private:
    EventDemultiplexer* demux;
    std::map<Handle, EventHandler*> handlers;
    std::mutex handlers_mutex;

public:
    ReactorImplementation() : demux(new SelectDemultiplexer()) {}
    ~ReactorImplementation() { delete demux; }

    void regist(EventHandler* handler, Event evt) {
        std::lock_guard<std::mutex> lock(handlers_mutex);
        Handle fd = handler->get_handle();
        handlers[fd] = handler;
        demux->regist(fd, evt);
    }

    void remove(Handle fd) {
        std::lock_guard<std::mutex> lock(handlers_mutex);
        demux->remove(fd);
        auto it = handlers.find(fd);
        if (it != handlers.end()) {
            it->second->handle_close();
            delete it->second;
        }
        handlers.erase(fd);
    }

    void modify(Handle fd, Event evt) {
        std::lock_guard<std::mutex> lock(handlers_mutex);
        demux->remove(fd);
        demux->regist(fd, evt);
    }

    void event_loop(int timeout) {
        while (true) {
            std::map<Handle, EventHandler*> temp_handlers;
            {
                std::lock_guard<std::mutex> lock(handlers_mutex);
                temp_handlers = handlers;
            }
            demux->wait_event(temp_handlers, timeout);
        }
    }
};

Reactor::Reactor() : impl(new ReactorImplementation()) {}
Reactor::~Reactor() { delete impl; }
void Reactor::regist(EventHandler* handler, Event evt) { impl->regist(handler, evt); }
void Reactor::remove(Handle fd) { impl->remove(fd); }
void Reactor::modify(Handle fd, Event evt) { impl->modify(fd, evt); }
void Reactor::event_loop(int timeout) { impl->event_loop(timeout); }