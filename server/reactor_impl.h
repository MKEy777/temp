#pragma once
#include "epoll_demultiplexer.h"
#include "event_handler.h"
#include <map>
#include <mutex>

class ReactorImplementation {
private:
    EventDemultiplexer* demux;
    std::map<Handle, EventHandler*> handlers;
    std::mutex handlers_mutex;

public:
    ReactorImplementation();
    ~ReactorImplementation();

    void regist(EventHandler* handler, Event evt);
    void remove(Handle fd);
    void modify(Handle fd, Event evt);
    void event_loop(int timeout);
};