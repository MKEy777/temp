#include "reactor_impl.h"
#include "event_demultiplexer.h" 
#include "select_demultiplexer.h"
#include <iostream>

ReactorImplementation::ReactorImplementation() : demux(new SelectDemultiplexer()) {}
ReactorImplementation::~ReactorImplementation() { delete demux; }

// regist ����ʵ��
void ReactorImplementation::regist(EventHandler* handler, Event evt) {
    std::lock_guard<std::mutex> lock(handlers_mutex);
    Handle fd = handler->get_handle();
    handlers[fd] = handler;
    demux->regist(fd, evt);
}

// remove ����ʵ��
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

// modify ����ʵ��
void ReactorImplementation::modify(Handle fd, Event evt) {
    std::lock_guard<std::mutex> lock(handlers_mutex);
    demux->remove(fd);
    demux->regist(fd, evt);
}

// event_loop ����ʵ��
void ReactorImplementation::event_loop(int timeout) {
    while (true) {
        std::map<Handle, EventHandler*> temp_handlers;
        {
            std::lock_guard<std::mutex> lock(handlers_mutex);
            temp_handlers = handlers;
        }
        demux->wait_event(temp_handlers, timeout);
    }
}